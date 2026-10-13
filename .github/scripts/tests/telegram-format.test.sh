#!/usr/bin/env bash
# 텔레그램 템플릿 로컬 검증 + 렌더 미리보기. 네트워크·GitHub·텔레그램·Neon 호출 없음(전부 fixture).
#
#   bash .github/scripts/tests/telegram-format.test.sh            # 단위 테스트 + 렌더 전문 출력
#   bash .github/scripts/tests/telegram-format.test.sh --quiet    # 단위 테스트·렌더 검사만 (CI·커밋 전)
#   bash .github/scripts/tests/telegram-format.test.sh --plain    # 렌더를 텔레그램에 보이는 모습(태그 제거)으로 출력
#
# 검사: html_escape·html_to_plain 단위 / 모든 렌더의 HTML 이 허용 태그(b i code pre a)만 짝 맞게 쓰는지·
#       이스케이프 안 된 & < > 가 없는지·4096자 이내인지 / tg_send 의 "can't parse entities" → plain 1회 재전송 /
#       렌더 가드(오타·빈 출력 → plain 비상 메시지)·빈 본문 미전송 / 고장 주입: telegram-format.sh 문법 오류·변수 오타·
#       monitor-lib.sh 고장 상태로 uptime.sh·neon-usage.sh·워크플로 '감시 자체 실패' 스텝을 가짜 curl/gh 로 실행해 plain 이 실제 전송되는지.
#       (워크플로 스텝 추출은 python+PyYAML 필요 — 없으면 그 부분만 SKIP)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
FIX="$HERE/fixtures/neon"
QUIET=0; PLAIN=0
for x in "$@"; do case "$x" in --quiet) QUIET=1 ;; --plain) PLAIN=1 ;; *) echo "알 수 없는 인자: $x"; exit 64 ;; esac; done

export RUNNER_TEMP; RUNNER_TEMP="$(mktemp -d)"
# shellcheck source=../monitor-lib.sh
source "$SCRIPTS/monitor-lib.sh"

# 고정 시각: 2026-10-13 09:17 KST (= 00:17Z) — 렌더 결과가 실행 시각과 무관하게 같도록
NOW=1791850620
export FMT_NOW_EPOCH="$NOW"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
assert_eq() { if [ "$2" = "$3" ]; then ok; else bad "$1 — 기대 [$2] 실제 [$3]"; fi; }

# ---- 1) html_escape ---------------------------------------------------------
assert_eq "escape &"       '&amp;'                       "$(html_escape '&')"
assert_eq "escape <>"      '&lt;b&gt;x&lt;/b&gt;'        "$(html_escape '<b>x</b>')"
assert_eq "escape 순서"    '&amp;lt;'                    "$(html_escape '&lt;')"
assert_eq "escape 혼합"    'a &amp; b &lt; c &gt; d'     "$(html_escape 'a & b < c > d')"
assert_eq "escape 한글"    '장애 &lt;503&gt; — 실패'     "$(html_escape '장애 <503> — 실패')"
assert_eq "escape 빈 값"   ''                            "$(html_escape '')"
assert_eq "escape 따옴표 유지" "it's \"q\""             "$(html_escape "it's \"q\"")"
assert_eq "escape 줄바꿈"  $'a&amp;\nb&lt;'              "$(html_escape $'a&\nb<')"
assert_eq "escape 반복 &&" '&amp;&amp;&amp;'             "$(html_escape '&&&')"
assert_eq "href 따옴표"    'https://x/?a=1&amp;b=&quot;2&quot;' "$(_ha 'https://x/?a=1&b="2"')"
# ---- 2) html_to_plain -------------------------------------------------------
assert_eq "plain 태그 제거" '굵게 x 코드'                 "$(html_to_plain '<b>굵게</b> <i>x</i> <code>코드</code>')"
assert_eq "plain 링크"     '이슈 #3 (https://g/i/3)'     "$(html_to_plain '<a href="https://g/i/3">이슈 #3</a>')"
assert_eq "plain 엔티티"   'a < b & c > "d"'             "$(html_to_plain 'a &lt; b &amp; c &gt; &quot;d&quot;')"
assert_eq "plain 이중"     '&lt;'                        "$(html_to_plain '&amp;lt;')"
assert_eq "plain 왕복"     '503 <Service> & "x"'         "$(html_to_plain "<b>$(html_escape '503 <Service> & "x"')</b>")"
# ---- 3) 시각 도우미 ----------------------------------------------------------
assert_eq "fmt_ago 분"     '7분 전'     "$(fmt_ago 420)"
assert_eq "fmt_ago 시간"   '10시간 전'  "$(fmt_ago 36720)"
assert_eq "fmt_ago 일"     '14일 전'    "$(fmt_ago 1209600)"
assert_eq "fmt_dur"        '1시간 20분' "$(fmt_dur 80)"
assert_eq "fmt_when 오늘"  '09:17'      "$(fmt_when "$NOW" "$NOW")"
assert_eq "fmt_when 어제"  '어제 23:04' "$(fmt_when $((NOW - 36780)) "$NOW")"
assert_eq "next full 오전" '11:04'      "$(fmt_when "$(_fmt_next_full "$NOW")" "$NOW")"
assert_eq "next full 밤"   '10-14 11:04' "$(fmt_when "$(_fmt_next_full $((NOW + 14 * 3600)))" "$NOW")"

# ---- 4) 렌더 검사 -------------------------------------------------------------
# 허용 태그만·짝 맞음·남는 < > 없음·엔티티 외 & 없음·4096자 이내
check_html() {
  local name="$1" text="$2" t stack=() rest
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [[ "$t" =~ ^\<(b|i|code|pre)\>$ ]]; then stack+=("${BASH_REMATCH[1]}")
    elif [[ "$t" =~ ^\<a\ href=\"[^\"\<\>]*\"\>$ ]]; then stack+=(a)
    elif [[ "$t" =~ ^\</(b|i|code|pre|a)\>$ ]]; then
      if [ "${#stack[@]}" -eq 0 ] || [ "${stack[-1]}" != "${BASH_REMATCH[1]}" ]; then bad "$name: 짝 안 맞는 $t"; return; fi
      unset 'stack[-1]'
    else bad "$name: 허용 안 된 태그 $t"; return; fi
  done < <(grep -o '<[^>]*>' <<< "$text" || true)
  [ "${#stack[@]}" -eq 0 ] || { bad "$name: 안 닫힌 태그 ${stack[*]}"; return; }
  rest="$(sed -E 's/<[^>]*>//g' <<< "$text")"
  if grep -q '[<>]' <<< "$rest"; then bad "$name: 이스케이프 안 된 < 또는 >"; return; fi
  if sed -E 's/&(amp|lt|gt|quot|#[0-9]+);//g' <<< "$rest" | grep -q '&'; then bad "$name: 이스케이프 안 된 &"; return; fi
  if [ "${#text}" -gt 4096 ]; then bad "$name: ${#text}자 > 4096"; return; fi
  ok
}
SHOWN=()
show() {  # $1 제목, $2 본문
  check_html "$1" "$2"
  SHOWN+=("$1" "$2")
}

# 업타임 알림 — 샘플 4종(test-alert 와 같은 fixture) + 나머지 kind
RUN="https://github.com/thebluepigu/simparty-monitor/actions/runs/123"
ISSUE="https://github.com/thebluepigu/simparty-monitor/issues/7"
for k in detected recovered selffail flap; do
  show "알림 샘플: $k" "$(fmt_sample "$k" now="$NOW" run="$RUN")"
done
R="$RUNNER_TEMP/res.tsv"
printf '%s\t%s\t%s\t%s\t%s\n' liveness 1 200 0.21 ok robots 1 200 0.35 ok readiness 0 503 1.02 'status!=UP: {"status":"DOWN","components":{"db":"<DOWN>"}}' \
  categories 0 500 0.88 'HTTP 500' home 1 200 1.7 ok > "$R"
show "🔴 감지 — DB 경유 (full)" "$(fmt_outage_detected kind=new results="$R" now="$NOW" mode=full issue="$ISSUE" run="$RUN")"
show "🔴 지속 — 6h 재알림 (이월 포함)" "$(fmt_outage_ongoing kind=remind results="$R" now="$NOW" mode=quick issue="$ISSUE" run="$RUN" since=$((NOW - 23400)) failed=categories,readiness,home)"
show "🔴 확대" "$(fmt_outage_expanded results="$R" now="$NOW" mode=full issue="$ISSUE" run="$RUN" since=$((NOW - 4000)) new_fails=categories)"
show "🔴 재발 (재오픈)" "$(fmt_outage_detected kind=reopen results="$R" now="$NOW" mode=full issue="$ISSUE" run="$RUN")"
show "🔴 직접 알림 — 이슈 기록 실패" "$(fmt_outage_detected kind=selffail results="$R" now="$NOW" mode=full run="$RUN")"
show "⚠️ 감시 자체 실패 — neon-usage" "$(fmt_selffail workflow=neon-usage now="$NOW" run="$RUN" reason='Neon 프로젝트 상세 조회 실패 (HTTP 401, id=***)')"
show "🧪 test-alert 머리" "$(fmt_test now="$NOW" run="$RUN")"

# Neon 브리프 — neon-usage.sh 를 fixture + DRY_RUN 으로 끝까지 돌려 실제 경로 그대로 렌더
brief() {  # $1 제목, $2 fixture 폴더, 나머지 env 할당
  local title="$1" fx="$2"; shift 2
  local st out msg
  st="$(mktemp -d)"
  # 직전 상태: 24시간 전, 기본 브랜치 active_time 이 지금보다 PREV_DELTA 초 적었음 (기본 10368 = 가동률 12%)
  printf '{"ts":%s,"active_time_seconds":%s,"act_src":"branch","period_start":"2026-10-01T00:00:00Z"}' \
    $((NOW - 86400)) $((150000 - ${PREV_DELTA:-10368})) > "$st/neon-state.json"
  out="$(env NEON_FIXTURE_DIR="$fx" NEON_PROJECT_ID=proj-fixture NOW_EPOCH="$NOW" STATE_DIR="$st" DRY_RUN=1 \
        RUNNER_TEMP="$RUNNER_TEMP" GITHUB_STEP_SUMMARY= "$@" bash "$SCRIPTS/neon-usage.sh" 2>&1)" || { bad "$title: neon-usage.sh 실패"; echo "$out" | tail -5; return; }
  msg="$(awk '/^----$/{n++; next} n==1' <<< "$out")"
  show "$title" "$msg"
  LAST_BRIEF="$msg"
  # 상태(판정 기준점): preview 는 그대로, normal 은 지금 시각으로 갱신돼야 한다
  local ts; ts="$(jq -r .ts "$st/neon-state.json")"
  case " $* " in
    *" BRIEF_MODE=preview "*) assert_eq "$title: preview 는 기준점 유지" "$((NOW - 86400))" "$ts" ;;
    *)                        assert_eq "$title: normal 은 기준점 갱신" "$NOW" "$ts" ;;
  esac
  rm -rf "$st"
}
ISO() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
COMMON=(UPTIME_LAST_SUCCESS="$(ISO $((NOW - 420)))" UPTIME_LAST_FULL="$(ISO $((NOW - 36780)))"
        UPTIME_RUNS_24H=31 UPTIME_FULL_24H=3 UPTIME_FULL_EXEC_24H=2 UPTIME_INCIDENT='{"open":false}'
        REPO_LAST_COMMIT_EPOCH=$((NOW - 14 * 86400)))
brief "브리프 ✅ 정상" "$FIX" "${COMMON[@]}"
NORMAL_BRIEF="$LAST_BRIEF"
brief "브리프 ✅ 정상 — preview" "$FIX" "${COMMON[@]}" BRIEF_MODE=preview
brief "브리프 ⚠️ 예산 초과 + DB체크 40h + 47일 무커밋" "$FIX" "${COMMON[@]}" NEON_BUDGET_USD=3 \
  UPTIME_LAST_FULL="$(ISO $((NOW - 144000)))" UPTIME_FULL_24H=0 UPTIME_FULL_EXEC_24H=0 REPO_LAST_COMMIT_EPOCH=$((NOW - 47 * 86400))
BADFX="$(mktemp -d)"; cp "$FIX"/*.json "$BADFX/"; cp "$FIX/consumption_hourly_bad.json" "$BADFX/consumption_hourly.json"
PREV_DELTA=82080 brief "브리프 🔴 autosuspend 의심 + 사이트 장애 중" "$BADFX" "${COMMON[@]}" \
  UPTIME_INCIDENT="{\"open\":true,\"number\":7,\"url\":\"$ISSUE\",\"failed\":\"liveness\",\"since\":\"$(ISO $((NOW - 2700)))\"}"
assert_eq "🔴 브리프 추가 문제 줄" "· 사이트 장애 중 — liveness 실패" "$(sed -n 3p <<< "$LAST_BRIEF")"
assert_eq "🔴 브리프 첫 줄" "🔴 <b>Neon autosuspend 미작동 의심 — 24h 중 22시간 내내 켜짐 외 1건</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
brief "브리프 — heartbeat·incident 확인 불가" "$FIX" UPTIME_LAST_SUCCESS= UPTIME_LAST_FULL= UPTIME_INCIDENT= REPO_LAST_COMMIT_EPOCH=
# F3: heartbeat 를 못 읽으면 첫 줄 ⚠️ (예전 형식과 같게 — 감시가 도는지 모르는 상태를 ✅ 로 보이지 않게)
assert_eq "heartbeat 확인 불가 → 첫 줄 ⚠️" "⚠️ <b>업타임 감시 마지막 성공 확인 불가 — 감시가 도는지 직접 확인</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
# F3: 22시에 멈춘 감시(09:17 기준 11h) — 첫 줄 ⚠️, ② 사이트는 ✅ 정상이 아님
brief "브리프 ⚠️ uptime 11h 전 (밤사이 멈춤)" "$FIX" "${COMMON[@]}" UPTIME_LAST_SUCCESS="$(ISO $((NOW - 39600)))"
assert_eq "uptime 11h → 첫 줄 ⚠️" "⚠️ <b>업타임 감시가 6시간 넘게 멈춤 — 장애를 못 잡는 상태</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "uptime 11h → 사이트 ✅ 아님" 0 "$(grep -c '사이트</b> — ✅' <<< "$LAST_BRIEF" || true)"
assert_eq "uptime 11h → 마지막 확인 표시" 1 "$(grep -c '사이트</b> — 열린 장애 이슈 없음 · 마지막 확인 11시간 전 ⚠️' <<< "$LAST_BRIEF" || true)"
# 4h 전: 첫 줄은 ✅(6h 미만) 이지만 ② 는 '정상' 이라 단정하지 않는다(3h 초과)
brief "브리프 — uptime 4h 전" "$FIX" "${COMMON[@]}" UPTIME_LAST_SUCCESS="$(ISO $((NOW - 14400)))"
assert_eq "uptime 4h → 첫 줄 ✅" "✅" "$(sed -n 1p <<< "$LAST_BRIEF" | cut -d' ' -f1)"
assert_eq "uptime 4h → 사이트 ✅ 아님" 0 "$(grep -c '사이트</b> — ✅' <<< "$LAST_BRIEF" || true)"
assert_eq "uptime 7분 전 → 사이트 ✅ (정상 경로)" 1 "$(grep -c '사이트</b> — ✅ 정상' <<< "$NORMAL_BRIEF" || true)"
rm -rf "$BADFX"

# ---- 5) tg_send: HTML 파싱 실패 → plain 1회 재전송 (네트워크 없이 _tg_post 대체) ----
CALLS="$RUNNER_TEMP/calls"; : > "$CALLS"
_tg_post() {  # $1 text $2 parse_mode $3 resp $4 err
  printf '%s|%s\n' "${2:-plain}" "$(printf '%s' "$1" | tr '\n' ' ')" >> "$CALLS"
  if [ "$2" = "HTML" ]; then printf '{"ok":false,"error_code":400,"description":"Bad Request: can'"'"'t parse entities: unexpected end tag at byte offset 3"}' > "$3"; echo 400
  else printf '{"ok":true}' > "$3"; echo 200; fi
}
TELEGRAM_BOT_TOKEN=x TELEGRAM_CHAT_ID=1 TG_FAILED=0
tg_send '<b>깨진 <i>태그</b> &amp; <a href="https://x">링크</a>' >/dev/null && ok || bad "tg_send 재전송 후 성공해야 함"
assert_eq "재전송 횟수" 2 "$(wc -l < "$CALLS" | tr -d ' ')"
assert_eq "1차 HTML" "HTML" "$(sed -n 1p "$CALLS" | cut -d'|' -f1)"
assert_eq "2차 plain 본문" "plain|깨진 태그 & 링크 (https://x)" "$(sed -n 2p "$CALLS")"
assert_eq "TG_FAILED 유지 0" 0 "$TG_FAILED"
# 다른 400(예: chat not found)은 재전송하지 않는다
: > "$CALLS"
_tg_post() { printf '%s\n' "$2" >> "$CALLS"; printf '{"ok":false,"description":"Bad Request: chat not found"}' > "$3"; echo 400; }
tg_send '<b>x</b>' >/dev/null 2>&1 && bad "chat not found 는 실패해야 함" || ok
assert_eq "다른 400 은 1회만" 1 "$(wc -l < "$CALLS" | tr -d ' ')"
# 4000자 초과는 plain 으로 잘라 보냄(HTML 중간 절단 방지)
: > "$CALLS"; TG_FAILED=0
_tg_post() { printf '%s|%s\n' "${2:-plain}" "${#1}" >> "$CALLS"; printf '{"ok":true}' > "$3"; echo 200; }
tg_send "<b>$(printf 'x%.0s' $(seq 1 4100))</b>" >/dev/null && ok || bad "긴 메시지 전송"
assert_eq "긴 메시지 plain·4000자" "plain|4000" "$(cat "$CALLS")"

# ---- 6) 렌더 가드·빈 본문 (같은 프로세스) ------------------------------------------------
# 실제 템플릿은 정상 렌더에서 rc=0·비지 않은 출력이어야 한다(아니면 tg_render 가 멀쩡한 메시지를 plain 으로 떨어뜨림)
TG_DEGRADED=0
for args in "fmt_outage_detected kind=new" "fmt_outage_detected kind=reopen" "fmt_outage_detected kind=selffail" "fmt_flap" \
            "fmt_outage_ongoing kind=remind" "fmt_outage_ongoing kind=retry" "fmt_outage_ongoing kind=flap_remind" \
            "fmt_outage_expanded new_fails=categories" "fmt_recovered pass_at=$((NOW - 600)) flap_hold=1" "fmt_test"; do
  # shellcheck disable=SC2086
  tg_render $args results="$R" now="$NOW" mode=full issue="$ISSUE" run="$RUN" since=$((NOW - 3600))
  assert_eq "정상 렌더 HTML 유지: ${args%% *}" "|0" "${TG_MSG_PM}|${TG_DEGRADED}"
done
tg_render fmt_selffail workflow=uptime mode=quick reason=x run="$RUN"; assert_eq "정상 렌더 HTML 유지: fmt_selffail" "|0" "${TG_MSG_PM}|${TG_DEGRADED}"
tg_render fmt_sample flap now="$NOW" run="$RUN"; assert_eq "정상 렌더 HTML 유지: fmt_sample" "|0" "${TG_MSG_PM}|${TG_DEGRADED}"
# 변수 오타(set -u) → 빈 메시지 대신 plain 비상 메시지 + note_fail + TG_DEGRADED
: > "$RUNNER_TEMP/monitor_fail_reason"
(
  fmt_outage_expanded() { local x="$NO_SUCH_VAR_TYPO"; printf '%s' "$x"; }
  tg_render fmt_outage_expanded results="$R" now="$NOW" mode=full issue="$ISSUE" run="$RUN" new_fails=categories
  printf '%s|%s|%s\n' "$TG_MSG_PM" "$TG_DEGRADED" "$(sed -n 1p <<< "$TG_MSG")" > "$RUNNER_TEMP/guard.out"
  grep -c '❌ readiness: 503' <<< "$TG_MSG" >> "$RUNNER_TEMP/guard.out" || true
) >/dev/null 2>&1
assert_eq "오타 렌더 → plain 비상 메시지" "plain|1|🔴 simparty 장애 확대 — 새로 실패: categories" "$(sed -n 1p "$RUNNER_TEMP/guard.out" | sed -E 's/ \([0-9-]+ [0-9:]+ KST, full\)$//')"
assert_eq "비상 메시지에 옛 형식 체크 표" 1 "$(sed -n 2p "$RUNNER_TEMP/guard.out")"
assert_eq "오타 렌더 → note_fail" 1 "$(grep -c '템플릿 렌더 실패: fmt_outage_expanded' "$RUNNER_TEMP/monitor_fail_reason")"
# 빈 출력(rc 0)도 같은 처리
( fmt_test() { :; }; tg_render fmt_test run="$RUN"; x=no; [[ "$TG_MSG" == "🧪 [샘플] "* ]] && x=yes; printf '%s|%s' "$TG_MSG_PM" "$x" > "$RUNNER_TEMP/guard.out" ) >/dev/null 2>&1
assert_eq "빈 렌더 → plain 비상 메시지" "plain|yes" "$(cat "$RUNNER_TEMP/guard.out")"
# tg_send 는 빈 본문(공백뿐 포함)을 보내지 않는다
: > "$CALLS"; TG_FAILED=0
tg_send '' >/dev/null 2>&1 && bad "빈 본문은 실패해야 함" || ok
tg_send $'  \n ' >/dev/null 2>&1 && bad "공백 본문은 실패해야 함" || ok
assert_eq "빈 본문은 POST 안 함" 0 "$(wc -l < "$CALLS" | tr -d ' ')"
assert_eq "빈 본문 → TG_FAILED" 1 "$TG_FAILED"
# plain 지정 전송은 parse_mode 없이
: > "$CALLS"; TG_FAILED=0
tg_send 'a <b> & c' plain >/dev/null && ok || bad "plain 전송"
assert_eq "plain 지정 → parse_mode 없음" "plain|9" "$(cat "$CALLS")"
# <pre> 표 정렬 (F6 반박): 원문 기준 패딩 후 이스케이프 → 텔레그램 표시(엔티티 1글자)에서 칸이 맞는다
printf '%s\t%s\t%s\t%s\t%s\n' 'a<b&c' 0 503 0.1 'HTTP 503' liveness 1 200 0.2 ok > "$RUNNER_TEMP/pre.tsv"
PRE="$(html_to_plain "$(_fmt_results "$RUNNER_TEMP/pre.tsv" | sed -n '/<pre>/,/<\/pre>/p')")"
assert_eq "pre 표 정렬: 특수문자 행 stat 칸" "FAIL" "$(sed -n 2p <<< "$PRE" | cut -c13-16)"
assert_eq "pre 표 정렬: 일반 행 stat 칸"   "OK  " "$(sed -n 3p <<< "$PRE" | cut -c13-16)"
# 이중 이스케이프 없음 (F6): 알 수 없는 체크 이름의 판정 문구
printf '%s\t%s\t%s\t%s\t%s\n' 'x<y' 0 503 0.1 'HTTP 503' > "$RUNNER_TEMP/dbl.tsv"
assert_eq "판정 문구 이중 이스케이프 없음" 0 "$(fmt_outage_detected kind=new results="$RUNNER_TEMP/dbl.tsv" now="$NOW" mode=quick | grep -c '&amp;lt;' || true)"
# 복구 문구가 flap-hold·REOPEN_MINUTES 를 따른다 (F6)
REC="$(fmt_recovered results="$R" now="$NOW" mode=quick since=$((NOW - 9000)) pass_at=$((NOW - 7300)) flap_hold=1 flap_hold_min=120 reopen_min=180)"
assert_eq "복구: flap-hold 문구" 1 "$(grep -c '전부 통과가 120분 이어짐' <<< "$REC")"
assert_eq "복구: 재오픈 창 = reopen_min" 1 "$(grep -c '3시간 안에 재발하면' <<< "$REC")"

# ---- 7) 고장 주입 — 실제 스크립트·워크플로 스텝을 가짜 curl/gh 로 끝까지 실행 ---------------------
#   (a) telegram-format.sh 에 ')' 1개 추가(문법 오류)  (b) 템플릿 변수 오타(set -u)  (c) monitor-lib.sh 자체 고장
#   확인: 빈 메시지·무전송 없이 plain 메시지가 실제로 POST 되는가, 상태 기록·감시 실패 스텝이 이어지는가
FI="$RUNNER_TEMP/fi"; mkdir -p "$FI/bin"
cat > "$FI/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# 가짜 curl: 텔레그램(-K -) 이면 본문을 $TG_DIR/N.txt·N.pm 에 기록하고 200, 그 외(업타임 체크)는 URL 에 liveness 가 있으면 503
out=""; tg=0; text=""; pm=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -K) tg=1; shift ;;
    -o|-D|-w|-A|-X|--max-time|--max-redirs) [ "$1" = "-o" ] && out="$2"; shift ;;
    --data-urlencode) case "$2" in text=*) text="${2#text=}" ;; parse_mode=*) pm="${2#parse_mode=}" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
if [ "$tg" = "1" ]; then
  cat > /dev/null
  n="$(find "$TG_DIR" -name '*.txt' | wc -l | tr -d ' ')"
  printf '%s' "$text" > "$TG_DIR/$n.txt"; printf '%s' "${pm:-plain}" > "$TG_DIR/$n.pm"
  [ -z "$out" ] || printf '{"ok":true}' > "$out"
  printf '200'; exit 0
fi
[ -z "$out" ] || printf '{"status":"UP"}' > "$out"
case "$url" in *liveness*) printf '503 0.10' ;; *) printf '200 0.20' ;; esac
FAKE
cat > "$FI/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# 가짜 gh: 열린·닫힌 장애 이슈 없음 → 신규 장애 경로(라벨·이슈 생성·본문 마커 편집)
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "api repos/"*)
    case "$2" in
      *issues\?*) echo '[]' ;;
      *issues/*) printf '{"number":9,"html_url":"https://github.com/o/r/issues/9","created_at":"2026-10-13T00:00:00Z","body":""}' ;;
    esac ;;
  "issue create") echo "https://github.com/o/r/issues/9" ;;
esac
exit 0
FAKE
chmod +x "$FI/bin/curl" "$FI/bin/gh"
# 가짜가 PATH 맨 앞에서 잡히는지 확인 — 경로에 ':' 가 섞이면(예: Windows 'C:/…') PATH 가 갈라져 진짜 curl/gh 가 불린다
for c in curl gh; do
  if [ "$(PATH="$FI/bin:$PATH" command -v "$c")" != "$FI/bin/$c" ]; then
    echo "중단: 가짜 $c 가 PATH 에서 먼저 잡히지 않음 (FI=$FI) — 실제 네트워크 호출 방지"; exit 1
  fi
done
# 스크립트 사본 + 고장 주입. $1 이름, $2 고장 종류(syntax|typo|libbroken|brieftypo)
mk_broken() {
  local d="$FI/$1"; rm -rf "$d"; mkdir -p "$d/.github"
  cp -r "$SCRIPTS" "$d/.github/scripts"; cp -r "$SCRIPTS/../workflows" "$d/.github/workflows"
  local tf="$d/.github/scripts/telegram-format.sh"
  case "$2" in
    syntax)    sed -i '300a )' "$tf" ;;
    typo)      sed -i 's/failed="${a\[failed\]:-$ran_failed}"/failed="${a[failed]:-$ran_faild}"/' "$tf" ;;
    brieftypo) sed -i 's/<code>${B_tx} GB<\/code>/<code>${B_tx_typo} GB<\/code>/' "$tf" ;;
    libbroken) sed -i '300a )' "$tf"; printf '\n)\n' >> "$d/.github/scripts/monitor-lib.sh" ;;
  esac
  printf '%s' "$d"
}
# $1 디렉터리 → 실행 환경 초기화 (전송 기록·gh 기록·RUNNER_TEMP)
fi_env() {
  export TG_DIR="${1:?}/tg" GH_LOG="$1/gh.log"; rm -rf "${TG_DIR:?}" "${1:?}/rt"; mkdir -p "$TG_DIR" "$1/rt"; : > "$GH_LOG"
}
fi_count() { find "$TG_DIR" -name '*.txt' | wc -l | tr -d ' '; }
# 워크플로 YAML 에서 id 로 스텝 run 블록 추출 (python+PyYAML 필요 — 없으면 SKIP)
PY=""; for c in python3 python; do if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi; done
SKIP=0
step_run() {  # $1 workflow 파일, $2 step id → stdout
  PYTHONUTF8=1 "$PY" -c '
import sys, yaml
d = yaml.safe_load(sys.stdin.buffer.read().decode("utf-8"))
for j in d["jobs"].values():
    for st in j.get("steps", []):
        if st.get("id") == sys.argv[1]:
            sys.stdout.buffer.write(st["run"].encode("utf-8"))
' "$2" < "$1"
}
# 워크플로 '감시 자체 실패' 스텝 실행 (GitHub 기본 셸 bash -e). $1 사본 디렉터리, $2 workflow, 나머지 env
run_selffail() {
  local d="$1" wf="$2"; shift 2
  step_run "$d/.github/workflows/$wf" selffail > "$d/selffail.sh"
  ( cd "$d" && env PATH="$FI/bin:$PATH" RUNNER_TEMP="$d/rt" GITHUB_OUTPUT="$d/rt/out" RUN_URL=https://example.invalid/run/1 \
      TELEGRAM_BOT_TOKEN=x TELEGRAM_CHAT_ID=1 "$@" bash -e selffail.sh ) > "$d/selffail.log" 2>&1
}
UP_ENV=(GH_REPO=o/r TELEGRAM_BOT_TOKEN=x TELEGRAM_CHAT_ID=1 RETRY_DELAY=0 SAMPLE_GAP_SEC=0 RUN_URL=https://example.invalid/run/1)
run_uptime() {  # $1 사본 디렉터리, $2 mode → rc 출력
  local d="$1" rc=0
  ( cd "$d" && env PATH="$FI/bin:$PATH" RUNNER_TEMP="$d/rt" SELFFAIL_DIR="$d/sf" GITHUB_OUTPUT="$d/rt/out" "${UP_ENV[@]}" \
      bash .github/scripts/uptime.sh "$2" ) > "$d/uptime.log" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# (a) 문법 오류 — uptime.sh 신규 장애: plain 🔴 가 실제로 전송되고, 이슈 상태 기록(tg-sent 마커)까지 이어진다
D="$(mk_broken syntax syntax)"; fi_env "$D"
bash -n "$D/.github/scripts/telegram-format.sh" 2>/dev/null && bad "고장 주입(syntax) 이 bash -n 에 걸려야 함" || ok
RC="$(run_uptime "$D" quick)"
assert_eq "(a) uptime.sh 종료코드 1 (기본 형식 사용 → job 실패 표시)" 1 "$RC"
assert_eq "(a) 텔레그램 1건 전송" 1 "$(fi_count)"
assert_eq "(a) parse_mode 없음(plain)" plain "$(cat "$TG_DIR/0.pm" 2>/dev/null)"
assert_eq "(a) 옛 형식 제목" "🔴 simparty 장애 감지" "$(sed -n 1p "$TG_DIR/0.txt" 2>/dev/null | cut -d' ' -f1-4)"
assert_eq "(a) 옛 형식 체크 표" 1 "$(grep -c '^❌ liveness: 503' "$TG_DIR/0.txt" 2>/dev/null || true)"
assert_eq "(a) 이슈 URL" 1 "$(grep -c '^이슈: https://github.com/o/r/issues/9$' "$TG_DIR/0.txt" 2>/dev/null || true)"
assert_eq "(a) 상태 기록(이슈 본문 마커 편집) 진행" 1 "$(grep -c '^issue edit 9 ' "$GH_LOG")"
assert_eq "(a) 실패 사유에 템플릿 고장" 1 "$(grep -c 'telegram-format.sh 사용 불가' "$D/rt/monitor_fail_reason")"
SHOWN+=("고장 주입 (a) 문법 오류 — uptime.sh 가 실제 보낸 🔴 (plain)" "$(cat "$TG_DIR/0.txt" 2>/dev/null)")
if [ -n "$PY" ]; then
  # 이어서 워크플로 '감시 자체 실패' 스텝 (같은 RUNNER_TEMP — 위 실패 사유가 실린다)
  run_selffail "$D" uptime.yml MODE=quick || bad "(a) uptime.yml selffail 스텝 비0 종료"
  assert_eq "(a) selffail: 텔레그램 추가 1건" 2 "$(fi_count)"
  assert_eq "(a) selffail: plain" plain "$(cat "$TG_DIR/1.pm" 2>/dev/null)"
  assert_eq "(a) selffail: 제목" "⚠️ 감시 자체 실패: uptime (quick) — 이후 6시간 같은 알림 억제" "$(sed -n 1p "$TG_DIR/1.txt" 2>/dev/null)"
  assert_eq "(a) selffail: 사유 실림" 1 "$(grep -c 'telegram-format.sh 사용 불가' "$TG_DIR/1.txt" 2>/dev/null || true)"
  assert_eq "(a) selffail: 억제 상태 저장" "saved=1" "$(cat "$D/rt/out" 2>/dev/null | grep saved || true)"
  SHOWN+=("고장 주입 (a) 문법 오류 — '감시 자체 실패' 스텝이 실제 보낸 ⚠️ (plain)" "$(cat "$TG_DIR/1.txt" 2>/dev/null)")
  # neon-usage.yml 의 같은 스텝
  fi_env "$D"; echo "Neon API 401" > "$D/rt/monitor_fail_reason"; rm -rf "$D/.selffail"
  run_selffail "$D" neon-usage.yml BRIEF_MODE=normal || bad "(a) neon-usage.yml selffail 스텝 비0 종료"
  assert_eq "(a) neon selffail: plain 1건" "1|plain" "$(fi_count)|$(cat "$TG_DIR/0.pm" 2>/dev/null)"
  assert_eq "(a) neon selffail: 제목" "⚠️ 감시 자체 실패: neon-usage (normal) — 이후 6시간 같은 알림 억제" "$(sed -n 1p "$TG_DIR/0.txt" 2>/dev/null)"
else
  SKIP=$((SKIP + 1)); echo "SKIP: python+PyYAML 없음 — 워크플로 스텝 고장 주입 생략"
fi
# (a') 문법 오류 + test-alert: 머리 + 샘플 4건 모두 plain 으로 가고, selffail 스텝은 6시간 억제 상태를 남기지 않는다(F5)
fi_env "$D"; rm -rf "$D/sf" "$D/.selffail"
RC="$(run_uptime "$D" test-alert)"
assert_eq "(a') test-alert 5건 plain" "5|1" "$(fi_count)|$RC"
if [ -n "$PY" ]; then
  run_selffail "$D" uptime.yml MODE=test-alert || bad "(a') selffail 비0"
  assert_eq "(a') test-alert 실패는 억제 상태 저장 안 함" "" "$(cat "$D/rt/out" 2>/dev/null | grep saved || true)"
  assert_eq "(a') 그래도 알림은 전송" 6 "$(fi_count)"
fi

# (b) 변수 오타(set -u) — 빈 메시지 대신 plain 비상 메시지, 상태 기록 계속
D="$(mk_broken typo typo)"; fi_env "$D"
grep -q 'ran_faild' "$D/.github/scripts/telegram-format.sh" || bad "(b) 오타 주입 실패"
RC="$(run_uptime "$D" quick)"
assert_eq "(b) uptime.sh 종료코드 1" 1 "$RC"
assert_eq "(b) 텔레그램 1건 plain" "1|plain" "$(fi_count)|$(cat "$TG_DIR/0.pm" 2>/dev/null)"
assert_eq "(b) 비상 메시지(빈 본문 아님)" "🔴 simparty 장애 감지" "$(sed -n 1p "$TG_DIR/0.txt" 2>/dev/null | cut -d' ' -f1-4)"
assert_eq "(b) 상태 기록 진행" 1 "$(grep -c '^issue edit 9 ' "$GH_LOG")"
assert_eq "(b) 실패 사유: 렌더 실패" 1 "$(grep -c '템플릿 렌더 실패: fmt_outage_detected' "$D/rt/monitor_fail_reason")"
SHOWN+=("고장 주입 (b) 변수 오타 — uptime.sh 가 실제 보낸 비상 🔴 (plain)" "$(cat "$TG_DIR/0.txt" 2>/dev/null)")

# (b') 브리프 변수 오타 — neon-usage.sh 가 옛 형식 plain 브리프를 보낸다
D="$(mk_broken brieftypo brieftypo)"; fi_env "$D"
BST="$(mktemp -d)"
RC=0
( cd "$D" && env PATH="$FI/bin:$PATH" RUNNER_TEMP="$D/rt" NEON_FIXTURE_DIR="$FIX" NEON_PROJECT_ID=proj-fixture NOW_EPOCH="$NOW" \
    STATE_DIR="$BST" GITHUB_STEP_SUMMARY= TELEGRAM_BOT_TOKEN=x TELEGRAM_CHAT_ID=1 "${COMMON[@]}" \
    bash .github/scripts/neon-usage.sh ) > "$D/neon.log" 2>&1 || RC=$?
assert_eq "(b') neon-usage.sh 종료코드 1 + plain 1건" "1|1|plain" "$RC|$(fi_count)|$(cat "$TG_DIR/0.pm" 2>/dev/null)"
SHOWN+=("고장 주입 (b') 브리프 변수 오타 — neon-usage.sh 가 실제 보낸 브리프 (plain)" "$(cat "$TG_DIR/0.txt" 2>/dev/null)")
assert_eq "(b') 옛 형식 브리프 첫 줄" "✅ Neon simparty 브리프 10-13 (기간 12/31일)" "$(sed -n 1p "$TG_DIR/0.txt" 2>/dev/null)"
rm -rf "$BST"

# (c) monitor-lib.sh 자체 고장 — selffail 스텝 서브셸이 죽어도 인라인 plain 으로 전송
if [ -n "$PY" ]; then
  D="$(mk_broken libbroken libbroken)"; fi_env "$D"; echo "uptime.sh 비정상 종료" > "$D/rt/monitor_fail_reason"
  run_selffail "$D" uptime.yml MODE=quick || bad "(c) selffail 비0"
  assert_eq "(c) 인라인 plain 1건" "1|plain" "$(fi_count)|$(cat "$TG_DIR/0.pm" 2>/dev/null)"
  assert_eq "(c) 인라인 제목" "⚠️ 감시 자체 실패: uptime (quick) — 이후 6시간 같은 알림 억제" "$(sed -n 1p "$TG_DIR/0.txt" 2>/dev/null)"
  assert_eq "(c) 억제 상태 저장" "saved=1" "$(grep saved "$D/rt/out" 2>/dev/null || true)"
  SHOWN+=("고장 주입 (c) monitor-lib.sh 고장 — 인라인 plain ⚠️" "$(cat "$TG_DIR/0.txt" 2>/dev/null)")
fi
rm -rf "$FI"

# ---- 출력 --------------------------------------------------------------------
if [ "$QUIET" = "0" ]; then
  for ((i = 0; i < ${#SHOWN[@]}; i += 2)); do
    printf '\n==================== %s ====================\n' "${SHOWN[i]}"
    if [ "$PLAIN" = "1" ]; then html_to_plain "${SHOWN[i + 1]}"; echo; else printf '%s\n' "${SHOWN[i + 1]}"; fi
  done
  echo
fi
rm -rf "$RUNNER_TEMP"
echo "telegram-format tests: ${PASS} passed, ${FAIL} failed${SKIP:+, ${SKIP} skipped}"
[ "$FAIL" = "0" ]
