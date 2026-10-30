// simparty-monitor 예약 실행기 (Cloudflare Workers Cron Triggers) — 로직·상수. 진입 모듈은 worker.js(default export 만).
//
// 왜: GitHub 무료 cron 은 지연·드롭이 심하다(실측: 09:17 브리프가 13:21~14:51 도착, 10분 주기 uptime 이 하루 144회 중
//     5~13회만 실행). Cloudflare 크론은 거의 정시에 돈다. 이 Worker 는 체크를 직접 하지 않고, 정해진 시각에
//     GitHub Actions 워크플로를 workflow_dispatch 로 "깨우기만" 한다 — 감시 로직·상태(장애 이슈·캐시)·텔레그램은
//     전부 지금처럼 GitHub Actions 안에 있다.
//
// 크론(UTC, wrangler.toml [triggers] 와 같아야 한다 — 아래 UPTIME_CRON·BRIEF_CRON. 공백 개수 차이는 허용):
//   "4,14,24,34,44,54 * * * *"  uptime 10분마다. 매시 04분 슬롯 중 UTC 02~14시(KST 11~23시) = full 의도, 그 밖은 quick(DB 미경유)
//   "17 0 * * *"                Neon 브리프 (UTC 00:17 = KST 09:17)
//   트리거 2개 — Workers Free 는 계정당 5개(https://developers.cloudflare.com/workers/platform/limits/).
//   '4-59/10' 같은 범위+간격 표기는 공식 문서에 예시가 없어 쉼표 목록으로 쓴다.
//   모르는 크론이면 throw 한다(대시보드에서 손으로 입력하다 어긋나면 Past Events 에 실패로 드러나게).
//
// 보내는 입력: uptime.yml {mode: quick|full, source: "cf"} / neon-usage.yml {mode: "normal", source: "cf"}
//   source=cf 는 "정기 실행(Worker)" 표식이다 — 워크플로가 run-name 에 'cf' 를 넣고, 브리프의 감시 집계가 정기 실행으로 센다.
//   사람이 손으로 돌린 실행(test-alert·preview)은 source=manual 이라 세지 않는다. test-alert·preview 는 여기서 절대 보내지 않는다.
//   ⚠️ 워크플로에 source 입력이 없으면 GitHub 가 422 로 거부한다 → 워크플로 변경을 main 에 먼저 올린 뒤 이 Worker 를 켠다.
//
// full 주기(몇 시간마다 DB 체크를 할지)는 여기서 정하지 않는다 — repo 변수 FULL_EVERY_HOURS 한 곳(uptime-mode.sh 가 적용,
// 브리프의 설계 횟수·복구 안내도 같은 값). Worker 는 영업시간 04분 슬롯마다 full "의도"만 보내고, uptime-mode.sh 가
// 주기·UTC 02~14시 밖·재실행·45분 안에 다른 full 이 DB 를 건드렸으면 quick 으로 강등한다 — 이 Worker 가 잘못돼도
// DB 를 시간당 1회보다 자주 깨우지 않는다. GitHub schedule 대비책도 같은 스크립트를 거치므로 같은 주기를 따른다.
//
// env (wrangler.toml [vars] — wrangler deploy 가 대시보드 값을 toml 값으로 덮어쓴다. 값은 한 곳에서만 바꾼다):
//   GITHUB_TOKEN      (secret, 필수) fine-grained PAT — 이 저장소 하나, Repository permissions → Actions: Read and write
//   DRY_RUN           정확히 "0" 일 때만 실제로 GitHub 를 호출한다. 그 밖(기본 toml "1"·변수 없음·오타)은 보낼 내용만 로그에 남긴다
//                     — 시크릿을 넣는 순간 전송이 시작되지 않게(전환 절차: SCHEDULER=cloudflare 를 먼저 켠 뒤 "0")
//   GITHUB_REPO       (선택, 기본 thebluepigu/simparty-monitor) · GITHUB_REF (선택, 기본 main)
//
// 로그: 토큰은 어디에도 찍지 않는다. 실패 시 HTTP 상태와 응답 본문 앞부분만 console.error.

export const UPTIME_CRON = "4,14,24,34,44,54 * * * *";
export const BRIEF_CRON = "17 0 * * *";
export const FULL_FIRST_UTC_HOUR = 2;   // KST 11시
export const FULL_LAST_UTC_HOUR = 14;   // KST 23시 — uptime-mode.sh 의 영업시간 강제(UTC 02~14시)와 같다
export const FULL_SLOT_MINUTE = 4;      // 매시 04분 슬롯만 full 후보 (시간당 1회)

const DEFAULT_REPO = "thebluepigu/simparty-monitor";
const DEFAULT_REF = "main";
const API_VERSION = "2022-11-28";
const RETRY_DELAY_MS = 3000;
const BODY_SNIPPET = 300;

const normCron = (c) => String(c ?? "").trim().replace(/\s+/g, " ");

/**
 * 크론 + 예정 시각 → 보낼 dispatch 목록 (순수 함수 — 테스트 대상). 모르는 크론이면 throw.
 * 시각은 실제 실행 시각이 아니라 controller.scheduledTime(예정 시각)으로 판단한다 — Worker 가 몇 초 늦게 떠도 슬롯이 안 바뀐다.
 * @returns {{workflow: string, inputs: Record<string,string>}[]}
 */
export function planDispatches(cron, scheduledTimeMs) {
  const t = new Date(scheduledTimeMs);
  if (Number.isNaN(t.getTime())) throw new Error(`scheduledTime 해석 불가: ${scheduledTimeMs}`);
  const c = normCron(cron);
  if (c === BRIEF_CRON) {
    return [{ workflow: "neon-usage.yml", inputs: { mode: "normal", source: "cf" } }];
  }
  if (c === UPTIME_CRON) {
    const h = t.getUTCHours();
    const m = t.getUTCMinutes();
    const full = m === FULL_SLOT_MINUTE && h >= FULL_FIRST_UTC_HOUR && h <= FULL_LAST_UTC_HOUR;
    return [{ workflow: "uptime.yml", inputs: { mode: full ? "full" : "quick", source: "cf" } }];
  }
  // 모르는 크론(대시보드 입력 오타, wrangler.toml 만 바꾸고 여기 상수를 안 바꾼 경우) — 추측해서 돌리지 않고 실패로 남긴다.
  // 그동안은 GitHub schedule 대비책이 대신 돈다.
  throw new Error(`알 수 없는 크론 '${cron}' — lib.js 의 UPTIME_CRON/BRIEF_CRON 과 wrangler.toml·대시보드 크론 동기 확인 필요. 아무것도 보내지 않음`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** workflow_dispatch 1건. 성공(200/204, DRY_RUN 포함) true. 네트워크 오류·429·5xx 는 1회 재시도, 4xx 는 재시도 안 함. */
export async function dispatch(d, env, opts = {}) {
  const fetchImpl = opts.fetch ?? fetch;
  const delay = opts.retryDelayMs ?? RETRY_DELAY_MS;
  const repo = env.GITHUB_REPO || DEFAULT_REPO;
  const ref = env.GITHUB_REF || DEFAULT_REF;
  const url = `https://api.github.com/repos/${repo}/actions/workflows/${d.workflow}/dispatches`;
  const label = `${d.workflow} ${JSON.stringify(d.inputs)}`;
  // 실제 전송은 DRY_RUN 이 정확히 "0" 일 때만 — 변수를 빠뜨린 배포(대시보드 붙여넣기 등)는 보내지 않는다(fail-safe)
  if (String(env.DRY_RUN ?? "").trim() !== "0") {
    console.log(`[DRY_RUN] 보낼 dispatch: ${label} (ref=${ref}) — 실제 전송은 DRY_RUN=0 일 때만`);
    return true;
  }
  if (!env.GITHUB_TOKEN) {
    console.error(`GITHUB_TOKEN secret 없음 — ${label} 보내지 못함`);
    return false;
  }
  const init = {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": API_VERSION,
      "User-Agent": "simparty-monitor-scheduler",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ ref, inputs: d.inputs }),
  };
  for (let attempt = 1; attempt <= 2; attempt++) {
    let retryable = true;
    try {
      const res = await fetchImpl(url, init);
      // 기존 문서는 204(본문 없음), 최근 문서는 200(run id 포함)을 적는다 — 둘 다 성공
      if (res.status === 204 || res.status === 200) {
        console.log(`dispatch 성공: ${label} (HTTP ${res.status}, 시도 ${attempt})`);
        return true;
      }
      let body = "";
      try { body = (await res.text()).slice(0, BODY_SNIPPET); } catch { /* 본문 없음 */ }
      retryable = res.status === 429 || res.status >= 500;
      console.error(`dispatch 실패: ${label} — HTTP ${res.status} (시도 ${attempt}${retryable ? "" : ", 재시도 안 함"}) ${body}`);
    } catch (e) {
      console.error(`dispatch 오류: ${label} — ${e?.name ?? "Error"}: ${String(e?.message ?? e).slice(0, BODY_SNIPPET)} (시도 ${attempt})`);
    }
    if (!retryable || attempt === 2) break;
    await sleep(delay);
  }
  return false;
}
