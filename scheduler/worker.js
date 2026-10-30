// simparty-monitor 예약 실행기 (Cloudflare Workers Cron Triggers)
//
// 왜: GitHub 무료 cron 은 지연·드롭이 심하다(실측: 09:17 브리프가 13:21~14:51 도착, 10분 주기 uptime 이 하루 144회 중
//     5~13회만 실행). Cloudflare 크론은 거의 정시에 돈다. 이 Worker 는 체크를 직접 하지 않고, 정해진 시각에
//     GitHub Actions 워크플로를 workflow_dispatch 로 "깨우기만" 한다 — 감시 로직·상태(장애 이슈·캐시)·텔레그램은
//     전부 지금처럼 GitHub Actions 안에 있다.
//
// 크론(UTC, wrangler.toml [triggers] 와 같아야 한다 — 아래 UPTIME_CRON·BRIEF_CRON):
//   "4,14,24,34,44,54 * * * *"  uptime 10분마다. 매시 04분 슬롯 중 UTC 02~14시(KST 11~23시)·FULL_EVERY_HOURS 간격 = full,
//                               그 밖은 quick(DB 미경유)
//   "17 0 * * *"                Neon 브리프 (UTC 00:17 = KST 09:17)
//   트리거 2개 — Workers Free 는 계정당 5개(https://developers.cloudflare.com/workers/platform/limits/).
//   '4-59/10' 같은 범위+간격 표기는 공식 문서에 예시가 없어 쉼표 목록으로 쓴다.
//
// 보내는 입력: uptime.yml {mode: quick|full, source: "cf"} / neon-usage.yml {mode: "normal", source: "cf", full_every_hours}
//   source=cf 는 "정기 실행(Worker)" 표식이다 — 워크플로가 run-name 에 'cf' 를 넣고, 브리프의 감시 집계가 정기 실행으로 센다.
//   사람이 손으로 돌린 실행(test-alert·preview)은 source=manual 이라 세지 않는다. test-alert·preview 는 여기서 절대 보내지 않는다.
//   ⚠️ 워크플로에 source·full_every_hours 입력이 없으면 GitHub 가 422 로 거부한다 → 워크플로 변경을 main 에 먼저 올린 뒤 이 Worker 를 켠다.
//
// full 은 여기서 "의도"만 정한다. 실제로 DB 를 건드릴지는 uptime-mode.sh 가 다시 강제한다(UTC 02~14시 밖·재실행·45분 안에
// 다른 full 이 DB 를 건드렸으면 quick 으로 강등) — 이 Worker 가 잘못돼도 DB 를 시간당 1회보다 자주 깨우지 않는다.
//
// env (wrangler.toml [vars] 또는 대시보드 Settings → Variables and Secrets):
//   GITHUB_TOKEN      (secret, 필수) fine-grained PAT — 이 저장소 하나, Repository permissions → Actions: Read and write
//   FULL_EVERY_HOURS  (선택, 기본 "1") full 간격(시간). 1 = KST 11~23시 매시(하루 13회), 2 = 11·13·…·23시(7회),
//                     3 = 11·14·17·20·23시(5회). 0 = Worker 는 full 을 보내지 않음(전부 quick). full 주기를 바꾸는 곳은 여기 하나.
//   DRY_RUN           (선택) "1" 이면 GitHub 를 호출하지 않고 보낼 내용만 로그에 남김 — 처음 켤 때 확인용
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

/** FULL_EVERY_HOURS 해석: 정수 0~13, 그 밖(빈 값·문자·음수·소수)은 기본 1 */
export function fullEveryHours(env) {
  const raw = String(env?.FULL_EVERY_HOURS ?? "").trim();
  if (!/^\d+$/.test(raw)) return 1;
  const n = Number(raw);
  return n > 13 ? 13 : n;
}

/**
 * 크론 + 예정 시각 → 보낼 dispatch 목록 (순수 함수 — 테스트 대상).
 * 시각은 실제 실행 시각이 아니라 controller.scheduledTime(예정 시각)으로 판단한다 — Worker 가 몇 초 늦게 떠도 슬롯이 안 바뀐다.
 * @returns {{workflow: string, inputs: Record<string,string>}[]}
 */
export function planDispatches(cron, scheduledTimeMs, env = {}) {
  const t = new Date(scheduledTimeMs);
  if (Number.isNaN(t.getTime())) throw new Error(`scheduledTime 해석 불가: ${scheduledTimeMs}`);
  const every = fullEveryHours(env);
  if (cron === BRIEF_CRON) {
    return [{ workflow: "neon-usage.yml", inputs: { mode: "normal", source: "cf", full_every_hours: String(every) } }];
  }
  if (cron === UPTIME_CRON) {
    const h = t.getUTCHours();
    const m = t.getUTCMinutes();
    const full = every > 0 && m === FULL_SLOT_MINUTE && h >= FULL_FIRST_UTC_HOUR && h <= FULL_LAST_UTC_HOUR
      && (h - FULL_FIRST_UTC_HOUR) % every === 0;
    return [{ workflow: "uptime.yml", inputs: { mode: full ? "full" : "quick", source: "cf" } }];
  }
  // 모르는 크론(wrangler.toml 만 바꾸고 여기 상수를 안 바꾼 경우) — 추측해서 돌리지 않는다. GitHub schedule 대비책이 대신 돈다.
  console.error(`알 수 없는 크론 '${cron}' — worker.js 의 UPTIME_CRON/BRIEF_CRON 과 wrangler.toml 동기 확인 필요. 아무것도 보내지 않음`);
  return [];
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** workflow_dispatch 1건. 성공(200/204) true. 네트워크 오류·429·5xx 는 1회 재시도, 4xx 는 재시도 안 함. */
export async function dispatch(d, env, opts = {}) {
  const fetchImpl = opts.fetch ?? fetch;
  const delay = opts.retryDelayMs ?? RETRY_DELAY_MS;
  const repo = env.GITHUB_REPO || DEFAULT_REPO;
  const ref = env.GITHUB_REF || DEFAULT_REF;
  const url = `https://api.github.com/repos/${repo}/actions/workflows/${d.workflow}/dispatches`;
  const label = `${d.workflow} ${JSON.stringify(d.inputs)}`;
  if (String(env.DRY_RUN ?? "") === "1") {
    console.log(`[DRY_RUN] 보낼 dispatch: ${label} (ref=${ref})`);
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

export default {
  async scheduled(controller, env, ctx) {
    const plan = planDispatches(controller.cron, controller.scheduledTime, env);
    let failed = 0;
    for (const d of plan) {
      if (!(await dispatch(d, env))) failed++;
    }
    // 실패를 던져 Cron Events(대시보드 Past Events)에 실패로 남긴다. GitHub schedule 대비책이 대신 돈다.
    if (failed > 0) throw new Error(`dispatch ${failed}/${plan.length}건 실패 (cron='${controller.cron}')`);
  },
};
