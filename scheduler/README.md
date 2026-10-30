# scheduler — Cloudflare 예약 실행기 (감시를 정시에)

GitHub 무료 cron 은 지연·드롭이 심합니다. 2026-10 실측으로 09:17 브리프는 13:21~14:51 에 도착했고, 하루 144번 돌아야 할
uptime 은 5~13번만 돌았습니다. 이 폴더의 Cloudflare Worker 는 **정해진 시각에 GitHub 워크플로를 깨우기만** 합니다.
체크·장애 이슈·텔레그램은 지금처럼 GitHub Actions 안에서 돌고, Worker 는 `workflow_dispatch` API 를 한 번 부를 뿐입니다.

| 크론 (UTC) | KST | 보내는 것 |
|---|---|---|
| `4,14,24,34,44,54 * * * *` | 매시 04·14·…·54분 | `uptime.yml` `mode=quick`. 04분 슬롯이면서 UTC 02~14시(KST 11~23시)면 `mode=full`(의도) |
| `17 0 * * *` | 매일 09:17 | `neon-usage.yml` `mode=normal` |

- 모든 dispatch 에 `source=cf` 가 붙습니다. 그래서 run 제목이 `uptime · cf · quick`, `Neon 사용량 일일 브리프 · cf` 가 되고,
  브리프의 감시 집계는 이 run 을 정기 실행으로 셉니다. 사람이 손으로 돌린 test-alert·preview 는 정기 실행으로 세지 않습니다.
  Worker 는 test-alert·preview 를 보내지 않습니다.
- 크론 트리거는 2개만 씁니다. Workers Free 플랜 한도는 **계정당 5개**입니다
  ([Workers limits](https://developers.cloudflare.com/workers/platform/limits/) 표의 "Number of Cron Triggers per account | 5 | 250").
  크론 시각은 UTC 이고, 트리거를 바꾸면 반영까지 최대 15분이 걸립니다
  ([Cron Triggers](https://developers.cloudflare.com/workers/configuration/cron-triggers/)).
  `4-59/10` 같은 "범위+간격" 표기는 공식 문서에 예시가 없어서 쉼표 목록으로 적었습니다.
  모르는 크론으로 불리면(대시보드 입력 오타 등) 아무것도 보내지 않고 **실패로** 끝나 Past Events 에 드러납니다.
- Free 플랜에서 크론 1회의 CPU 시간 한도는 10ms 입니다. GitHub 응답을 기다리는 시간은 CPU 시간에 들어가지 않으므로 충분합니다.
  하루 호출은 145회로, 하루 요청 한도 100,000 의 0.2% 입니다.
- **full(DB 경유) 주기는 Worker 가 정하지 않습니다.** Worker 는 영업시간 04분 슬롯마다 full "의도"만 보내고,
  `uptime-mode.sh` 가 repo 변수 `FULL_EVERY_HOURS` 주기·영업시간 밖·재실행·45분 안에 다른 full 이 DB 를 건드렸는지를 보고
  quick 으로 낮춥니다. GitHub schedule 대비책·수동 full 도 같은 스크립트를 거치므로 **주기를 정하는 곳은 그 변수 하나**입니다.
  Worker 설정이 잘못돼도 DB 를 시간당 1회보다 자주 깨우지 않습니다.
- **quick 은 DB 를 건드리지 않습니다.** BE `/actuator/health/liveness` 는 `livenessState` 만 보고(DB 미포함),
  FE `/robots.txt` 는 Nitro 라우트라 BE 를 부르지 않습니다. 따라서 10분 주기 quick 은 Neon 을 깨우지 않습니다.

## 파일

| 파일 | 내용 |
|---|---|
| `worker.js` | 진입 모듈. **default export(`scheduled`) 하나만** 내보냅니다. workerd 는 진입 모듈의 named export 를 entrypoint·handler 로 해석하므로, 상수·함수를 여기서 내보내면 기동이 막힐 수 있습니다(테스트가 이 규칙을 확인) |
| `lib.js` | 크론→dispatch 판단·GitHub 호출·재시도 (테스트 대상) |
| `wrangler.toml` | 이름·크론·변수(`DRY_RUN`)·Workers Logs |
| `worker.test.mjs` | 단위 테스트 (가짜 fetch — 네트워크 없음) |

## 설정값

**Worker 쪽** (wrangler 로 배포하면 `wrangler.toml` 에서만 바꿉니다. `wrangler deploy` 는 대시보드에서 바꾼 변수를 toml 값으로 덮어씁니다)

| 이름 | 종류 | 기본 | 뜻 |
|---|---|---|---|
| `GITHUB_TOKEN` | **Secret** (필수) | — | fine-grained PAT (아래 1단계) |
| `DRY_RUN` | 변수 | `"1"` | **정확히 `"0"` 일 때만** 실제로 GitHub 를 부릅니다. 그 밖(`"1"`·변수 없음·오타)은 보낼 내용만 로그에 남깁니다. 시크릿을 넣는 순간 전송이 시작되지 않게 하려는 것입니다 |
| `GITHUB_REPO` · `GITHUB_REF` | 변수 | `thebluepigu/simparty-monitor` · `main` | 보통 바꾸지 않습니다 |

**GitHub repo 쪽** (Settings → Secrets and variables → Actions → **Variables**)

| 이름 | 기본 | 뜻 |
|---|---|---|
| `SCHEDULER` | 없음 = `github` | 예약 실행 주 경로. `cloudflare` 로 두면 Worker 가 주 경로, GitHub schedule 은 대비책. 다른 값(오타)은 `github` 으로 취급하고 로그에 경고 + 브리프용 `SCHEDULER_BAD=1` |
| `FULL_EVERY_HOURS` | 없음 = `1` | DB 경유(full) 체크 주기(시간). `1` = KST 11~23시 매시(하루 13회, 지금과 같음), `2` = 11·13·…·23시(7회), `3` = 11·14·17·20·23시(5회), `0` = 안 함. 브리프의 "DB 포함 점검 예정 N번" 과 복구 안내의 다음 DB 포함 점검 시각도 이 값으로 계산합니다. 바꾸면 다음 run 부터 바로 적용됩니다(`gh variable set FULL_EVERY_HOURS -b 3 -R thebluepigu/simparty-monitor`) |

`FULL_EVERY_HOURS=0` 으로 두면 DB 체크가 전혀 돌지 않으므로, 하루 반 뒤부터 브리프에 "🟡 DB 포함 점검이 36시간째 없어요" 가 뜨고, DB 를 거치는 점검이 실패한 장애는 **저절로 닫히지 않습니다**(수동 `mode=full` 도 `uptime-mode.sh` 가 quick 으로 바꾸고, DB 경유 실패는 full 이 돌 때까지 이월). 알림은 "FULL_EVERY_HOURS 를 1 로 바꾼 뒤 KST 11~23시에 mode=full 수동 실행, 또는 이슈 직접 close" 로 안내합니다(2·3 이면 수동 full 도 그 주기 시각(KST 11시부터 N시간 간격)에만 돕니다).
정말로 끌 때만 씁니다. 주기를 늘리면 DB 체크 실패로 열린 장애는 다음 DB 체크 때 복구가 확정되므로(최대 N시간) 그만큼 늦게 닫힙니다.

## 대비책 — GitHub `schedule:` 은 그대로 남깁니다

Worker 나 토큰이 죽어도 감시가 끊기지 않도록, 두 워크플로의 `on.schedule` 은 지우지 않습니다. 어느 쪽이 주 경로인지는
repo 변수 **`SCHEDULER`** 가 정합니다(없으면 `github`). 판정은 각 워크플로의 첫 스텝 '정기 실행 중복 확인'
(`.github/scripts/schedule-gate.sh`)이 합니다.

| 상황 (`SCHEDULER=cloudflare`) | uptime | 브리프 |
|---|---|---|
| **Worker 정상** | GitHub schedule run 은 최근 20분 안에 Worker run 이 있으면 체크 없이 건너뜁니다(run 은 success, 이슈·텔레그램 손대지 않음). 취소·기동 실패로 끝난 Worker run 은 세지 않습니다 | GitHub schedule run 은 오늘(KST) 정기 브리프를 이미 **보냈으면** 건너뜁니다 → 하루 1통 |
| **Worker 중단** (토큰 만료, `DRY_RUN` 그대로, 계정 문제 등) | 최근 20분 안에 Worker run 이 없으면 GitHub schedule run 이 대신 체크합니다. 빈도는 예전(GitHub 실측) 수준으로 돌아갑니다 | 오늘 보낸 정기 브리프가 없으면 GitHub schedule run 이 대신 보냅니다(늦은 오후 도착 — 예전과 같음) |
| **둘 다 실행** (조회 실패로 fail-open, Worker 가 다시 살아나는 순간 등) | `concurrency: uptime` 이 두 run 을 차례로 돌립니다. 장애 알림은 이슈 본문 마커가 막습니다(`alerted` 누적 집합, `tg-sent` 6시간 재알림) → 같은 장애를 두 번 알리지 않습니다. DB 체크는 `uptime-mode.sh` 45분 가드가 막습니다. 다만 연달아 두 번 통과하면 close 가 몇 분 만에 확정될 수 있습니다(히스테리시스가 시간이 아니라 횟수 기준) | `concurrency: neon-usage` 가 직렬화하고, 뒤에 도는 쪽이 앞 run 의 "보냄" 을 보고 건너뜁니다. Worker run 쪽도 같은 확인을 하므로 GitHub schedule 이 먼저 와도 하루 1통입니다. 최악(조회 실패)은 그날 브리프 2통입니다 |

- **"보냄" 의 뜻**: 그 run 의 '브리프 전송 표식' 스텝이 success 이거나(텔레그램 전송 성공 — 템플릿 고장으로 plain 폴백을
  보낸 뒤 job 이 실패로 끝나도 보냄), '브리프' 스텝이 success 입니다. 전송 자체가 실패한 run 은 보낸 것이 아니므로 대비책이
  다시 보냅니다. 전송 표식은 `neon-usage.sh` 가 전송 성공 시 스텝 출력 `sent=1` 로 남깁니다.
- uptime 은 "같은 종류"를 따지지 않고 Worker uptime run 이 있었는지만 봅니다. Worker 가 살아 있으면 그 시간의 full 여부는
  이미 Worker run 이 모드 결정(주기 포함)을 거쳐 정한 것입니다.
- 대비책 run 도 `FULL_EVERY_HOURS` 주기를 따릅니다(같은 `uptime-mode.sh`).
- 조회가 실패하면 진행합니다(fail-open). 감시가 빠지는 것보다 한 번 더 도는 편이 낫기 때문입니다.
- `SCHEDULER` 가 없거나 `github` 이면 GitHub schedule run 은 오늘과 똑같이 돕니다(이 스텝은 gh 호출도 하지 않음).
  Worker run 의 브리프만은 `SCHEDULER` 와 관계없이 "오늘 이미 보냈으면 건너뜀"을 확인합니다.
- **Worker 가 멈추면 알 수 있게**: `SCHEDULER=cloudflare` 인데 최근 60분 안에 Worker run 이 없으면 브리프의 감시 집계(hb)가
  `UPTIME_CF_STALE=1`(마지막 Worker run 시각 `UPTIME_CF_LAST`)을 브리프 스크립트에 넘기고 run 로그에 경고를 남깁니다.
  브리프는 이 값으로 🟡 "예약 실행기(Cloudflare)가 1시간 넘게 안 돌았어요 — GitHub 대비책으로 도는 중 … (토큰 만료 확인)" 을
  띄웁니다. 대비책 uptime run 은 run 로그에 경고를 남기고, 그 run 에서 나가는 장애 알림은 "10분 간격" 이 아니라 GitHub 지연
  문구를 씁니다(`schedule-gate.sh` 의 `fallback=1`).

## 전환 절차 (할로윈 이후 — 11/1~)

순서가 중요합니다. **워크플로 변경을 main 에 먼저** 올려야 합니다. 워크플로에 `source` 입력이 없으면 GitHub 가
Worker 의 dispatch 를 422 로 거부합니다.

### 0. 워크플로 변경을 main 에 올리기

CI 가 초록인 것을 확인한 뒤 main 에 머지합니다. `SCHEDULER`·`FULL_EVERY_HOURS` 변수가 없으므로 이 시점의 운영은 오늘과 같습니다.

### 1. GitHub fine-grained PAT 발급

GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token

- Token name: `simparty-monitor-scheduler`
- **Expiration: 날짜를 지정합니다**(예: 1년). 만료일을 달력에 적어 두고, 만료 2주 전에 새 토큰을 만들어 3단계로 교체합니다.
  만료되면 Worker 는 401 로 실패하고 감시는 GitHub schedule 대비책으로 내려갑니다. 끊기지는 않지만 다시 불규칙해지고,
  브리프에 🟡 "예약 실행기 멈춤" 이 뜹니다.
- Repository access: **Only select repositories** → `thebluepigu/simparty-monitor` **하나만**
- Repository permissions → **Actions: Read and write**(나머지는 손대지 않습니다. Metadata: Read 는 자동으로 붙습니다)
  — dispatch API 는 Actions **write** 가 필요합니다
  ([fine-grained 권한표](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens):
  `POST /repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches | write`)
- 생성된 토큰은 바로 3단계에 붙여 넣고, 다른 곳(채팅·메모·repo)에는 적지 않습니다. 새면 할 수 있는 일은 아래 '토큰이 새면' 참고.

### 2. Worker 만들기 — wrangler 권장

**A. wrangler (권장)** — `worker.js`·`lib.js` 를 하나로 묶어 올리고, 크론·변수·Workers Logs 를 toml 대로 등록합니다.

```bash
cd scheduler
npx wrangler@4 login
npx wrangler@4 deploy            # wrangler.toml 의 name·main·crons·vars(DRY_RUN="1")·observability 그대로
```

`wrangler.toml` 은 `DRY_RUN = "1"` 이 기본이라, 이 시점엔 아무것도 보내지 않습니다. 이후 변수는 **toml 에서만** 바꿉니다
(대시보드에서 바꾸면 다음 deploy 가 toml 값으로 되돌립니다).

**B. 대시보드에 붙여넣기**

1. Cloudflare 대시보드 → Workers & Pages → Create → Worker → 이름 `simparty-monitor-scheduler` → Deploy
2. Edit code → 파일을 **두 개** 만듭니다: 기본 파일(`worker.js`)을 지우고 `scheduler/worker.js` 내용을, 새 파일 `lib.js` 에
   `scheduler/lib.js` 내용을 붙여 넣기 → Deploy. (`worker.js` 만 붙이면 `./lib.js` import 가 실패해 배포가 안 됩니다)
3. Settings → Variables and Secrets → 변수 `DRY_RUN` = `1`. (변수가 없어도 보내지 않지만, 확인용으로 명시합니다)
4. Settings → Observability → Workers Logs 켜기 (5단계 확인·토큰 만료 진단용, Free 포함)
5. Settings → Domains & Routes 의 workers.dev 는 꺼도 됩니다(HTTP 로 부를 일이 없음)

### 3. Secret `GITHUB_TOKEN` 등록

- wrangler: `npx wrangler@4 secret put GITHUB_TOKEN` (프롬프트에 붙여넣기 — 명령줄 인자로 주지 않습니다)
- 대시보드: Settings → Variables and Secrets → Add → Type **Secret**, 이름 `GITHUB_TOKEN`, 값 = 1단계 토큰

`DRY_RUN` 이 `"1"` 이므로 시크릿을 넣어도 아직 보내지 않습니다.

### 4. 크론 등록

- wrangler: 2단계 `deploy` 가 `[triggers] crons` 를 같이 등록합니다
- 대시보드: Settings → Trigger Events(Triggers) → Add → Cron Triggers 에 `4,14,24,34,44,54 * * * *` 와 `17 0 * * *` 두 개
  (문자 하나라도 다르면 Worker 가 "알 수 없는 크론" 으로 실패합니다 — Past Events 에 빨간 줄)
- 반영까지 최대 15분입니다

### 5. DRY_RUN 으로 확인 → 실제 전송

1. Worker → **Logs**(Workers Logs, 지난 기록도 보임)를 엽니다. 10분마다
   `[DRY_RUN] 보낼 dispatch: uptime.yml {"mode":"quick","source":"cf"}` 가 찍히고, KST 11:04 쯤엔 `"mode":"full"`,
   09:17 엔 `neon-usage.yml` 이 찍히면 정상입니다. Past Events 에는 성공·실패만 보이고 로그 본문은 안 보입니다.
2. repo 변수를 만듭니다: **`SCHEDULER` = `cloudflare`**
   (`gh variable set SCHEDULER -b cloudflare -R thebluepigu/simparty-monitor`).
   Worker 가 아직 보내지 않으므로 이 순간에는 GitHub schedule run 이 대비책으로 돌고, 로그에 "Worker 실행 없음" 경고가 찍힙니다.
   **반드시 3보다 먼저** 합니다 — 순서가 바뀌면 그 사이 uptime 이 두 갈래로 돌고 브리프가 하루 2통 옵니다.
3. Worker 변수 `DRY_RUN` 을 `"0"` 으로 바꿉니다.
   - wrangler: `wrangler.toml` 의 `DRY_RUN = "0"` 으로 고치고 `npx wrangler@4 deploy`. 이 toml 변경은 커밋해 둡니다
     (커밋하지 않으면 다음 deploy 가 `"1"` 로 되돌려 조용히 대비책으로 내려갑니다 — 브리프 🟡 로 드러나긴 합니다).
   - 대시보드: 변수 `DRY_RUN` = `0` 저장(바로 반영)
4. 확인:

```bash
gh run list -R thebluepigu/simparty-monitor --event workflow_dispatch --limit 10   # 'uptime · cf · quick' 이 10분마다
gh run list -R thebluepigu/simparty-monitor --workflow uptime.yml --event schedule --limit 5
#   → GitHub schedule run 은 success 지만 '정기 실행 중복 확인' 로그에 "건너뜀" — 체크 스텝 skipped
```

다음 날 09:17 쯤 브리프가 오면 끝입니다. 브리프의 "최근 24h 정기 실행" 이 144 근처로 올라가야 합니다.
full 주기를 줄이려면 그 뒤 언제든 repo 변수 `FULL_EVERY_HOURS` 를 설정합니다(Worker 는 손대지 않음).

## 되돌리기

**순서: Worker 먼저 멈춤 → 15분 대기 → `SCHEDULER` 삭제.** 거꾸로 하면 안 됩니다.

1. Worker 를 멈춥니다. 셋 중 하나:
   - `DRY_RUN` 을 `"1"` 로(wrangler 는 toml 수정 후 deploy, 대시보드는 저장)
   - 크론 트리거 삭제(대시보드 Trigger Events, 또는 `crons = []` 로 deploy — 이 toml 은 **커밋하지 않습니다**: 테스트가
     크론 2개를 요구해 CI 가 빨개집니다. 되돌린 뒤 다시 켤 때는 커밋된 toml 그대로 deploy)
   - Worker 자체 삭제
2. **15분 기다립니다**(크론 변경 반영 최대 15분). Workers Logs 에 실제 `dispatch 성공` 이 더 찍히지 않는지,
   `gh run list --event workflow_dispatch` 에 새 `· cf` run 이 없는지 확인합니다.
   이 동안 `SCHEDULER=cloudflare` 가 남아 있으므로 대비책이 자동으로 이어받습니다(uptime 은 20분 안, 브리프는 그날 안 갔으면 대신 보냄).
3. repo 변수 `SCHEDULER` 를 지웁니다(`gh variable delete SCHEDULER -R thebluepigu/simparty-monitor`). 이제 예전과 똑같습니다.
   **언제 지우나**: KST 09:17 전, 또는 그날 GitHub schedule 브리프 run 이 끝난 뒤(`gh run list -R thebluepigu/simparty-monitor
   --workflow neon-usage.yml --event schedule --limit 1` — 보통 KST 13~16시). 그 사이(09:17 Worker 브리프는 이미 갔고 오후
   schedule 브리프는 아직)에 지우면 schedule 브리프가 조회 없이 보내 **그날만 2통**이 옵니다(감시·DB 영향 없음).
4. PAT 를 GitHub 에서 Revoke 합니다.

왜 이 순서인가: `SCHEDULER` 가 없으면 GitHub schedule 브리프는 **조회 없이 그냥 보냅니다**(변수가 없을 때 지금과 똑같이
동작하도록 일부러 gh 호출을 0회로 둔 것). 그래서 Worker 가 살아 있는 채로 `SCHEDULER` 부터 지우면, 그날 Worker 브리프(09:17)와
GitHub schedule 브리프(오후)가 둘 다 와서 2통이 되고, uptime 도 두 갈래로 돕니다(해롭지는 않지만 낭비 — 직렬화·이슈 마커·
45분 DB 가드가 막음). 순서를 어겼다면 바로 1단계를 하면 다음 날부터 정상입니다.

워크플로 코드는 되돌릴 필요가 없습니다. `SCHEDULER` 가 없으면 예전과 똑같이 동작합니다.

## 토큰이 새면 할 수 있는 일

fine-grained PAT 의 Actions write 는 dispatch 하나만 따로 줄 수 없습니다. 토큰이 새면 이 저장소에서 다음이 가능합니다.

- 워크플로를 마음대로 dispatch — test-alert 반복(텔레그램 스팸). full 반복은 영업시간·45분 가드가 DB 접근을 시간당 1회로 막습니다
- 워크플로 disable — 감시가 조용히 멈춤(브리프까지 끄면 알림도 없음)
- run 취소·재실행·run 과 로그 삭제
- Actions 캐시 삭제 — `.selffail`(감시 실패 알림 6시간 억제)·neon-state(autosuspend 판정 기준점)가 초기화
- 할 수 없는 것: 코드·워크플로 파일 변경, 시크릿·변수 읽기/쓰기, 이슈 쓰기, 다른 저장소

대응: 즉시 Revoke → `gh workflow list -R thebluepigu/simparty-monitor` 로 두 워크플로가 active 인지 확인(꺼져 있으면
`gh workflow enable`) → 새 토큰 발급 후 3단계. 토큰을 만료일 있게 만들고, 이 저장소 하나에만 거는 이유가 이것입니다.

## 개발

```bash
node --check scheduler/worker.js && node --check scheduler/lib.js
node --test scheduler/worker.test.mjs        # 크론→dispatch 매핑·재시도·토큰 미노출·진입 모듈 export 규칙 (가짜 fetch, 네트워크 없음)
bash .github/scripts/tests/ci-check.sh       # 위 + 대비책·heartbeat·uptime-mode 주기 테스트까지 (CI 와 같은 명령)
```

크론을 바꾸면 `wrangler.toml` 의 `crons` 와 `lib.js` 의 `UPTIME_CRON`·`BRIEF_CRON` 을 같이 바꿉니다.
다르면 Worker 가 "알 수 없는 크론" 으로 실패하고 아무것도 보내지 않으며, 테스트도 실패합니다.
`worker.js` 에는 named export 를 추가하지 않습니다(테스트가 막음) — 상수·함수는 `lib.js` 에 둡니다.
