# scheduler — Cloudflare 예약 실행기 (감시를 정시에)

GitHub 무료 cron 은 지연·드롭이 심합니다. 2026-10 실측으로 09:17 브리프는 13:21~14:51 에 도착했고, 하루 144번 돌아야 할
uptime 은 5~13번만 돌았습니다. 이 폴더의 Cloudflare Worker 는 **정해진 시각에 GitHub 워크플로를 깨우기만** 합니다.
체크·장애 이슈·텔레그램은 지금처럼 GitHub Actions 안에서 돌고, Worker 는 `workflow_dispatch` API 를 한 번 부를 뿐입니다.

| 크론 (UTC) | KST | 보내는 것 |
|---|---|---|
| `4,14,24,34,44,54 * * * *` | 매시 04·14·…·54분 | `uptime.yml` `mode=quick`. 04분 슬롯이면서 UTC 02~14시(KST 11~23시)이고 `FULL_EVERY_HOURS` 간격에 맞으면 `mode=full` |
| `17 0 * * *` | 매일 09:17 | `neon-usage.yml` `mode=normal` |

- 모든 dispatch 에 `source=cf` 가 붙습니다. 그래서 run 제목이 `uptime · cf · quick`, `Neon 사용량 일일 브리프 · cf` 가 되고,
  브리프의 감시 집계는 이 run 을 정기 실행으로 셉니다. 사람이 손으로 돌린 test-alert·preview 는 정기 실행으로 세지 않습니다.
- 크론 트리거는 2개만 씁니다. Workers Free 플랜 한도는 **계정당 5개**입니다
  ([Workers limits](https://developers.cloudflare.com/workers/platform/limits/) 표의 "Number of Cron Triggers per account | 5 | 250").
  크론 시각은 UTC 이고, 트리거를 바꾸면 반영까지 최대 15분이 걸립니다
  ([Cron Triggers](https://developers.cloudflare.com/workers/configuration/cron-triggers/)).
  `4-59/10` 같은 "범위+간격" 표기는 공식 문서에 예시가 없어서 쉼표 목록으로 적었습니다.
- Free 플랜에서 크론 1회의 CPU 시간 한도는 10ms 입니다. GitHub 응답을 기다리는 시간은 CPU 시간에 들어가지 않으므로 충분합니다.
  하루 호출은 145회로, 하루 요청 한도 100,000 의 0.2% 입니다.
- full 은 Worker 가 "의도"만 정합니다. 실제로 DB 를 건드릴지는 `uptime-mode.sh` 가 다시 판단합니다. 영업시간 밖이거나,
  재실행이거나, 45분 안에 다른 full 이 DB 를 건드렸으면 quick 으로 낮춥니다. 그래서 Worker 설정이 잘못돼도 DB 를
  시간당 1회보다 자주 깨우지 않습니다.
- **quick 은 DB 를 건드리지 않습니다.** BE `/actuator/health/liveness` 는 `livenessState` 만 보고(DB 미포함),
  FE `/robots.txt` 는 Nitro 라우트라 BE 를 부르지 않습니다. 따라서 10분 주기 quick 은 Neon 을 깨우지 않습니다.

## 설정값

| 이름 | 종류 | 기본 | 뜻 |
|---|---|---|---|
| `GITHUB_TOKEN` | **Secret** (필수) | — | fine-grained PAT (아래 1단계) |
| `FULL_EVERY_HOURS` | 변수 | `1` | full(DB 경유) 간격. `1` = KST 11~23시 매시(하루 13회), `2` = 11·13·…·23시(7회), `3` = 11·14·17·20·23시(5회), `0` = Worker 는 full 을 보내지 않음. **full 주기를 바꾸는 곳은 여기 하나**입니다. 브리프의 "DB체크 설계 N회" 도 이 값으로 계산됩니다 |
| `DRY_RUN` | 변수 | `0` | `1` 이면 GitHub 를 부르지 않고 보낼 내용만 로그에 남깁니다(처음 켤 때 확인용) |
| `GITHUB_REPO` · `GITHUB_REF` | 변수 | `thebluepigu/simparty-monitor` · `main` | 보통 바꾸지 않습니다 |

`FULL_EVERY_HOURS=0` 으로 두면 DB 체크가 전혀 돌지 않으므로, 하루 반 뒤부터 브리프에 "DB체크 36시간 전 ⚠️" 가 뜹니다.
정말로 끌 때만 씁니다.

## 대비책 — GitHub `schedule:` 은 그대로 남깁니다

Worker 나 토큰이 죽어도 감시가 끊기지 않도록, 두 워크플로의 `on.schedule` 은 지우지 않습니다. 어느 쪽이 주 경로인지는
repo 변수 **`SCHEDULER`** 가 정합니다(없으면 `github`). 판정은 각 워크플로의 첫 스텝 '정기 실행 중복 확인'
(`.github/scripts/schedule-gate.sh`)이 합니다.

| 상황 (`SCHEDULER=cloudflare`) | uptime | 브리프 |
|---|---|---|
| **Worker 정상** | GitHub schedule run 은 최근 20분 안에 Worker run 이 있으면 체크 없이 건너뜁니다(run 은 success, 이슈·텔레그램 손대지 않음) | GitHub schedule run 은 오늘(KST) Worker 브리프가 이미 갔으면 건너뜁니다 → 하루 1통 |
| **Worker 중단** (토큰 만료, 계정 문제 등) | 최근 20분 안에 Worker run 이 없으면 GitHub schedule run 이 대신 체크합니다. 로그에 경고가 남습니다. 빈도는 예전(GitHub 실측) 수준으로 돌아갑니다 | 오늘 보낸 정기 브리프가 없으면 GitHub schedule run 이 대신 보냅니다(늦은 오후 도착 — 예전과 같음) |
| **둘 다 실행** (조회 실패로 fail-open, Worker 가 다시 살아나는 순간 등) | `concurrency: uptime` 이 두 run 을 차례로 돌립니다. 장애 알림은 이슈 본문 마커가 막습니다(`alerted` 누적 집합, `tg-sent` 6시간 재알림)→ 같은 장애를 두 번 알리지 않습니다. DB 체크는 `uptime-mode.sh` 45분 가드가 막습니다. 다만 연달아 두 번 통과하면 close 가 몇 분 만에 확정될 수 있습니다(히스테리시스가 시간이 아니라 횟수 기준) | `concurrency: neon-usage` 가 직렬화하고, 뒤에 도는 쪽이 앞 run 의 '브리프' 스텝 success 를 보고 건너뜁니다. Worker run 쪽도 같은 확인을 하므로 GitHub schedule 이 먼저 와도 하루 1통입니다. 최악(조회 실패)은 그날 브리프 2통입니다 |

- uptime 은 "같은 종류"를 따지지 않고 Worker uptime run 이 있었는지만 봅니다. Worker 가 살아 있으면 full 여부도 Worker
  (`FULL_EVERY_HOURS`)가 정한 것입니다. full 슬롯이라고 GitHub 가 따로 full 을 돌리면, 줄여 둔 DB 접근이 되살아납니다.
- 대비책 run 에는 `FULL_EVERY_HOURS` 가 적용되지 않고, GitHub 의 원래 크론(`4 2-14 * * *`)대로 full 을 시도합니다.
  실제로는 GitHub 가 그 크론을 하루 1~3번만 실행하므로 Neon 부담은 예전 수준입니다.
- 조회가 실패하면 진행합니다(fail-open). 감시가 빠지는 것보다 한 번 더 도는 편이 낫기 때문입니다.
- `SCHEDULER` 가 없거나 `github` 이면 GitHub schedule run 은 오늘과 똑같이 돕니다(이 스텝은 gh 호출도 하지 않음).
  Worker run 의 브리프만은 `SCHEDULER` 와 관계없이 "오늘 이미 보냈으면 건너뜀"을 확인합니다.

## 전환 절차 (할로윈 이후 — 11/1~)

순서가 중요합니다. **워크플로 변경을 main 에 먼저** 올려야 합니다. 워크플로에 `source` 입력이 없으면 GitHub 가
Worker 의 dispatch 를 422 로 거부합니다.

### 0. 워크플로 변경을 main 에 올리기 (이 브랜치 `feat/cf-scheduler`)

CI 가 초록인 것을 확인한 뒤 main 에 머지합니다. `SCHEDULER` 변수가 없으므로 이 시점의 운영은 오늘과 같습니다.

### 1. GitHub fine-grained PAT 발급

GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token

- Token name: `simparty-monitor-scheduler`
- **Expiration: 날짜를 지정합니다**(예: 1년). 만료일을 달력에 적어 두고, 만료 2주 전에 새 토큰을 만들어 3단계로 교체합니다.
  만료되면 Worker 는 401 로 실패하고 감시는 GitHub schedule 대비책으로 내려갑니다. 끊기지는 않지만 다시 불규칙해집니다.
- Repository access: **Only select repositories** → `thebluepigu/simparty-monitor` **하나만**
- Repository permissions → **Actions: Read and write**(나머지는 손대지 않습니다. Metadata: Read 는 자동으로 붙습니다)
  — dispatch API 는 Actions **write** 가 필요합니다
  ([fine-grained 권한표](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens):
  `POST /repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches | write`)
- 생성된 토큰은 바로 2~3단계에 붙여 넣고, 다른 곳(채팅·메모·repo)에는 적지 않습니다.

### 2. Worker 만들기 (둘 중 하나)

**A. 대시보드에 붙여넣기**

1. Cloudflare 대시보드 → Workers & Pages → Create → Worker → 이름 `simparty-monitor-scheduler` → Deploy
2. Edit code → 기본 코드를 지우고 `scheduler/worker.js` 내용을 그대로 붙여 넣기 → Deploy
3. Settings → Variables and Secrets → 변수 `FULL_EVERY_HOURS` = `1`, `DRY_RUN` = `1`(첫 확인용)
4. Settings → Domains & Routes 의 workers.dev 는 꺼도 됩니다(HTTP 로 부를 일이 없음)

**B. wrangler**

```bash
cd scheduler
npx wrangler@4 login
npx wrangler@4 deploy            # wrangler.toml 의 name·main·crons·vars 그대로
```

`wrangler.toml` 은 `DRY_RUN = "0"` 입니다. 첫 확인을 DRY_RUN 으로 하려면 배포 전에 `"1"` 로 바꿉니다(커밋은 하지 않음).

### 3. Secret `GITHUB_TOKEN` 등록

- 대시보드: Settings → Variables and Secrets → Add → Type **Secret**, 이름 `GITHUB_TOKEN`, 값 = 1단계 토큰
- wrangler: `npx wrangler@4 secret put GITHUB_TOKEN` (프롬프트에 붙여넣기 — 명령줄 인자로 주지 않습니다)

### 4. 크론 등록

- 대시보드: Settings → Trigger Events(Triggers) → Add → Cron Triggers 에 `4,14,24,34,44,54 * * * *` 와 `17 0 * * *` 두 개
- wrangler: 2단계 `deploy` 가 `[triggers] crons` 를 같이 등록합니다
- 반영까지 최대 15분입니다

### 5. DRY_RUN 으로 확인 → 실제 전송

1. `DRY_RUN=1` 상태에서 Worker → Logs(실시간) 또는 Settings → Trigger Events 의 Past Events 를 확인합니다.
   10분마다 `[DRY_RUN] 보낼 dispatch: uptime.yml {"mode":"quick","source":"cf"}` 가 찍히고, KST 11:04 쯤엔 `"mode":"full"` 이 찍히면 정상입니다.
2. repo 변수를 만듭니다. Settings → Secrets and variables → Actions → Variables → **`SCHEDULER` = `cloudflare`**
   (`gh variable set SCHEDULER -b cloudflare -R thebluepigu/simparty-monitor`).
   Worker 가 아직 실제로 보내지 않으므로 이 순간에는 GitHub schedule run 이 대비책으로 돌고, 로그에 "Worker 실행 없음" 경고가 찍힙니다.
3. Worker 변수 `DRY_RUN` 을 `0` 으로 바꿉니다(대시보드는 저장하면 바로 반영, wrangler 는 toml 수정 후 deploy).
4. 확인:

```bash
gh run list -R thebluepigu/simparty-monitor --event workflow_dispatch --limit 10   # 'uptime · cf · quick' 이 10분마다
gh run list -R thebluepigu/simparty-monitor --workflow uptime.yml --event schedule --limit 5
#   → GitHub schedule run 은 success 지만 '정기 실행 중복 확인' 로그에 "건너뜀" — 체크 스텝 skipped
```

다음 날 09:17 쯤 브리프가 오면 끝입니다. 브리프의 "최근 24h 정기 실행" 이 144 근처로 올라가야 합니다.

## 되돌리기

1. repo 변수 `SCHEDULER` 를 지우거나 `github` 으로 둡니다(`gh variable delete SCHEDULER -R thebluepigu/simparty-monitor`).
   이것만으로 GitHub schedule 이 다시 주 경로가 됩니다.
2. Worker 의 크론 트리거를 지웁니다(대시보드 Trigger Events 에서 삭제, 또는 `crons = []` 로 deploy). Worker 자체를 지워도 됩니다.
   1만 하고 2를 안 하면 uptime 이 두 갈래로 돕니다. 해롭지는 않지만(직렬화 + 이슈 마커 + 45분 DB 가드) 낭비입니다.
   브리프는 Worker run 쪽이 "오늘 이미 보냄"을 확인하므로 그래도 하루 1통입니다.
3. PAT 를 GitHub 에서 Revoke 합니다.

워크플로 코드는 되돌릴 필요가 없습니다. `SCHEDULER` 가 없으면 예전과 똑같이 동작합니다.

## 개발

```bash
node --check scheduler/worker.js
node --test scheduler/worker.test.mjs        # 크론→dispatch 매핑·재시도·토큰 미노출 (가짜 fetch, 네트워크 없음)
bash .github/scripts/tests/ci-check.sh       # 위 두 개 + 대비책·heartbeat 테스트까지 (CI 와 같은 명령)
```

크론을 바꾸면 `wrangler.toml` 의 `crons` 와 `worker.js` 의 `UPTIME_CRON`·`BRIEF_CRON` 을 같이 바꿉니다.
다르면 Worker 가 "알 수 없는 크론" 을 로그에 남기고 아무것도 보내지 않으며, 테스트도 실패합니다.
