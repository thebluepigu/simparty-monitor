# simparty-monitor

simparty 서비스(의상 대여 플랫폼)의 **외부 감시 전용** repo 입니다. GitHub Actions 스케줄로 BE·FE 가 살아 있는지와
Neon(PostgreSQL) 사용량을 확인하고, 이상이 있으면 텔레그램으로 알립니다. 앱 코드와 설정은 이 repo 에 없습니다.
앱 repo(BE·FE)는 private 입니다.

## 감시 대상과 주기

| 워크플로 | cron (UTC) | KST | 하는 일 | DB 경유 |
|---|---|---|---|---|
| `uptime.yml` quick | `14,24,34,44,54 * * * *` | 매시 14·24·34·44·54분 | BE `/actuator/health/liveness` + FE `/robots.txt`(엣지 캐시 우회) | 아니오 |
| `uptime.yml` quick | `4 0-1,15-23 * * *` | 00:04~10:04 매시 04분 | 위와 같음 | 아니오 |
| `uptime.yml` full | `4 2-14 * * *` | 11:04~23:04 매시 04분 | quick + BE readiness·`/simparty/categories` + SSR 홈 | 예 (시간당 1회) |
| `neon-usage.yml` | `17 0 * * *` | 매일 09:17 | Neon 결제기간 사용량 브리프 (control plane API만, compute 를 깨우지 않음) | 아니오 |

- 업타임은 **10분 주기**로 하루 144회 돕니다(quick 131 + full 13). 세 cron 은 시각이 겹치지 않습니다.
- DB 를 건드리는 full 은 영업시간(KST 11~23시)에 시간당 1회만 돕니다. Neon compute 가 5분 무요청이면 잠드는데,
  감시가 그보다 자주 깨우면 compute 가 계속 켜져 과금되기 때문입니다. `uptime-mode.sh` 가 시간대 밖·재실행·
  최근 45분 안의 다른 full 실행이 있으면 full 을 quick 으로 낮춥니다.
- 감시 대상: `https://simparty.fly.dev`(BE, Fly.io) · `https://simparty.shop`(FE, Cloudflare Pages).
- ⏰ GitHub 무료 cron 은 지연·드롭이 심합니다(2026-10 실측: 09:17 브리프가 13~15시 도착, uptime 하루 5~13회).
  그래서 **Cloudflare Workers Cron 예약 실행기**(`scheduler/`)가 같은 시각에 워크플로를 `workflow_dispatch` 로 깨우는 경로를
  준비해 두었습니다. 위 GitHub cron 은 대비책으로 남습니다. 어느 쪽이 주 경로인지는 repo 변수 `SCHEDULER` 가 정합니다
  (없으면 `github` = 위 표 그대로). 전환·되돌리기 절차와 대비책 동작은 [`scheduler/README.md`](scheduler/README.md) 에 있습니다.

## 경보 규칙 요약

- 🔴 장애 감지: 체크가 실패하면(10초 뒤 1회 재시도 후에도 실패) 텔레그램 1건 + 장애 이슈 생성.
- 장애가 이어지면 **6시간마다** 재알림. 이번 장애에서 아직 알리지 않은 체크가 새로 실패하면 **확대** 1건(직전 알림 후 1시간 이상일 때).
- 🟢 복구: **연속 2회 전부 통과**해야 close. DB 경유 체크 실패는 full 재통과로만 close.
- 복구 후 6시간 안 재발은 같은 이슈를 재오픈. 12시간 안 2번째 재발은 🟡 1건(그 장애의 🟢 복구는 통과가 2시간 이어지면 옴),
  3번째부터는 재발을 바로 알리지 않고 직전 알림 6시간 뒤에만 다시 알림(알리지 않은 재발은 🟢 도 없음).
- 2026-10-30 신호등 개편 뒤 브리프 첫 줄이 🟡 가 되는 경우가 늘었습니다(의도): 예산의 80% 이상 예상 · 확인 불가(장애 이슈
  조회·DB 포함 점검 기록·저장소 커밋) · DB 자동 절전 판정 생략. 예전엔 이때도 첫 줄이 ✅ 였습니다. 예산 80% 🟡 를 끄려면
  `NEON_BUDGET_WARN_PCT=0`.
- 일일 브리프(Neon): 섹션 4개(사이트 / DB 사용량과 비용 / DB 자동 절전 / 감시 자체)마다 신호등을 붙이고, 첫 줄은
  그중 **가장 나쁜 색** + 한 문장 판정(여러 개면 "외 N건", 나머지는 바로 아래 "- 🟡 …" 줄)입니다. 판정은 `neon-usage.sh` 가
  `brief.json` 의 `.level` 에 한 번만 계산하고, 템플릿(HTML)·비상 plain 형식이 같은 값을 씁니다.
  - 🔴 문제: DB 자동 절전(autosuspend) 미작동 의심(24시간 중 상시가동 ≥ 90% 등) · 사이트 장애 중(열린 장애 이슈).
  - 🟡 주의: 기간 말 예상 비용이 예산 초과 또는 **예산의 80% 이상**(`NEON_BUDGET_WARN_PCT`, 0 = 끔. 판정은 화면에 보이는 정수 %
    그대로 — "(80%)" 로 보이면 🟡. `NEON_BUDGET_USD` 가 0 이하면 "예산 미설정" 으로 비교 안 함) · 사이트 점검 **정기** 성공이
    6시간 넘게 없거나 확인 불가 · DB 포함 점검(full) 성공이 36시간 넘게 없거나 기록 확인 불가 ·
    사이트 마지막 확인이 오래됨 — `SCHEDULER=cloudflare` 면 `SITE_FRESH_H`(3h) 초과, 기본(github)이면 6h 초과일 때만
    (github 는 cron 지연이 일상이라 3~6h 는 🟢 "열린 장애 이슈 없음 (마지막 확인 N시간 전 — GitHub 지연…)" 글자로만.
    실측 09-27~10-30: 브리프가 도착하는 13~15시의 약 절반이 3h 초과, 6h 초과 0회 — 3h 로 켜면 매일 🟡) ·
    감시 저장소 마지막 커밋 45일 이상 전 또는 확인 불가(아래 '60일 규칙') · 장애 이슈 조회 실패 ·
    DB 자동 절전 판정 생략(데이터 부족) · 24시간 점검 횟수(전체·DB 포함 점검 각각)가 예정의 N% 미만(`RUNS_WARN_PCT`, **기본 0 = 끔** —
    첫 줄 문장과 🟡 표시는 미달인 쪽만 가리킴).
  - `RUNS_WARN_PCT` 를 끄는 이유: GitHub 무료 cron 은 지연·드롭이 심해(실측 하루 5~13회 / 예정 144회) 켜면 매일 🟡 입니다.
    지금은 횟수를 "최근 24시간 점검 N번 / 예정 144번" 과 'GitHub 지연 — 감시 고장 아님' 설명 줄로만 보여 주고,
    Cloudflare 예약 실행(`SCHEDULER=cloudflare`)으로 바꾼 뒤 켭니다(예: 80).
  - 수동 test-alert 성공은 heartbeat 로 세지 않습니다(체크 없이 성공해 멈춘 스케줄을 가림). 기준은 repo variable
    `HB_UPTIME_MAX_H`·`HB_FULL_MAX_H`·`SITE_FRESH_H`(2026-10-13: 2h 는 매일 경보라 희석, 12h 는 밤사이 멈춘 감시를 놓쳐 6h).
  - 브리프 끝 줄은 다음 브리프 시각입니다. `SCHEDULER=cloudflare` 면 "다음 브리프: 내일 09:17", 그 외(기본 github)면
    "… 09:17 예정(지금은 GitHub 지연으로 오후에 올 수 있음)".
  - `NEON_BUDGET_WARN_PCT`·`RUNS_WARN_PCT`·`SCHEDULER`·`FULL_EVERY_HOURS` 는 repo variable 로 바꿉니다(`neon-usage.yml` 이 env 로
    내려 주고, 없으면 기본값 80 / 0 / github / 1). 예: `gh variable set RUNS_WARN_PCT -b 80 -R thebluepigu/simparty-monitor`.
  - `SCHEDULER=cloudflare` 인데 최근 60분 동안 Worker run 이 없으면 ⑤ 감시 자체가 🟡 "예약 실행기(Cloudflare)가 1시간 넘게 안 돌았어요"
    (GitHub 대비책으로 이어 돌지만 시각이 불규칙 — 토큰 만료부터 확인). `SCHEDULER` 값 오타도 🟡 입니다(github 으로 동작).
  - 장애·감시 실패 알림도 `SCHEDULER` 를 읽습니다(읽기만). 기본(github)이면 "10분 주기"·"약 10분 간격" 을 단정하지 않고
    "설계상 10분마다지만 지금은 GitHub 무료 스케줄 지연으로 몇 시간 간격이 될 수 있어요" 한 줄을 붙이고, cloudflare 면 10분 그대로 씁니다.
- 감시 자체가 실패하면 '감시 자체 실패' 🟡 텔레그램을 6시간에 1건 보냅니다. 수동 test-alert·preview 의 실패는 알림은 보내되
  6시간 억제 상태를 남기지 않습니다(진짜 감시 실패 알림을 가리지 않게).

## incident 이슈 상태머신

장애 상태는 이 repo 의 GitHub Issue 로 관리합니다. **감시(github-actions 봇)가 만든** 이슈 중 제목에 `[uptime] 장애 감지` 가
있고 라벨 `uptime-incident` 가 붙은 open 이슈가 "장애 중"입니다.

- **봇이 만든 `uptime-incident` 라벨 이슈만 상태로 인정하고, 외부 이슈는 무시합니다.** 공개 repo 라 누구나 같은 제목·본문
  마커로 이슈를 만들 수 있는데, 이를 상태로 읽으면 외부인이 경보·재오픈을 억제하거나 🟢 복구 알림을 스팸할 수 있기
  때문입니다. 작성자(github-actions 봇) AND 라벨 AND 제목 세 조건을 모두 봅니다(라벨은 triage 이상 권한자만 붙일 수 있음).
- 라벨을 만들 수 없으면(권한·API 이상) 이슈를 만들지 않고 감시 실패로 끝냅니다 — 라벨 없는 이슈는 상태로 인정하지 않으므로
  조용히 만들어 봐야 매 실행 새 이슈·🔴 가 반복될 뿐입니다. 실제 장애 중이면 '이슈 기록 실패' 문구의 🔴 를 직접 보내고,
  그 외엔 '감시 자체 실패' 🟡 텔레그램이 갑니다.
- 사람이 손으로 만든 이슈(제목을 똑같이 써도)는 감시가 읽지도 닫지도 않습니다.

 장애를 처음 감지하면 이슈를 만들고, 진행 중 상태(실패 집합·알린 체크·장애 시작 시각·
재오픈 기록·close 대기 등)는 **이슈 본문 끝의 HTML 주석 마커**에 기록합니다(본문 편집은 GitHub 알림이 가지 않습니다).
전부 통과하면 `pass-pending` 을 남기고 다음 실행도 통과하면 close 하며, 6시간 안에 재발하면 새 이슈 대신 재오픈합니다.
코멘트는 사람이 읽는 기록일 뿐 상태로 읽지 않습니다. **감시 이슈의 제목·라벨·본문 마커는 손으로 고치지 마세요**
(상태를 잃습니다). 사람이 쓰는 일반 이슈는 건드리지 않습니다.

## 필요한 설정

Settings → Secrets and variables → Actions → **Secrets** 에 등록합니다. 값은 이 repo 에 절대 커밋하지 않습니다.

| Secret | 용도 |
|---|---|
| `SIMPARTY_TELEGRAM_BOT_TOKEN` | 알림을 보내는 텔레그램 봇 토큰 |
| `SIMPARTY_TELEGRAM_CHAT_ID` | 알림을 받을 채팅(그룹) id |
| `SIMPARTY_NEON_API_KEY` | Neon control plane API 조회용 키 (`neon-usage.yml`) |

선택 **Variables**(없으면 기본값): `NEON_PROJECT_ID`(없으면 이름 `simparty` 로 검색), `NEON_BUDGET_USD`(15),
`NEON_CU_HOUR_USD`(0.106), `NEON_STORAGE_GB_USD`(0.35), `NEON_MIN_CU`(0.25), `REPO_IDLE_WARN_DAYS`(45),
`HB_UPTIME_MAX_H`(6), `HB_FULL_MAX_H`(36), `SITE_FRESH_H`(3),
`SCHEDULER`(`github` | `cloudflare`, 기본 github — 예약 실행 주 경로, `scheduler/README.md`),
`FULL_EVERY_HOURS`(1 — DB 경유(full) 체크 주기(시간). 1 = KST 11~23시 매시 13회 = 지금, 2 = 7회, 3 = 11·14·17·20·23시 5회,
0 = 안 함. `uptime-mode.sh` 가 Worker·GitHub schedule·수동 어느 경로든 같은 주기로 강제하고, 브리프의 "DB 포함 점검 예정 N번" 과
복구 안내의 다음 DB 체크 시각도 이 값을 씁니다).
Variables 값은 run 로그에 보이므로 비밀이 아닌 값만 둡니다.

## 왜 공개 repo 인가

- private repo 에서는 Actions 무료분(월 2,000분) 때문에 30분 주기로 돌렸고, GitHub cron 지연·드롭까지 겹쳐 실제 간격이
  60~110분이었습니다. 공개 repo 는 표준 러너 분이 무제한이라 10분 주기로 올릴 수 있습니다.
- 그래서 감시 코드만 떼어 공개합니다. 시크릿은 전부 Actions Secrets 에만 있고, 감시하는 URL 은 이미 공개된 주소입니다.
- 공개 repo 라 **run 로그·step summary·장애 이슈는 누구나 볼 수 있습니다.** 스크립트는 토큰을 로그에 찍지 않고,
  Neon 프로젝트·조직 id 는 로그에서 마스킹하고 step summary 에서는 아예 뺍니다.
- ⚠️ 공개 repo 는 60일 동안 활동이 없으면 스케줄이 꺼집니다 — 아래 '60일 규칙' 참고.
- 감시 워크플로(`uptime.yml`·`neon-usage.yml`)는 `schedule`·`workflow_dispatch` 로만 돌고, 수동 실행은 write 권한자만 할 수
  있습니다. `ci.yml`(문법·테스트)만 push·pull_request 로 돕니다 — 시크릿을 쓰지 않아 fork PR 에서 돌아도 안전합니다.

## 60일 규칙 (스케줄 자동 비활성)

공개 repo 는 **60일 동안 repo 활동이 없으면 GitHub 가 스케줄 워크플로를 자동으로 끕니다**(`uptime.yml`·`neon-usage.yml`
둘 다). 감시 코드는 한 번 자리 잡으면 몇 달씩 커밋이 없을 수 있어, 모르는 사이 감시가 꺼질 수 있습니다.

- **자동 빈 커밋(keepalive 워크플로)은 쓰지 않습니다.** 같은 방식의 공개 액션 repo 를 GitHub Staff 가 비활성화했고,
  60일 정책을 우회한다는 이유가 인용된 전례가 있습니다. 감시 repo 나 Actions 자체가 막히면 감시가 소리 없이 전부 멈춥니다.
  또 봇 커밋이 60일 타이머를 리셋한다는 공식 근거도 없습니다.
- 대신 **일일 브리프 '감시 자체' 문단**에 `감시 저장소 마지막 커밋 N일 전` 이 매일 찍힙니다(기본 브랜치 HEAD 커밋 시각).
  **45일 이상**이면 브리프 첫 줄이 🟡 가 되고 `사소한 커밋 1건 필요` 가 붙습니다.
  시각을 못 읽으면 `확인 불가 🟡` 로 표시합니다. 기준 일수는 repo variable `REPO_IDLE_WARN_DAYS`(기본 45).
- 🟡 가 보이면 **사람이** README 오타 수정·주석 보완 같은 사소한 커밋 1건을 기본 브랜치(`main`)에 push 합니다.
  45일부터 60일까지 약 15일 동안 매일 알림이 오므로 놓칠 여유가 있습니다.
- 이미 꺼졌다면(매일 09:17 에 오던 Neon 브리프가 끊기면 이 경우를 의심) Actions 탭에서 워크플로를 다시 켜거나 아래
  명령을 실행합니다. 켠 뒤 커밋 1건도 같이 해 두면 60일 타이머가 다시 넉넉해집니다.

```bash
gh workflow list -R thebluepigu/simparty-monitor --all        # 상태 확인 (disabled_inactivity = 60일 규칙으로 꺼짐)
gh workflow enable uptime.yml -R thebluepigu/simparty-monitor
gh workflow enable neon-usage.yml -R thebluepigu/simparty-monitor
```

## 배포 직후 확인

장애 상태는 검색 인덱스를 타지 않는 REST 이슈 목록(`GET /repos/…/issues?labels=uptime-incident`)으로 조회합니다
(`gh issue list --label` 은 gh 가 검색 API 로 보내 반영이 늦을 수 있어 쓰지 않습니다). 라벨이 아직 없을 때도 빈 배열이
오는지 repo 생성 직후 1회 확인하세요. `[]` 가 나오면 정상이고, 오류가 나면 첫 장애 때 감시가 이슈 조회 단계에서 실패합니다.

```bash
gh api "repos/thebluepigu/simparty-monitor/issues?state=open&labels=uptime-incident&per_page=100"
```

## 수동 실행

```bash
gh workflow run uptime.yml -R thebluepigu/simparty-monitor -f mode=test-alert   # 연동 확인 + 알림 서식 샘플 4종([샘플], 이슈·상태 미변경)
gh workflow run uptime.yml -R thebluepigu/simparty-monitor -f mode=quick        # DB 미경유 체크
gh workflow run uptime.yml -R thebluepigu/simparty-monitor -f mode=full         # DB 경유 (영업시간·시간당 1회로 자동 제한)
gh workflow run neon-usage.yml -R thebluepigu/simparty-monitor -f mode=preview  # 실데이터 브리프 [미리보기] (판정 기준점 저장 안 함)
gh workflow run neon-usage.yml -R thebluepigu/simparty-monitor -f mode=normal   # 정기 실행과 동일 (기준점 갱신)
```

수동 실행은 입력 `source` 가 기본값 `manual` 이라 브리프의 정기 실행 집계에 들어가지 않습니다. `source=cf` 는 Cloudflare
예약 실행기 전용이므로 손으로 고르지 마세요(정기 실행으로 세어 멈춘 감시를 가릴 수 있음).

## 텔레그램 메시지 조정

모든 텔레그램 본문은 `.github/scripts/telegram-format.sh` 한 파일에서 만듭니다(파일 머리의 '조정 가이드' 참고 — 어느 함수가
어떤 메시지인지, 줄바꿈·굵게 규칙). 호출부(`uptime.sh`·`neon-usage.sh`)는 값만 넘깁니다. `parse_mode=HTML` 로 보내며
동적 값은 전부 이스케이프하고, 태그가 깨져 텔레그램이 거부하면 태그를 벗긴 plain 으로 1회 다시 보냅니다.

1. 로컬에서 고치고 `bash .github/scripts/tests/telegram-format.test.sh` 로 렌더 전문·검사 결과 확인 (네트워크 호출 없음,
   `--plain` 은 텔레그램에 보이는 모습, `--quiet` 는 검사만)
2. **문구 한 줄만 바꾸는 미세 조정도** 작업 브랜치에 push 해 CI(`ci.yml` — 모든 `*.sh` 의 `bash -n`, 워크플로 YAML 파싱,
   위 테스트)가 초록인 것을 본 뒤 `main` 에 올립니다. 로컬에서는 `bash .github/scripts/tests/ci-check.sh` 가 같은 검사입니다.
3. push 후 `-f mode=preview`(브리프)·`-f mode=test-alert`(알림 4종)로 실제 텔레그램에서 확인

### 메시지 읽는 법 (2026-10-30 규칙)

- 상태 이모지는 신호등 셋뿐입니다: 🟢 정상·복구 / 🟡 주의(확인 필요 · 감시 자체 실패 · 장애·복구 반복) / 🔴 문제·장애.
  옛 기호(✅ ⚠️ 🟠 ≈ 🧪 ⏭)는 쓰지 않고, 근사치·판정 생략은 글자로 씁니다. test-alert 머리는 이모지 없이 "[샘플]".
- 브리프의 섹션 머리는 `🟢 사이트: 정상` 처럼 색이 맨 앞이라 왼쪽 끝만 훑어도 됩니다. 섹션 사이 빈 줄 1개.
- 줄 머리는 `- `, 한 줄 안 항목 구분은 ` / ` 입니다. 영어 식별자는 필요할 때 괄호로 한 번만 씁니다
  (서버 응답(liveness) / 화면 응답(robots) / DB 연결(readiness) / DB 사용량(CU-h) / DB 자동 절전(autosuspend)).
- 점검 묶음 이름은 어디서나 같습니다: quick = **빠른 점검**(서버 응답 / 화면 응답), full = **DB 포함 점검**(DB 연결 / 의상 API /
  홈 화면). "DB 연결" 은 readiness 하나만 가리킵니다. 비용·사용량은 "월말" 이 아니라 **기간 말**(Neon 결제 기간 끝) 기준입니다.
- 장애 알림의 점검 결과 표(`<pre>`)는 칸이 맞도록 ASCII 식별자 그대로 두고, 바로 아래 범례 한 줄로 한글 뜻을 붙입니다.
- 렌더 테스트(`telegram-format.test.sh`)가 모든 렌더·실제 전송 본문에서 옛 기호·줄 머리 `· `·` · ` 구분이 남았는지,
  브리프 섹션 머리가 전부 신호등으로 시작하는지, 첫 줄 색이 섹션 중 가장 나쁜 색인지를 검사합니다.

스케줄은 기본 브랜치(`main`)에 있는 워크플로 파일만 실행됩니다.

**템플릿이 깨져도 알림은 갑니다.** `monitor-lib.sh` 가 `telegram-format.sh` 를 `bash -n`·시험 source 로 먼저 확인하고, 실패하면
모든 메시지를 옛 plain 형식(제목 + 체크 표(통과 🟢 / 실패 🔴) + 이슈·run URL, 끝에 "[기본 형식] … 오류로 대체 전송" 표시)으로 보냅니다.
렌더 중 오류(변수 오타 등)·빈 출력도 그 메시지만 같은 plain 형식으로 대체하고, 빈 본문은 아예 보내지 않습니다.
이 경우 알림은 정상적으로 가지만 job 이 실패로 표시되어 GitHub 실패 메일과 '감시 자체 실패' 🟡(사유: 템플릿 오류)가 옵니다.
'감시 자체 실패' 스텝은 lib 를 서브셸에서 쓰고, 그것마저 실패하면 lib 없이 인라인 plain 으로 보냅니다.

## 구성

```
.github/
  workflows/uptime.yml       업타임 감시 (10분)
  workflows/neon-usage.yml   Neon 사용량 일일 브리프
  workflows/ci.yml           push·PR 검사 (bash -n · YAML · 템플릿·대비책 테스트 · Worker 테스트)
  scripts/schedule-gate.sh   정기 실행 중복 확인 (SCHEDULER=cloudflare 일 때 Worker 와 겹치는 schedule run 건너뜀)
  scripts/uptime-mode.sh     quick/full 모드 결정 (DB 보호)
  scripts/uptime.sh          체크 + 장애 이슈·텔레그램 상태머신
  scripts/neon-usage.sh      Neon API 조회 + 브리프
  scripts/monitor-lib.sh     공용 함수 (텔레그램 전송 — HTML·plain 재전송, 템플릿 오류 시 plain 대체, KST 시각)
  scripts/telegram-format.sh 텔레그램 메시지 템플릿 (모든 본문 — 조정은 여기만)
  scripts/tests/             템플릿 단위·고장 주입 테스트, 렌더 미리보기, 대비책·heartbeat 테스트, ci-check.sh + Neon fixture
scheduler/                   Cloudflare Workers Cron 예약 실행기 (worker.js 진입 · lib.js 로직 · wrangler.toml · 운영 절차 README)
```

⚠️ cron 문자열은 여러 곳이 같아야 합니다. full `4 2-14 * * *` 은 `uptime.yml` 의 `on.schedule`·`run-name`·
`uptime-mode.sh` 의 `FULL_CRON` 세 곳, quick 두 줄은 `on.schedule` 과 `QUICK_CRONS` 가 같아야 합니다.
Cloudflare 쪽은 `scheduler/wrangler.toml` 의 `crons` 와 `scheduler/lib.js` 의 `UPTIME_CRON`·`BRIEF_CRON` 이 같아야 합니다(테스트가 확인).

> 첫 스케줄 실행 확인용 push: 2026-09-27 22:15 KST (schedule 은 기본 브랜치 push 이후 활성화되는 경우가 있음)
