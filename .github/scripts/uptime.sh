#!/usr/bin/env bash
# 업타임 감시 본체. 사용: uptime.sh quick|full|test-alert
#
#   quick : DB 를 건드리지 않는 체크만 (liveness, robots.txt)
#   full  : quick + DB 경유 체크 (readiness, /simparty/categories, SSR 홈) — 시간당 1회·영업시간만 (uptime-mode.sh 가 강제)
#   test-alert : 체크 없이 텔레그램 연동 확인 메시지 1건
#
# 상태 머신 = GitHub Issue. **이 감시(github-actions 봇)가 만든** 이슈 중 제목에 '[uptime] 장애 감지' 가 있고
# label 'uptime-incident' 가 붙은 open 이슈가 "장애 중". 세 조건(봇 작성자 AND 라벨 AND 제목) 중 하나라도 빠지면(또는 PR 이면) 무시한다.
#   조회는 검색 인덱스를 타지 않는 REST 이슈 목록(gh api repos/…/issues?labels=…)으로만 — 자세한 근거는 '상태 조회' 절.
#   공개 repo 라 외부인도 같은 제목·본문 마커로 이슈를 만들 수 있다 → 작성자로 걸러 경보 억제·재오픈 억제·🟢 스팸을 막는다.
#   라벨은 triage 이상 권한자만 붙일 수 있어 2차 방어선. 라벨을 못 만들면 이슈를 만들지 않고 감시 실패로 처리한다
#   (라벨 없는 이슈는 상태로 인정하지 않으므로, 만들어 봐야 다음 실행이 못 찾아 매번 새 이슈·🔴 가 된다).
# 사람이 만든 일반 'incident' 이슈는 건드리지 않는다.
#
# 기계용 상태는 전부 이슈 **본문 마커**(gh issue edit — GitHub 알림 메일이 안 나감). 코멘트는 사람용 기록일 뿐 상태로 읽지 않는다.
#   <!-- failed: a,b -->       현재 실패 중인 체크 집합 (quick 실행이 full 전용 체크 실패를 잘못 "복구" 처리하지 않도록)
#   <!-- alerted: a,b -->      이번 장애(생성·재오픈 ~ close)에서 이미 텔레그램으로 알린 체크의 누적 집합. 새 이슈·재오픈 때
#                              그 시점 실패 집합으로 초기화(플래핑 억제로 텔레그램을 생략한 재오픈도 "알린 것"으로 본다),
#                              텔레그램을 보낼 때마다 합집합, close 때 제거. '장애 확대' = 지금 실패 − alerted.
#   <!-- seen: a,b -->         이번 장애에서 한 번이라도 실패한 체크의 누적 집합 (커질 때만 코멘트)
#   <!-- down-since: ISO -->   이번 장애 시작(생성·재오픈) 시각
#   <!-- reopens: ISO,ISO -->  최근 FLAP_WINDOW_SEC(12h) 안의 재오픈 시각 (재발 횟수·플래핑 판정)
#   <!-- flap-hold: 1 -->      이 재오픈이 12h 안 FLAP_REOPENS(2)번째 이상 = 플래핑 에피소드. close 까지 유지(12h 창이 흘러가도
#                              열려 있는 동안 강화가 풀리지 않게 — 풀리면 close→reopen 순환이 12h 마다 재시작)
#   <!-- tg-sent: ISO -->      🔴/🟠 텔레그램을 보낸 시각 (장애 지속 중 REMIND_HOURS(6)시간마다 재알림) — close 후에도 유지
#   <!-- tg-recovered: ISO --> 🟢 텔레그램을 보낸 시각 (풀리지 않은 🔴/🟠 가 있을 때만 🟢 를 보낸다) — close 후에도 유지
#   <!-- tg-attempt: ISO -->   텔레그램 전송 실패 시각. 재시도는 1시간에 1번 (텔레그램 고장 시 매 실행 job 실패 방지)
#   <!-- pass-pending: ISO --> 1차 전부 통과 시각. 다음 실행도 통과해야 close (close 히스테리시스)
#   <!-- pass-need: full -->   pass-pending 을 만든 실행이 full 이고 DB 경유 체크 실패를 해소한 것이면, close 도 full 실행의
#                              재통과로만 확정 (quick 은 DB 를 다시 보지 않으므로 DB 전용 장애의 히스테리시스가 1회로 무너짐 방지)
#
# 알림량 상한:
#   - 이슈 코멘트는 텔레그램을 보냈을 때와 seen(누적 실패 집합)이 커질 때만. 실패 집합이 줄거나 들쭉날쭉한 변화는
#     본문 마커 편집으로만 기록 (매 실행 코멘트 = GitHub 알림 메일 하루 144건+)
#   - 텔레그램 '장애 확대' 는 alerted 에 없던 체크가 새로 실패할 때만 → 같은 체크가 번갈아 실패해도 장애당 1번
#     (직전 텔레그램 후 1시간 이상일 때만. BE(liveness)가 alerted 면 BE 의존 체크(readiness·categories·홈)는 확대 아님)
#   - close 는 연속 2회 전부 통과 시에만. 12시간 안 재오픈이 FLAP_REOPENS(2)회 이상인 에피소드(flap-hold)는 통과가
#     FLAP_HOLD_MIN(120)분 이어져야 close → 90분 주기 장애·복구 반복이 close·reopen 이벤트를 무한히 만들지 않는다
#   - 복구 후 6시간 안 재발은 새 이슈 대신 재오픈. 12시간 안의 첫 재발 = 🔴, 두 번째 = 🟠 1건, 그 이후 억제
#     (장애가 이어지면 REMIND_HOURS 재알림은 유지). 재오픈·close 사실은 텔레그램을 보낸 경우에만 코멘트, 그 외는 본문 마커
#   - GitHub 이슈 API 가 죽어 상태 기록이 안 되는데 실제 장애가 있으면 🔴 를 바로 보낸다(간격 1h→3h→6h 로 늘림,
#     직전 시각·횟수는 SELFFAIL_DIR 에 저장 — 워크플로가 actions/cache 로 보관). 이때 '감시 자체 실패' 알림은 생략.
#     이번 실행에서 이미 🔴 를 보낸 뒤 상태 기록만 실패했으면 중복 🔴 를 보내지 않는다.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=monitor-lib.sh
source "$HERE/monitor-lib.sh"

MODE="${1:-quick}"
RUN_URL="${RUN_URL:-local}"
RETRY_DELAY="${RETRY_DELAY:-10}"
RETRY_MAX_TIME_FAST="${RETRY_MAX_TIME_FAST:-8}"   # 앞선 체크가 000(무응답)이면 이후 체크의 재시도 max-time (Actions 분 절약)
REMIND_HOURS="${REMIND_HOURS:-6}"
REOPEN_MINUTES="${REOPEN_MINUTES:-360}"
FLAP_WINDOW_SEC="${FLAP_WINDOW_SEC:-43200}"   # 재발 횟수를 세는 창 12시간
FLAP_REOPENS="${FLAP_REOPENS:-2}"             # 창 안 재오픈이 이 횟수 이상이면 close 강화
FLAP_HOLD_MIN="${FLAP_HOLD_MIN:-120}"         # 강화 시 close 에 필요한 연속 통과 지속 시간(분)
LABEL="uptime-incident"
TITLE_KEY="[uptime] 장애 감지"
FULL_ONLY="readiness,categories,home"         # full 에서만 도는 체크 = BE 의존 체크
FAIL_FILE="${RUNNER_TEMP:-/tmp}/monitor_fail_reason"
OUTAGE_FLAG="${RUNNER_TEMP:-/tmp}/monitor_outage_alerted"
SELFFAIL_DIR="${SELFFAIL_DIR:-.selffail}"

URL_LIVENESS="${URL_LIVENESS:-https://simparty.fly.dev/actuator/health/liveness}"
URL_ROBOTS="${URL_ROBOTS:-https://simparty.shop/robots.txt}"
URL_READINESS="${URL_READINESS:-https://simparty.fly.dev/actuator/health/readiness}"
URL_CATEGORIES="${URL_CATEGORIES:-https://simparty.fly.dev/simparty/categories}"
URL_HOME="${URL_HOME:-https://simparty.shop/}"

# 실패 사유 파일은 시작 시에만 비운다 (종료 시 비우면 tg_send 가 남긴 HTTP 코드·migrate 안내가 지워진다)
: > "$FAIL_FILE"
rm -f "$OUTAGE_FLAG"

STAGE="init"; DONE=0; FAILED_NOW=""; TABLE=""; NOW_KST="$(kst_now)"; TG_SENT_RUN=0
iso_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# 이슈 API 지속 실패 중 직접 🔴 간격: 직전 직접 알림 횟수 0→즉시, 1→1h, 2→3h, 3+→6h (24시간 조용하면 횟수 리셋)
selffail_interval() { case "$1" in 0) echo 0 ;; 1) echo 3600 ;; 2) echo 10800 ;; *) echo 21600 ;; esac; }
read_num() { local v; v="$(cat "$1" 2>/dev/null || echo 0)"; case "$v" in ''|*[!0-9]*) v=0 ;; esac; echo "$v"; }
record_direct_alert() {  # 직접 🔴(또는 이번 실행 🔴 후 상태 기록 실패) 시각·횟수 저장
  mkdir -p "$SELFFAIL_DIR" && echo "$1" > "$SELFFAIL_DIR/outage_last" && echo "$2" > "$SELFFAIL_DIR/outage_count"
  echo "state_dirty=1" >> "${GITHUB_OUTPUT:-/dev/null}"
}

# 비정상 종료(set -e 등) 시: 단계 기록 + (실제 장애가 있는데 상태 기록 단계에서 죽었으면) 🔴 직접 전송
on_exit() {
  local rc=$?
  [ "$DONE" = "1" ] && return 0
  [ "$rc" = "0" ] && return 0
  note_fail "uptime.sh 비정상 종료 (단계: ${STAGE}, rc=${rc}, failed_now=[${FAILED_NOW}])"
  if [ "$STAGE" = "state" ] && [ -n "$FAILED_NOW" ]; then
    local now last cnt gap
    now="$(date -u +%s)"
    last="$(read_num "$SELFFAIL_DIR/outage_last")"; cnt="$(read_num "$SELFFAIL_DIR/outage_count")"
    if [ $((now - last)) -ge 86400 ]; then cnt=0; fi
    if [ "$TG_SENT_RUN" = "1" ]; then
      # 이번 실행이 이미 🔴 를 보냈다 — 상태(tg-sent) 기록만 실패. 중복 🔴 금지, 다음 직접 알림 간격 계산에만 반영
      echo "::warning::텔레그램은 이미 전송됨 — 상태 기록 실패로 인한 중복 🔴 생략"
      record_direct_alert "$now" $((cnt + 1))
      # 본문 tg-sent 가 못 남았으니 전송 시각을 캐시 쪽에도 남긴다 → 다음 실행이 곧바로 6h 재알림하지 않게
      [ -z "$TG_AT" ] || echo "$TG_AT" > "$SELFFAIL_DIR/tg_sent_at"
      return 0
    fi
    gap="$(selffail_interval "$cnt")"
    if [ $((now - last)) -lt "$gap" ]; then
      echo "::warning::상태 기록 실패 + 장애 — 직전 직접 알림(${cnt}회째) 후 $((gap / 3600))시간 미만이라 생략"
    elif tg_send "🔴 simparty 장애 감지 (${NOW_KST} KST) — ⚠️ GitHub 이슈 기록 실패로 상태 추적 불가, 계속되면 1→3→6시간 간격으로 반복
${TABLE}
${RUN_URL}"; then
      record_direct_alert "$now" $((cnt + 1))
      : > "$OUTAGE_FLAG"
    fi
  fi
}
trap on_exit EXIT

# gh 는 GH_REPO 가 비면 현재 디렉터리의 git remote 로 떨어진다 — 로컬 테스트 중 엉뚱한 repo 에
# 이슈를 만드는 사고(검증 중 실제 발생) 방지를 위해 명시를 강제. 워크플로는 github.repository 를 넣는다.
if [ "$MODE" != "test-alert" ] && [ -z "${GH_REPO:-}" ]; then
  echo "::error::GH_REPO 미지정 — 대상 repo 를 명시해야 함"; note_fail "GH_REPO 미지정"; exit 2
fi

WORK="$(mktemp -d)"
RESULTS="$WORK/results.tsv"   # name \t ok(1/0) \t code \t time \t detail
: > "$RESULTS"

# 정상 종료 경로: 텔레그램 실패가 있었으면 job 을 실패로 표시 (재시도가 1시간 1회로 제한돼 실패 메일도 그 이하)
finish() {
  DONE=1
  # 상태 기록이 정상으로 돌아왔으면 직접 🔴 백오프 횟수 리셋 (값이 있을 때만 → 평소엔 캐시 저장 안 함)
  if [ "$MODE" != "test-alert" ] && [ "$(read_num "$SELFFAIL_DIR/outage_count")" != "0" ]; then
    mkdir -p "$SELFFAIL_DIR" && echo 0 > "$SELFFAIL_DIR/outage_count"
    echo "state_dirty=1" >> "${GITHUB_OUTPUT:-/dev/null}"
  fi
  if [ "$TG_FAILED" = "1" ]; then
    note_fail "텔레그램 전송 실패 — 위 로그 참고"
    echo "::error::텔레그램 전송 실패가 있었음 — job 을 실패로 표시(GitHub 실패 메일 경로 확보)"
    exit 1
  fi
  exit 0
}

if [ "$MODE" = "test-alert" ]; then
  tg_send "🧪 test — simparty 업타임 감시 텔레그램 연동 확인 ($(kst_now) KST)
${RUN_URL}" || true
  if [ "$TG_FAILED" = "0" ]; then echo "텔레그램 test 전송 성공"; fi
  finish
fi
case "$MODE" in
  quick|full) ;;
  *) echo "::error::알 수 없는 mode: $MODE"; note_fail "알 수 없는 mode: $MODE"; exit 2 ;;
esac

# ---- 체크 -------------------------------------------------------------------
# $1 name, $2 url, $3 validator(status|readiness|nonempty_array), $4 follow(1=리다이렉트 추적)
# 네트워크 실패는 code=000 으로 기록하고 계속(set -e 에 죽지 않음).
# 실패 시 RETRY_DELAY 초 후 1회 재시도 — 일시 블립 오탐 방지.
# 앞선 체크가 000(무응답·타임아웃)으로 끝났으면 이후 체크의 재시도는 max-time 을 RETRY_MAX_TIME_FAST 로 줄인다
# (hang 형태 장애가 며칠 이어질 때 run 이 2~5분으로 불어 10분 주기 다음 run 과 겹치거나 대기열이 밀리는 것 방지).
# cf-cache-status 는 로그에만 남긴다 (엣지 캐시가 오리진 장애를 가리는지 사후 확인용).
STAGE="checks"
FAST_RETRY=0
run_check() {
  local name="$1" url="$2" validator="$3" follow="${4:-0}" body err hdr out code t detail ok attempt cache mt
  local -a opts=(-sS -A "$MONITOR_UA")
  if [ "$follow" = "1" ]; then opts+=(-L --max-redirs 3); fi
  body="$WORK/$name.body"; err="$WORK/$name.err"; hdr="$WORK/$name.hdr"
  for attempt in 1 2; do
    mt=20
    if [ "$attempt" = "2" ] && [ "$FAST_RETRY" = "1" ]; then mt="$RETRY_MAX_TIME_FAST"; fi
    : > "$hdr"
    out="$(curl "${opts[@]}" --max-time "$mt" -D "$hdr" -o "$body" -w '%{http_code} %{time_total}' "$url" 2>"$err")" || true
    code="${out%% *}"; t="${out#* }"
    if [ -z "$code" ] || [ "$code" = "$out" ]; then code="000"; t="0"; fi
    ok=0; detail=""
    if [ "$code" = "200" ]; then
      case "$validator" in
        status) ok=1 ;;
        readiness)
          if jq -e '.status == "UP"' "$body" >/dev/null 2>&1; then ok=1
          else detail="status!=UP: $(head -c 120 "$body" | tr '\n' ' ')"; fi ;;
        nonempty_array)
          if jq -e 'type == "array" and length >= 1' "$body" >/dev/null 2>&1; then ok=1
          else detail="JSON 배열이 비었거나 형식 오류"; fi ;;
      esac
    elif [ "$code" = "000" ]; then
      detail="네트워크 오류: $(head -c 160 "$err" 2>/dev/null | tr '\n' ' ')"
    else
      detail="HTTP ${code}"
    fi
    if [ "$ok" = "1" ]; then break; fi
    if [ "$attempt" = "1" ]; then sleep "$RETRY_DELAY"; fi
  done
  if [ "$ok" = "1" ]; then detail="ok"; [ "$attempt" = "2" ] && detail="ok (재시도 후)"; fi
  if [ "$ok" = "0" ] && [ "$code" = "000" ]; then FAST_RETRY=1; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$ok" "$code" "$t" "$detail" >> "$RESULTS"
  cache="$(grep -i '^cf-cache-status:' "$hdr" 2>/dev/null | tail -n 1 | cut -d: -f2 | tr -d ' \r' || true)"
  echo "[$name] ok=$ok code=$code time=${t}s cf-cache=${cache:--} $detail"
}

# robots.txt 는 Cloudflare Cache Rule 로 엣지에 ~4시간 캐시된다 (cf-cache-status: HIT 실측) → 그대로 부르면
# Pages Functions/Nitro 가 죽어도 200. 매번 다른 쿼리로 캐시를 비켜 오리진까지 도달시킨다.
# 이 라우트(FE 의 Nitro 서버 라우트)는 BE 를 호출하지 않으므로 DB 제약과 무관.
# (홈은 캐시를 비키면 Nitro swr 도 비켜 BE→DB 를 부를 수 있어 버스터를 붙이지 않는다 — full 전용·시간당 1회)
case "$URL_ROBOTS" in *\?*) ROBOTS_SEP="&" ;; *) ROBOTS_SEP="?" ;; esac
run_check liveness "$URL_LIVENESS" status
run_check robots   "${URL_ROBOTS}${ROBOTS_SEP}uptime=$(date -u +%s)" status
if [ "$MODE" = "full" ]; then
  run_check readiness  "$URL_READINESS"  readiness
  run_check categories "$URL_CATEGORIES" nonempty_array
  run_check home       "$URL_HOME"       status 1
fi

RAN="$(cut -f1 "$RESULTS" | paste -sd, -)"
FAILED_NOW="$(awk -F'\t' '$2=="0"{print $1}' "$RESULTS" | paste -sd, -)"
TABLE="$(awk -F'\t' '{printf "%s %s: %s (%ss) %s\n", ($2=="1"?"✅":"❌"), $1, $3, $4, $5}' "$RESULTS")"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### uptime ($MODE) $(kst_now) KST"; echo; echo '```'; echo "$TABLE"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi

# ---- 상태 조회 --------------------------------------------------------------
# gh 실패(권한·API 장애)는 set -e 로 종료 → on_exit 가 (장애 중이면) 🔴 직접 전송, 워크플로 '감시 자체 실패' 스텝이 알림.
STAGE="state"

# 이 감시가 관리하는 이슈인가: 봇 작성자 AND 전용 라벨 AND 제목 키 AND PR 아님 (하나라도 아니면 외부·사람 이슈로 보고 무시)
#
# 조회는 REST `GET /repos/{owner}/{repo}/issues` (gh api) 만 쓴다. `gh issue list --label …` 은 gh 가 GraphQL
#   search(query:"label:… state:open type:issue") 로 바꿔 보내(GH_DEBUG=api 실측 2026-09-27) **검색 인덱스**를 탄다.
#   인덱스 반영이 늦으면 방금 만든 장애 이슈를 못 찾아 중복 이슈·🔴, 방금 닫은 이슈를 open 으로 읽어 재발 처리 지연,
#   검색 장애가 이어지면 10분마다 새 이슈·🔴 가 쌓인다. REST 이슈 목록은 검색이 아니라 저장소 이슈를 직접 나열하므로
#   생성·close 직후 다음 실행에도 그대로 보인다. `labels=` 는 서버 측 필터 — 외부인이 제목을 맞춘 이슈를 100건 넘게
#   쏟아 per_page 창에서 봇 이슈를 밀어내는 것을 막는다(외부인은 라벨을 못 붙인다).
#   REST 이슈 목록엔 PR 도 섞여 나온다(.pull_request 필드 존재) → 제외.
#
# 작성자 (N3 단순화 근거): REST 는 작성자를 원본 그대로 준다 — GITHUB_TOKEN 으로 만든 이슈는
#   .user = {"login":"github-actions[bot]","type":"Bot"} (id 41898282). 예전 조건의 'app/github-actions'·is_bot 은
#   gh issue list 가 GraphQL 결과를 변환한 표현이라 REST 응답엔 나오지 않는다 → 조건을 REST 표현 하나로 줄였다.
#   - 사람 계정 login 엔 '[' ']' 를 쓸 수 없어 'github-actions[bot]' 을 흉내 낼 수 없고, type 도 "User" 다.
#   - 다른 GitHub App 봇은 type "Bot" 이라도 login 이 '<그 앱 slug>[bot]' 이라 다르다(slug 는 GitHub 전역 유일).
#   - 실패 방향: GitHub 가 REST 표현을 바꾸면 봇 이슈가 전부 걸러져 매 실행 새 이슈·🔴 가 난다 — 조용해지지 않고
#     시끄러워지는 쪽이라 경보 누락은 없다(발견 즉시 이 조건만 고치면 된다).
#   ⚠️ 서버 측 `creator=github-actions[bot]` 필터는 쓰지 않는다 — 봇 계정에 대한 동작을 실측하지 못했다. 클라이언트에서 거른다.
# 라벨: .labels[] 는 객체({name,…})지만 혹시 문자열이 와도 죽지 않게 `.name? // .`.
OWN_FILTER='select(
  (.pull_request == null)
  and ((.user.login // "") == "github-actions[bot]") and ((.user.type // "") == "Bot")
  and (((.labels // []) | map(.name? // .) | index($l)) != null)
  and ((.title // "") | contains($k)))'
# $1 state(open|closed), $2 추가 쿼리 → JSON 배열 (실패 = gh 비0 → set -e 로 종료 → on_exit)
#   페이지네이션 없이 첫 페이지(100건)만 — labels 서버 필터 덕에 봇 이슈만 남아 충분. 라벨이 아직 없을 때(첫 장애 전)
#   REST 는 오류 없이 [] 를 줄 것으로 보지만 repo 생성 전이라 미실측 → README '배포 직후 확인' 의 명령으로 1회 확인.
list_own_issues() {
  gh api "repos/${GH_REPO}/issues?state=$1&labels=${LABEL}&per_page=100$2"
}
# open 중 가장 오래된 것 = 이번 장애 (정상이라면 open 은 1건뿐)
ISSUE="$(list_own_issues open "&sort=created&direction=asc" \
  | jq -r --arg l "$LABEL" --arg k "$TITLE_KEY" "[.[] | $OWN_FILTER] | sort_by(.created_at) | .[0].number // empty")"

# 집합 연산 헬퍼 (쉼표 구분 문자열)
set_minus() { jq -rn --arg a "$1" --arg b "$2" '($a | split(",") | map(select(. != ""))) - ($b | split(",")) | join(",")'; }
set_union() { jq -rn --arg a "$1" --arg b "$2" '(($a | split(",")) + ($b | split(","))) | map(select(. != "")) | unique | join(",")'; }
set_norm()  { jq -rn --arg a "$1" '$a | split(",") | map(select(. != "")) | unique | join(",")'; }
set_has()   { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }
# $1 부터 $2(빈 값 = 지금)까지 분
minutes_between() { jq -rn --arg a "$1" --arg b "$2" '(if $b == "" then now else ($b | fromdateiso8601) end) as $e | (($e - ($a | fromdateiso8601)) / 60) | floor'; }
# 쉼표 구분 ISO 목록에서 최근 $2 초 이내만 남김 / 원소 수
recent_times() { jq -rn --arg l "$1" --argjson w "$2" '$l | split(",") | map(select(. != "") | select((now - fromdateiso8601) < $w)) | join(",")'; }
count_list() { if [ -z "$1" ]; then echo 0; else awk -F, '{print NF}' <<< "$1"; fi; }
# ISO 시각 a > b 인가 (빈 값 = 가장 과거)
ts_gt() { jq -rn --arg a "$1" --arg b "$2" 'def t: if . == "" then -1 else fromdateiso8601 end; if ($a | t) > ($b | t) then "yes" else "no" end'; }
ts_max() { if [ "$(ts_gt "$1" "$2")" = "yes" ]; then echo "$1"; else echo "$2"; fi; }
# 시각 $1 로부터 $2 시간 이상 지났나 (빈 값 = 지남)
hours_passed() { jq -rn --arg t "$1" --argjson h "$2" 'if $t == "" then "yes" elif (now - ($t | fromdateiso8601)) >= ($h * 3600) then "yes" else "no" end'; }

# 이슈 본문만 읽는다 (상태는 전부 본문 마커 — 코멘트 페이지네이션 불필요). VIEW 는 REST 이슈 객체의 부분집합 —
# 필드명도 REST 그대로(number·html_url·created_at·body) 둬 목록 조회(list_own_issues)와 표현을 하나로 맞춘다.
load_view() {
  gh api "repos/${GH_REPO}/issues/$1" > "$WORK/issue_raw.json"
  jq '{number, html_url, created_at, body: (.body // "")}' "$WORK/issue_raw.json" > "$VIEW"
}
# 본문 마커 읽기 / 일괄 쓰기. 쓰기는 "$1 issue, 이후 key value 쌍"(값 빈 문자열 = 제거), 바뀐 게 없으면 편집 생략.
# 본문 편집은 GitHub 알림을 보내지 않는다. 값은 공백 없는 토큰(집합·ISO 목록)만.
body_marker() { jq -r --arg k "$1" '[(.body // "") | capture("<!-- " + $k + ": (?<v>[^ ]+) -->") | .v] | last // empty' "$VIEW"; }
set_body_markers() {
  local issue="$1"; shift
  local nb="$WORK/body.new" changed=0 i
  local -a kv=("$@")
  for ((i = 0; i < ${#kv[@]}; i += 2)); do
    if [ "$(body_marker "${kv[i]}")" != "${kv[i + 1]}" ]; then changed=1; fi
  done
  if [ "$changed" = "0" ]; then return 0; fi
  jq -j '(.body // "") as $b0 | $ARGS.positional as $kv
     | reduce range(0; ($kv | length); 2) as $i ($b0;
         gsub("\n?<!-- " + $kv[$i] + ": [^ ]+ -->"; "") | sub("\\s+$"; "")
         | if $kv[$i + 1] == "" then . else . + "\n<!-- " + $kv[$i] + ": " + $kv[$i + 1] + " -->" end)' \
    "$VIEW" --args "$@" > "$nb"
  gh issue edit "$issue" --body-file "$nb" >/dev/null
  jq --rawfile b "$nb" '.body = $b' "$VIEW" > "$VIEW.tmp" && mv "$VIEW.tmp" "$VIEW"
}
# 사람용 코멘트 — 상태가 아니므로 실패해도 job 을 죽이지 않는다 (상태는 이미 본문에 기록됨)
comment() { gh issue comment "$1" --body "$2" >/dev/null || echo "::warning::이슈 #$1 코멘트 실패 (상태는 본문 마커에 기록됨)"; }
# 텔레그램. 성공 시 TG_SENT_RUN=1(트랩 중복 🔴 방지)·TG_AT=지금, 실패 시 ATTEMPT_AT=지금. 성공 0 / 실패 1
TG_AT=""; ATTEMPT_AT=""
alert() {
  if tg_send "$1"; then TG_SENT_RUN=1; TG_AT="$(iso_now)"; return 0; fi
  ATTEMPT_AT="$(iso_now)"; return 1
}
# 텔레그램 결과 마커 key/value 를 TGM 배열에 (성공: tg-sent, 실패: tg-attempt)
tg_markers() {
  TGM=()
  if [ -n "$TG_AT" ]; then TGM+=(tg-sent "$TG_AT"); fi
  if [ -n "$ATTEMPT_AT" ]; then TGM+=(tg-attempt "$ATTEMPT_AT"); fi
}

VIEW="$WORK/issue.json"
# 텔레그램은 보냈는데 본문 기록이 실패했던 실행이 캐시에 남긴 전송 시각 (ISO 형식이 아니면 무시)
LOCAL_TG="$(cat "$SELFFAIL_DIR/tg_sent_at" 2>/dev/null || true)"
case "$LOCAL_TG" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;; *) LOCAL_TG="" ;; esac

if [ -z "$ISSUE" ]; then
  if [ -z "$FAILED_NOW" ]; then
    echo "정상 · 장애 이슈 없음 — 조용히 종료"
    finish
  fi
  NOW_ISO="$(iso_now)"
  FN="$(set_norm "$FAILED_NOW")"

  # ---- 복구 후 REOPEN_MINUTES 안의 재발 → 새 이슈 대신 재오픈 (플래핑 알림 폭주 방지) ----
  # 닫힌 봇 이슈는 생성순 = close 순이다(open 은 한 번에 1건, 재오픈은 가장 최근 close 건만·6h 안) → sort=created desc 의
  # 첫 페이지면 충분. sort=updated 는 외부인 코멘트로 옛 이슈를 끌어올려 창을 밀어낼 수 있어 쓰지 않는다.
  REOPEN="$(list_own_issues closed "&sort=created&direction=desc" \
    | jq -r --arg l "$LABEL" --arg k "$TITLE_KEY" --argjson w "$((REOPEN_MINUTES * 60))" \
        "[.[] | $OWN_FILTER | select(.closed_at != null) | select((now - (.closed_at | fromdateiso8601)) < \$w)]
         | sort_by(.closed_at) | last | .number // empty")"
  if [ -n "$REOPEN" ]; then
    gh issue reopen "$REOPEN" >/dev/null
    load_view "$REOPEN"
    ISSUE_URL="$(jq -r '.html_url' "$VIEW")"
    LAST_TG="$(ts_max "$(body_marker tg-sent)" "$LOCAL_TG")"
    REOPENS="$(recent_times "$(body_marker reopens)" "$FLAP_WINDOW_SEC")"
    REOPENS_WIN="$(count_list "$REOPENS")"
    MARK=""
    if [ "$REOPENS_WIN" = "0" ]; then
      if alert "🔴 simparty 장애 재발 (${NOW_KST} KST, 복구 후 $((REOPEN_MINUTES / 60))시간 안)
${TABLE}
이슈: ${ISSUE_URL}"; then MARK="📨 텔레그램 재발 알림"; fi
    elif [ "$REOPENS_WIN" = "1" ]; then
      if alert "🟠 simparty 장애·복구 반복 (${NOW_KST} KST) — 12시간 안 재발 2회째
이후 재발·복구 텔레그램은 억제하고, 장애가 이어지면 ${REMIND_HOURS}시간마다만 재알림합니다.
${TABLE}
이슈: ${ISSUE_URL}"; then MARK="📨 텔레그램 반복 알림"; fi
    elif [ "$(hours_passed "$LAST_TG" "$REMIND_HOURS")" = "yes" ]; then
      if alert "🔴 simparty 장애 반복 중 (${NOW_KST} KST, ${REMIND_HOURS}시간 재알림)
${TABLE}
이슈: ${ISSUE_URL}"; then MARK="📨 텔레그램 재알림"; fi
    else
      echo "플래핑 억제 — 12시간 내 이전 재발 ${REOPENS_WIN}회, 텔레그램 생략"
    fi
    # 새 장애 에피소드: 누적 집합 초기화. 텔레그램을 생략(억제)했어도 지금 실패 집합은 alerted 로 본다
    # (그러지 않으면 다음 실행이 같은 체크를 '장애 확대' 로 알려 억제가 무력화된다)
    # 12h 안 FLAP_REOPENS 번째 이상 재오픈 = 플래핑 에피소드 → close 강화를 close 까지 고정(flap-hold)
    HOLD=""; if [ $((REOPENS_WIN + 1)) -ge "$FLAP_REOPENS" ]; then HOLD=1; fi
    tg_markers
    set_body_markers "$REOPEN" failed "$FN" alerted "$FN" seen "$FN" down-since "$NOW_ISO" \
      reopens "$(set_union "$REOPENS" "$NOW_ISO")" flap-hold "$HOLD" pass-pending "" pass-need "" "${TGM[@]}"
    # 재오픈 사실 자체는 본문(reopens)·GitHub 타임라인에 남는다. 코멘트는 텔레그램을 보냈을 때만
    if [ -n "$MARK" ]; then
      comment "$REOPEN" "$(printf '🔁 재발 — 이슈 재오픈 (%s KST, %s) · %s\n\n```\n%s\n```\n\nrun: %s' \
        "$NOW_KST" "$MODE" "$MARK" "$TABLE" "$RUN_URL")"
    fi
    echo "재발 — 이슈 #$REOPEN 재오픈 (12시간 내 이전 재발 ${REOPENS_WIN}회)"
    finish
  fi

  # ---- 신규 장애 ----
  # 라벨 없이는 이슈를 만들지 않는다 — 라벨 없는 이슈는 OWN_FILTER 가 상태로 인정하지 않아 다음 실행마다 새 이슈·🔴 가
  # 반복된다. issues: write 면 생성(--force = 이미 있으면 갱신)이 성공하므로, 실패 = 권한·API 이상 → 감시 실패로 종료.
  # (STAGE=state + 실패 체크 있음 → on_exit 가 '⚠️ GitHub 이슈 기록 실패' 문구의 🔴 를 1→3→6h 백오프로 직접 전송,
  #  백오프로 생략되면 워크플로 '감시 자체 실패' 스텝이 ⚠️ 텔레그램(6h 1건). 어느 쪽이든 job 은 실패 → GitHub 실패 메일)
  if ! LABEL_ERR="$(gh label create "$LABEL" --color B60205 --description "업타임 감시 전용: open = 장애 중 (감시가 자동 open/close)" --force 2>&1 >/dev/null)"; then
    echo "::error::label '$LABEL' 생성 실패 — 라벨 없는 장애 이슈는 만들지 않음 (권한 issues: write 확인): ${LABEL_ERR:0:200}"
    note_fail "라벨 '$LABEL' 생성 실패 → 장애 이슈 미생성 (실패 체크: ${FN}). issues: write 권한 확인: ${LABEL_ERR:0:200}"
    exit 1
  fi
  TITLE="🔴 ${TITLE_KEY} ${NOW_KST} KST"
  BODY="$(printf '업타임 감시(%s)가 장애를 감지했습니다.\n\n```\n%s\n```\n\nrun: %s\n\n이 이슈가 open 인 동안 = 장애 중. 실패 체크가 연속 2회 전부 통과하면 감시가 자동으로 close 합니다.\n이 이슈의 제목·라벨·본문 끝 주석 마커를 바꾸면 감시가 상태를 잃습니다.\n\n<!-- failed: %s -->\n<!-- alerted: %s -->\n<!-- seen: %s -->\n<!-- down-since: %s -->\n' \
    "$MODE" "$TABLE" "$RUN_URL" "$FN" "$FN" "$FN" "$NOW_ISO")"
  # 생성 실패는 set -e 로 종료 → on_exit (위와 같은 감시 실패 경로). 라벨 없이 재시도하지 않는다
  URL="$(gh issue create --title "$TITLE" --body "$BODY" --label "$LABEL")"
  NUM="${URL##*/}"
  echo "장애 이슈 생성: $URL"
  alert "🔴 simparty 장애 감지 (${NOW_KST} KST)
${TABLE}
이슈: ${URL}" || true
  # 이슈 생성 자체가 GitHub 알림 1건 — 전송 결과는 본문 마커로만 (코멘트 생략)
  load_view "$NUM"
  tg_markers
  if [ "${#TGM[@]}" != "0" ]; then set_body_markers "$NUM" "${TGM[@]}"; fi
  finish
fi

# ---- 장애 진행 중 -----------------------------------------------------------
load_view "$ISSUE"
ISSUE_URL="$(jq -r '.html_url' "$VIEW")"
CREATED="$(jq -r '.created_at' "$VIEW")"
PREV_FAILED="$(body_marker failed)"
ALERTED="$(body_marker alerted)"
SEEN="$(body_marker seen)"
LAST_TG="$(ts_max "$(body_marker tg-sent)" "$LOCAL_TG")"
LAST_OK_TG="$(body_marker tg-recovered)"
LAST_ATTEMPT="$(body_marker tg-attempt)"
PENDING="$(body_marker pass-pending)"
PASS_NEED="$(body_marker pass-need)"
DOWN_SINCE="$(body_marker down-since)"; DOWN_SINCE="${DOWN_SINCE:-$CREATED}"
REOPENS="$(recent_times "$(body_marker reopens)" "$FLAP_WINDOW_SEC")"
REOPENS_WIN="$(count_list "$REOPENS")"
FLAPPY="$(body_marker flap-hold)"

# 이번 실행에서 확인하지 못한 체크(quick 실행 시 full 전용)는 직전 실패 상태를 유지.
# 단 pass-pending 이 있으면 직전 실행이 "모든 실패 체크 통과"를 이미 확인했으므로 이월할 것이 없다.
if [ -n "$PENDING" ]; then CARRY=""; else CARRY="$(set_minus "$PREV_FAILED" "$RAN")"; fi
FAILED_SET="$(set_union "$CARRY" "$FAILED_NOW")"
echo "issue #$ISSUE prev_failed=[$PREV_FAILED] ran=[$RAN] failed_now=[$FAILED_NOW] pending=[$PENDING/$PASS_NEED] alerted=[$ALERTED] reopens12h=$REOPENS_WIN flap-hold=[$FLAPPY] => [$FAILED_SET]"

if [ -z "$FAILED_SET" ]; then
  if [ -z "$PENDING" ]; then
    # ---- 1차 전부 통과: close 보류 (히스테리시스). 본문 편집이라 GitHub 알림 없음 ----
    # full 실행이 DB 경유 체크 실패를 해소했다면 close 확정도 full 재통과로만 (quick 은 DB 를 안 본다)
    NEED=""
    if [ "$MODE" = "full" ] && [ "$(set_minus "$PREV_FAILED" "$FULL_ONLY")" != "$(set_norm "$PREV_FAILED")" ]; then NEED="full"; fi
    set_body_markers "$ISSUE" pass-pending "$(iso_now)" pass-need "$NEED" failed ""
    echo "전부 통과(1차${NEED:+ · DB 경유 체크 해소 — full 재통과 필요}) — 다음 실행도 통과하면 close. 대기"
    finish
  fi
  if [ "$PASS_NEED" = "full" ] && [ "$MODE" != "full" ]; then
    echo "DB 경유 체크 해소 확인 대기 — quick 은 DB 를 안 보므로 다음 full 실행의 재통과로 close"
    finish
  fi
  HELD="$(minutes_between "$PENDING" "")"
  if [ "$FLAPPY" = "1" ] && [ "$HELD" -lt "$FLAP_HOLD_MIN" ]; then
    echo "플래핑 에피소드(12시간 안 재오픈 ${FLAP_REOPENS}회 이상) — 통과 ${HELD}분 지속, ${FLAP_HOLD_MIN}분 이어져야 close. 대기"
    finish
  fi
  # ---- 복구 확정 ----
  MIN="$(minutes_between "$DOWN_SINCE" "$PENDING")"
  OK_AT=""
  # 🟢 는 풀리지 않은 🔴/🟠 가 있을 때만 (플래핑 억제로 🔴 를 생략했다면 🟢 도 생략)
  if [ "$(ts_gt "$LAST_TG" "$LAST_OK_TG")" = "yes" ]; then
    FLAP_NOTE=""
    if [ "$REOPENS_WIN" != "0" ]; then FLAP_NOTE="
(최근 12시간 재발 ${REOPENS_WIN}회 — 반복되면 재발·복구 알림은 억제됨)"; fi
    if alert "🟢 simparty 복구 (다운 약 ${MIN}분, ${NOW_KST} KST 확인)${FLAP_NOTE}
${ISSUE_URL}"; then OK_AT="$TG_AT"; TG_AT=""; fi
  else
    echo "알리지 않은 장애(플래핑 억제·전송 실패) — 🟢 텔레그램 생략"
  fi
  tg_markers
  OKM=(); if [ -n "$OK_AT" ]; then OKM=(tg-recovered "$OK_AT"); fi
  set_body_markers "$ISSUE" pass-pending "" pass-need "" failed "" alerted "" seen "" down-since "" flap-hold "" \
    reopens "$REOPENS" "${OKM[@]}" "${TGM[@]}"
  # close 사실은 GitHub 타임라인에 남는다. 코멘트는 🟢 텔레그램을 보냈을 때만
  if [ -n "$OK_AT" ]; then
    comment "$ISSUE" "$(printf '🟢 복구 (%s KST 확인, 다운 약 %s분) · 📨 텔레그램 복구 알림\n\n```\n%s\n```\n\nrun: %s' "$NOW_KST" "$MIN" "$TABLE" "$RUN_URL")"
  fi
  gh issue close "$ISSUE" >/dev/null
  echo "복구 — 이슈 #$ISSUE close (다운 약 ${MIN}분)"
  finish
fi

# 여전히 (이월 포함) 실패. 텔레그램 규칙(우선순위 순, 이번 실행에서 실제로 실패가 보였을 때만):
#   (1) 직전 알림이 전송 실패(tg-attempt > tg-sent)였으면 1시간 뒤 재시도
#   (2) 마지막 🔴 후 REMIND_HOURS 경과 → 재알림 (직전 전송 실패 후 1시간 이내면 보류)
#   (3) 이번 장애에서 아직 알리지 않은 체크(alerted 밖)가 새로 실패(악화) → 확대 알림 (직전 텔레그램/시도 후 1시간 이상일 때만)
# 코멘트는 텔레그램을 보냈을 때와 seen(누적 실패 집합)이 커질 때만. 그 외 변화는 본문 마커로만.
HEAD=""
NEW_FAILS=""
if [ -n "$FAILED_NOW" ]; then
  NEW_FAILS="$(set_minus "$FAILED_NOW" "$ALERTED")"
  # BE(liveness)를 이미 알렸으면 BE 의존 체크(readiness·categories·SSR 홈)의 신규 실패는 당연한 결과라 '확대'가 아니다
  if set_has "$ALERTED" liveness; then NEW_FAILS="$(set_minus "$NEW_FAILS" "$FULL_ONLY")"; fi
  LAST_ANY="$(ts_max "$LAST_TG" "$LAST_ATTEMPT")"
  ATTEMPT_OK="$(hours_passed "$LAST_ATTEMPT" 1)"
  MIN="$(minutes_between "$DOWN_SINCE" "")"
  if [ "$(ts_gt "$LAST_ATTEMPT" "$LAST_TG")" = "yes" ] && [ "$ATTEMPT_OK" = "yes" ]; then
    HEAD="🔴 simparty 장애 지속 (다운 약 ${MIN}분, ${NOW_KST} KST — 직전 알림 전송 실패분 재시도)"
  elif [ "$(hours_passed "$LAST_TG" "$REMIND_HOURS")" = "yes" ] && [ "$ATTEMPT_OK" = "yes" ]; then
    HEAD="🔴 simparty 장애 지속 (다운 약 ${MIN}분, ${NOW_KST} KST)"
  elif [ -n "$NEW_FAILS" ] && [ "$(hours_passed "$LAST_ANY" 1)" = "yes" ]; then
    HEAD="🔴 simparty 장애 확대 — 새로 실패: ${NEW_FAILS} (다운 약 ${MIN}분, ${NOW_KST} KST)"
  fi
fi
SENT=0
if [ -n "$HEAD" ]; then
  if alert "${HEAD}
${TABLE}
이슈: ${ISSUE_URL}"; then SENT=1; fi
fi
NEW_ALERTED="$(set_norm "$ALERTED")"
if [ "$SENT" = "1" ]; then NEW_ALERTED="$(set_union "$ALERTED" "$FAILED_NOW")"; fi
NEW_SEEN="$(set_union "$SEEN" "$FAILED_SET")"
SEEN_ADDED="$(set_minus "$NEW_SEEN" "$SEEN")"
# 실패가 다시 보이면 close 보류 취소 (본문 편집 — 알림 없음)
PEND_ARGS=()
if [ -n "$PENDING" ] && [ -n "$FAILED_NOW" ]; then PEND_ARGS=(pass-pending "" pass-need ""); echo "1차 통과 후 재실패 — close 보류 취소"; fi
tg_markers
set_body_markers "$ISSUE" failed "$(set_norm "$FAILED_SET")" alerted "$NEW_ALERTED" seen "$NEW_SEEN" "${PEND_ARGS[@]}" "${TGM[@]}"

if [ "$SENT" = "1" ] || [ -n "$SEEN_ADDED" ]; then
  NOTE=""
  if [ "$SENT" = "1" ]; then NOTE=" · 📨 텔레그램 알림"; fi
  if [ -n "$SEEN_ADDED" ]; then NOTE="${NOTE} · 이번 장애 첫 실패: ${SEEN_ADDED}"; fi
  comment "$ISSUE" "$(printf '❌ 여전히 실패 (%s KST, %s)%s\n\n```\n%s\n```\n\nrun: %s' "$NOW_KST" "$MODE" "$NOTE" "$TABLE" "$RUN_URL")"
elif [ -z "$FAILED_NOW" ]; then
  # 이번 체크는 전부 통과했지만 full 전용 체크 실패가 아직 재확인 전 → 다음 full 실행까지 대기
  echo "이번 체크 통과, 미확인 실패 체크 [$CARRY] 는 다음 full 실행에서 판정 — 대기"
else
  echo "장애 지속 · 실패 [$FAILED_SET] · 알린 집합 [$NEW_ALERTED] · 알림 조건 아님 — 코멘트 생략(본문 마커·step summary 에만 기록)"
fi
finish
