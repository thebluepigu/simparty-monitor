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

## 경보 규칙 요약

- 🔴 장애 감지: 체크가 실패하면(10초 뒤 1회 재시도 후에도 실패) 텔레그램 1건 + 장애 이슈 생성.
- 장애가 이어지면 **6시간마다** 재알림. 이번 장애에서 아직 알리지 않은 체크가 새로 실패하면 **확대** 1건(직전 알림 후 1시간 이상일 때).
- 🟢 복구: **연속 2회 전부 통과**해야 close. DB 경유 체크 실패는 full 재통과로만 close.
- 복구 후 6시간 안 재발은 같은 이슈를 재오픈. 12시간 안 2번째 재발은 🟠 1건, 그 뒤는 억제하고 통과가 2시간 이어져야 close.
- Neon 브리프: autosuspend 미작동 의심(24h 상시가동 ≥ 90% 등) 🔴, 기간말 예상 비용이 예산 초과·uptime 성공이 2시간 넘게 없음·
  DB 체크(full) 성공이 14시간 넘게 없음·저장소 마지막 커밋이 45일 이상 전 ⚠️ (아래 '60일 규칙').
- 감시 자체가 실패하면 '감시 자체 실패' 텔레그램을 6시간에 1건 보냅니다.

## incident 이슈 상태머신

장애 상태는 이 repo 의 GitHub Issue 로 관리합니다. **감시(github-actions 봇)가 만든** 이슈 중 제목에 `[uptime] 장애 감지` 가
있고 라벨 `uptime-incident` 가 붙은 open 이슈가 "장애 중"입니다.

- **봇이 만든 `uptime-incident` 라벨 이슈만 상태로 인정하고, 외부 이슈는 무시합니다.** 공개 repo 라 누구나 같은 제목·본문
  마커로 이슈를 만들 수 있는데, 이를 상태로 읽으면 외부인이 경보·재오픈을 억제하거나 🟢 복구 알림을 스팸할 수 있기
  때문입니다. 작성자(github-actions 봇) AND 라벨 AND 제목 세 조건을 모두 봅니다(라벨은 triage 이상 권한자만 붙일 수 있음).
- 라벨을 만들 수 없으면(권한·API 이상) 이슈를 만들지 않고 감시 실패로 끝냅니다 — 라벨 없는 이슈는 상태로 인정하지 않으므로
  조용히 만들어 봐야 매 실행 새 이슈·🔴 가 반복될 뿐입니다. 실제 장애 중이면 '이슈 기록 실패' 문구의 🔴 를 직접 보내고,
  그 외엔 '감시 자체 실패' ⚠️ 텔레그램이 갑니다.
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
`NEON_CU_HOUR_USD`(0.106), `NEON_STORAGE_GB_USD`(0.35), `NEON_MIN_CU`(0.25), `REPO_IDLE_WARN_DAYS`(45).
Variables 값은 run 로그에 보이므로 비밀이 아닌 값만 둡니다.

## 왜 공개 repo 인가

- private repo 에서는 Actions 무료분(월 2,000분) 때문에 30분 주기로 돌렸고, GitHub cron 지연·드롭까지 겹쳐 실제 간격이
  60~110분이었습니다. 공개 repo 는 표준 러너 분이 무제한이라 10분 주기로 올릴 수 있습니다.
- 그래서 감시 코드만 떼어 공개합니다. 시크릿은 전부 Actions Secrets 에만 있고, 감시하는 URL 은 이미 공개된 주소입니다.
- 공개 repo 라 **run 로그·step summary·장애 이슈는 누구나 볼 수 있습니다.** 스크립트는 토큰을 로그에 찍지 않고,
  Neon 프로젝트·조직 id 는 로그에서 마스킹하고 step summary 에서는 아예 뺍니다.
- ⚠️ 공개 repo 는 60일 동안 활동이 없으면 스케줄이 꺼집니다 — 아래 '60일 규칙' 참고.
- 워크플로는 `schedule`·`workflow_dispatch` 로만 돌고 PR 트리거가 없습니다. 수동 실행은 write 권한자만 할 수 있습니다.

## 60일 규칙 (스케줄 자동 비활성)

공개 repo 는 **60일 동안 repo 활동이 없으면 GitHub 가 스케줄 워크플로를 자동으로 끕니다**(`uptime.yml`·`neon-usage.yml`
둘 다). 감시 코드는 한 번 자리 잡으면 몇 달씩 커밋이 없을 수 있어, 모르는 사이 감시가 꺼질 수 있습니다.

- **자동 빈 커밋(keepalive 워크플로)은 쓰지 않습니다.** 같은 방식의 공개 액션 repo 를 GitHub Staff 가 비활성화했고,
  60일 정책을 우회한다는 이유가 인용된 전례가 있습니다. 감시 repo 나 Actions 자체가 막히면 감시가 소리 없이 전부 멈춥니다.
  또 봇 커밋이 60일 타이머를 리셋한다는 공식 근거도 없습니다.
- 대신 **Neon 일일 브리프 마지막 줄**에 `저장소 마지막 커밋 N일 전` 이 매일 찍힙니다(기본 브랜치 HEAD 커밋 시각).
  **45일 이상**이면 브리프 첫 줄이 ⚠️ 가 되고 `60일 무활동 시 스케줄 자동 비활성 — 사소한 커밋 1건 필요` 가 붙습니다.
  시각을 못 읽으면 `확인 불가 ⚠️` 로 표시합니다. 기준 일수는 repo variable `REPO_IDLE_WARN_DAYS`(기본 45).
- ⚠️ 가 보이면 **사람이** README 오타 수정·주석 보완 같은 사소한 커밋 1건을 기본 브랜치(`main`)에 push 합니다.
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
gh workflow run uptime.yml -R thebluepigu/simparty-monitor -f mode=test-alert   # 텔레그램 연동 확인 1건
gh workflow run uptime.yml -R thebluepigu/simparty-monitor -f mode=quick        # DB 미경유 체크
gh workflow run uptime.yml -R thebluepigu/simparty-monitor -f mode=full         # DB 경유 (영업시간·시간당 1회로 자동 제한)
gh workflow run neon-usage.yml -R thebluepigu/simparty-monitor                  # Neon 브리프
```

스케줄은 기본 브랜치(`main`)에 있는 워크플로 파일만 실행됩니다.

## 구성

```
.github/
  workflows/uptime.yml       업타임 감시 (10분)
  workflows/neon-usage.yml   Neon 사용량 일일 브리프
  scripts/uptime-mode.sh     quick/full 모드 결정 (DB 보호)
  scripts/uptime.sh          체크 + 장애 이슈·텔레그램 상태머신
  scripts/neon-usage.sh      Neon API 조회 + 브리프
  scripts/monitor-lib.sh     공용 함수 (텔레그램 전송·KST 시각)
```

⚠️ cron 문자열은 여러 곳이 같아야 합니다. full `4 2-14 * * *` 은 `uptime.yml` 의 `on.schedule`·`run-name`·
`uptime-mode.sh` 의 `FULL_CRON` 세 곳, quick 두 줄은 `on.schedule` 과 `QUICK_CRONS` 가 같아야 합니다.
