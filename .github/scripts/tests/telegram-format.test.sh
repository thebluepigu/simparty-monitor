#!/usr/bin/env bash
# 텔레그램 템플릿 로컬 검증 + 렌더 미리보기. 네트워크·GitHub·텔레그램·Neon 호출 없음(전부 fixture).
#
#   bash .github/scripts/tests/telegram-format.test.sh            # 단위 테스트 + 렌더 전문 출력
#   bash .github/scripts/tests/telegram-format.test.sh --quiet    # 단위 테스트·렌더 검사만 (CI·커밋 전)
#   bash .github/scripts/tests/telegram-format.test.sh --plain    # 렌더를 텔레그램에 보이는 모습(태그 제거)으로 출력
#
# 검사: html_escape·html_to_plain 단위 / 모든 렌더의 HTML 이 허용 태그(b i code pre a)만 짝 맞게 쓰는지·
#       이스케이프 안 된 & < > 가 없는지·4096자 이내인지 / tg_send 의 "can't parse entities" → plain 1회 재전송.
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
brief "브리프 ✅ 정상 — preview" "$FIX" "${COMMON[@]}" BRIEF_MODE=preview
brief "브리프 ⚠️ 예산 초과 + DB체크 40h + 47일 무커밋" "$FIX" "${COMMON[@]}" NEON_BUDGET_USD=3 \
  UPTIME_LAST_FULL="$(ISO $((NOW - 144000)))" UPTIME_FULL_24H=0 UPTIME_FULL_EXEC_24H=0 REPO_LAST_COMMIT_EPOCH=$((NOW - 47 * 86400))
BADFX="$(mktemp -d)"; cp "$FIX"/*.json "$BADFX/"; cp "$FIX/consumption_hourly_bad.json" "$BADFX/consumption_hourly.json"
PREV_DELTA=82080 brief "브리프 🔴 autosuspend 의심 + 사이트 장애 중" "$BADFX" "${COMMON[@]}" \
  UPTIME_INCIDENT="{\"open\":true,\"number\":7,\"url\":\"$ISSUE\",\"failed\":\"liveness\",\"since\":\"$(ISO $((NOW - 2700)))\"}"
brief "브리프 — heartbeat·incident 확인 불가" "$FIX" UPTIME_LAST_SUCCESS= UPTIME_LAST_FULL= UPTIME_INCIDENT= REPO_LAST_COMMIT_EPOCH=
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

# ---- 출력 --------------------------------------------------------------------
if [ "$QUIET" = "0" ]; then
  for ((i = 0; i < ${#SHOWN[@]}; i += 2)); do
    printf '\n==================== %s ====================\n' "${SHOWN[i]}"
    if [ "$PLAIN" = "1" ]; then html_to_plain "${SHOWN[i + 1]}"; echo; else printf '%s\n' "${SHOWN[i + 1]}"; fi
  done
  echo
fi
rm -rf "$RUNNER_TEMP"
echo "telegram-format tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" = "0" ]
