#!/usr/bin/env bash
# 텔레그램 템플릿 로컬 검증 + 렌더 미리보기. 네트워크·GitHub·텔레그램·Neon 호출 없음(전부 fixture).
#
#   bash .github/scripts/tests/telegram-format.test.sh            # 단위 테스트 + 렌더 전문 출력
#   bash .github/scripts/tests/telegram-format.test.sh --quiet    # 단위 테스트·렌더 검사만 (CI·커밋 전)
#   bash .github/scripts/tests/telegram-format.test.sh --plain    # 렌더를 텔레그램에 보이는 모습(태그 제거)으로 출력
#
# 검사: html_escape·html_to_plain 단위 / 모든 렌더의 HTML 이 허용 태그(b i code pre a)만 짝 맞게 쓰는지·
#       이스케이프 안 된 & < > 가 없는지·4096자 이내인지 / 옛 기호(✅ ⚠️ 🟠 ≈ 🧪 ⏭ ℹ️, 줄 머리 "· ", " · ")가 없는지 /
#       브리프 신호등(섹션 머리 색·첫 줄 = 가장 나쁜 색, 예산 80%·RUNS_WARN_PCT·SCHEDULER 문구) / tg_send 의 "can't parse entities" → plain 1회 재전송 /
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
# FULL_EVERY_HOURS(repo 변수) — uptime-mode.sh 와 같은 해석: N=3 → KST 11·14·17·20·23, 0 → 없음(빈 값), 정수 아님 → 1
assert_eq "next full N=3 오전"   '11:04' "$(fmt_when "$(FULL_EVERY_HOURS=3 _fmt_next_full "$NOW")" "$NOW")"
assert_eq "next full N=3 12:17"  '14:04' "$(fmt_when "$(FULL_EVERY_HOURS=3 _fmt_next_full $((NOW + 3 * 3600)))" "$NOW")"
assert_eq "next full N=3 20:17"  '23:04' "$(fmt_when "$(FULL_EVERY_HOURS=3 _fmt_next_full $((NOW + 11 * 3600)))" "$NOW")"
assert_eq "next full N=3 23:17"  '10-14 11:04' "$(fmt_when "$(FULL_EVERY_HOURS=3 _fmt_next_full $((NOW + 14 * 3600)))" "$NOW")"
assert_eq "next full N=2 11:17 (공백)" '13:04' "$(fmt_when "$(FULL_EVERY_HOURS=' 2 ' _fmt_next_full $((NOW + 2 * 3600)))" "$NOW")"
assert_eq "next full N=3 11:17"  '14:04' "$(fmt_when "$(FULL_EVERY_HOURS=3 _fmt_next_full $((NOW + 2 * 3600)))" "$NOW")"
assert_eq "next full N=02 11:17" '13:04' "$(fmt_when "$(FULL_EVERY_HOURS=02 _fmt_next_full $((NOW + 2 * 3600)))" "$NOW")"
assert_eq "next full 큰 값 → 1 (overflow 방지)" '12:04' "$(fmt_when "$(FULL_EVERY_HOURS=18446744073709551615 _fmt_next_full $((NOW + 2 * 3600)))" "$NOW")"
assert_eq "next full 4자리 → 1" '12:04' "$(fmt_when "$(FULL_EVERY_HOURS=1000 _fmt_next_full $((NOW + 2 * 3600)))" "$NOW")"
assert_eq "next full N=0 → 빈 값" '' "$(FULL_EVERY_HOURS=0 _fmt_next_full "$NOW")"
assert_eq "next full N=x → 1"    '13:04' "$(fmt_when "$(FULL_EVERY_HOURS=x _fmt_next_full $((NOW + 3 * 3600)))" "$NOW")"
assert_eq "_fmt_sched 대소문자·공백" cloudflare "$(SCHEDULER=' Cloudflare ' _fmt_sched)"
assert_eq "_fmt_sched 빈 값"        github     "$(SCHEDULER= _fmt_sched)"

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
# 신호등 규칙(2026-10-30): 상태 이모지는 🟢 🟡 🔴 만, 줄 머리 "- ", 한 줄 안 구분 " / " → 옛 기호가 남았으면 실패
check_symbols() {
  local name="$1" text="$2" sym
  for sym in '✅' '⚠️' '⚠' '🟠' '≈' '🧪' '⏭' 'ℹ️'; do
    if [[ "$text" == *"$sym"* ]]; then bad "$name: 옛 기호 '$sym' 남음"; return; fi
  done
  if grep -q '^ *· ' <<< "$text"; then bad "$name: 줄 머리 '· ' 남음"; return; fi
  if grep -q ' · ' <<< "$text"; then bad "$name: 항목 구분 ' · ' 남음 (' / ' 사용)"; return; fi
  ok
}
SHOWN=()
show() {  # $1 제목, $2 본문
  check_html "$1" "$2"
  check_symbols "$1" "$2"
  SHOWN+=("$1" "$2")
}
# 실제 전송 본문(plain 대체 포함)도 같은 기호 규칙
shown_plain() { check_symbols "$1" "$2"; SHOWN+=("$1" "$2"); }

# 업타임 알림 — 샘플 4종(test-alert 와 같은 fixture) + 나머지 kind
RUN="https://github.com/thebluepigu/simparty-monitor/actions/runs/123"
ISSUE="https://github.com/thebluepigu/simparty-monitor/issues/7"
for k in detected recovered selffail flap; do
  show "알림 샘플: $k" "$(fmt_sample "$k" now="$NOW" run="$RUN")"
done
# 반복 장애(🟡 flap): 이번 장애의 🟢 는 온다 — '재발·복구 알림은 보내지 않아요' 같은 사실과 다른 단정 금지
FLAP_TXT="$(fmt_sample flap now="$NOW" run="$RUN")"
assert_eq "flap: '보내지 않아요' 단정 없음" 0 "$(grep -c '재발·복구 알림은 보내지 않아요' <<< "$FLAP_TXT" || true)"
assert_eq "flap: 120분 통과 후 🟢 복구 알림" 1 "$(grep -c '^- 복구 조건 강화: 모두 통과가 <b>120분</b> 이어져야 🟢 복구 알림 + 이슈 close$' <<< "$FLAP_TXT" || true)"
assert_eq "flap: 다음 재발은 바로 알리지 않음(6시간에 1번)" 1 "$(grep -c '^- 12시간 안에 또 재발하면 바로 알리지 않아요 — 직전 알림 6시간 뒤부터만 다시 알림 (알리지 않은 재발은 🟢 도 없음)$' <<< "$FLAP_TXT" || true)"
assert_eq "flap_remind: '멈춘 상태' 없음" 0 "$(grep -c '멈춘 상태' <<< "$(fmt_outage_ongoing kind=flap_remind results="$RUNNER_TEMP/none" now="$NOW" mode=quick since=$((NOW - 7200)) failed=liveness)" || true)"
assert_eq "recovered(재발 1회): 다음 재발 규칙" 1 "$(grep -c '또 재발하면 🟡 1건, 그다음부터는 바로 알리지 않아요(6시간에 1번)' <<< "$(fmt_recovered now="$NOW" since=$((NOW - 3600)) pass_at=$((NOW - 600)) seen=liveness reopens=1 remind_h=6)" || true)"
R="$RUNNER_TEMP/res.tsv"
printf '%s\t%s\t%s\t%s\t%s\n' liveness 1 200 0.21 ok robots 1 200 0.35 ok readiness 0 503 1.02 'status!=UP: {"status":"DOWN","components":{"db":"<DOWN>"}}' \
  categories 0 500 0.88 'HTTP 500' home 1 200 1.7 ok > "$R"
show "🔴 감지 — DB 경유 (full)" "$(fmt_outage_detected kind=new results="$R" now="$NOW" mode=full issue="$ISSUE" run="$RUN")"
assert_eq "DB 경유 실패 → 다음 예정 11:04 (N=1)" 1 "$(grep -c '다음 예정 <b>11:04</b> KST' <<< "$(fmt_outage_detected kind=new results="$R" now="$NOW" mode=full)" || true)"
assert_eq "DB 경유 실패 → 다음 예정 14:04 (N=3, 12:17)" 1 "$(grep -c '다음 예정 <b>14:04</b> KST' <<< "$(FULL_EVERY_HOURS=3 fmt_outage_detected kind=new results="$R" now=$((NOW + 3 * 3600)) mode=full)" || true)"
show "🔴 감지 — DB 경유, DB 포함 점검 꺼짐(FULL_EVERY_HOURS=0)" "$(FULL_EVERY_HOURS=0 fmt_outage_detected kind=new results="$R" now="$NOW" mode=full issue="$ISSUE" run="$RUN")"
N0_ALERT="$(FULL_EVERY_HOURS=0 fmt_outage_detected kind=new results="$R" now="$NOW" mode=full)"
assert_eq "N=0 → 꺼져 있음 + 수동 full 도 막힘" 1 "$(grep -c '지금 DB 포함 점검이 꺼져 있어요(FULL_EVERY_HOURS=0 — 수동 mode=full 도 빠른 점검으로 바뀜) → 이대로는 장애가 저절로 닫히지 않아요' <<< "$N0_ALERT" || true)"
assert_eq "N=0 → 실제 해법 안내(1 로 — 2·3 이면 수동 full 도 그 주기 시각에만 돈다)" 1 "$(grep -c '^- 해결: repo 변수 FULL_EVERY_HOURS 를 1 로 바꾼 뒤 KST 11~23시에 mode=full 수동 실행(2·3 이면 그 주기 시각에만 돌아요), 또는 장애 이슈를 직접 close$' <<< "$N0_ALERT" || true)"
assert_eq "N=0 → '수동 실행(mode=full)으로 확인' 같은 안 되는 안내 없음" 0 "$(grep -c '으로 확인$' <<< "$N0_ALERT" || true)"
show "🔴 지속 — 6h 재알림 (이월 포함)" "$(fmt_outage_ongoing kind=remind results="$R" now="$NOW" mode=quick issue="$ISSUE" run="$RUN" since=$((NOW - 23400)) failed=categories,readiness,home)"
show "🔴 확대" "$(fmt_outage_expanded results="$R" now="$NOW" mode=full issue="$ISSUE" run="$RUN" since=$((NOW - 4000)) new_fails=categories)"
show "🔴 재발 (재오픈)" "$(fmt_outage_detected kind=reopen results="$R" now="$NOW" mode=full issue="$ISSUE" run="$RUN")"
show "🔴 직접 알림 — 이슈 기록 실패" "$(fmt_outage_detected kind=selffail results="$R" now="$NOW" mode=full run="$RUN")"
assert_eq "직접 알림: 사이트가 먼저 회복되면 🟢 없음" 1 "$(grep -c '^- 그사이 사이트가 먼저 회복되면 따로 🟢 는 오지 않아요(이 경우 장애 이슈도 만들어지지 않음)$' <<< "$(fmt_outage_detected kind=selffail results="$R" now="$NOW" mode=full)" || true)"
show "🟡 감시 자체 실패 — neon-usage" "$(fmt_selffail workflow=neon-usage now="$NOW" run="$RUN" reason='Neon 프로젝트 상세 조회 실패 (HTTP 401, id=***)')"
show "[샘플] test-alert 머리" "$(fmt_test now="$NOW" run="$RUN")"

# Neon 브리프 — neon-usage.sh 를 fixture + DRY_RUN 으로 끝까지 돌려 실제 경로 그대로 렌더
brief() {  # $1 제목, $2 fixture 폴더, 나머지 env 할당
  local title="$1" fx="$2"; shift 2
  local st out msg
  st="$(mktemp -d)"
  # 직전 상태: 24시간 전, 기본 브랜치 active_time 이 지금보다 PREV_DELTA 초 적었음 (기본 10368 = 가동률 12%)
  printf '{"ts":%s,"active_time_seconds":%s,"act_src":"branch","period_start":"%s"}' \
    $((NOW - 86400)) $((150000 - ${PREV_DELTA:-10368})) "${PREV_PS:-2026-10-01T00:00:00Z}" > "$st/neon-state.json"
  out="$(env NEON_FIXTURE_DIR="$fx" NEON_PROJECT_ID=proj-fixture NOW_EPOCH="$NOW" STATE_DIR="$st" DRY_RUN=1 \
        RUNNER_TEMP="$RUNNER_TEMP" GITHUB_STEP_SUMMARY= "$@" bash "$SCRIPTS/neon-usage.sh" 2>&1)" || { bad "$title: neon-usage.sh 실패"; echo "$out" | tail -5; return; }
  msg="$(awk '/^----$/{n++; next} n==1' <<< "$out")"
  show "$title" "$msg"
  LAST_BRIEF="$msg"
  # 섹션 머리(빈 줄 다음 줄)는 신호등으로 시작 — 마지막 "다음 브리프:" 줄만 예외. 섹션 4개(사이트·비용·절전·감시)
  local heads; heads="$(awk 'p && !/^다음 브리프: /{print} {p = ($0 == "")}' <<< "$msg")"
  assert_eq "$title: 섹션 머리 4개" 4 "$(grep -c . <<< "$heads")"
  assert_eq "$title: 섹션 머리 모두 신호등" 0 "$(grep -Evc '^(🟢|🟡|🔴) <b>' <<< "$heads" || true)"
  # 첫 줄 색 = 섹션 중 가장 나쁜 색
  local worst=🟢; grep -q '^🟡' <<< "$heads" && worst=🟡; grep -q '^🔴' <<< "$heads" && worst=🔴
  assert_eq "$title: 첫 줄 = 가장 나쁜 색" "$worst" "$(sed -n 1p <<< "$msg" | sed -E 's/^\[[^]]*\] //' | cut -d' ' -f1)"
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
GH_NOTE='다음 브리프: 내일 09:17 예정(지금은 GitHub 지연으로 오후에 올 수 있음)'
brief "브리프 🟢 정상" "$FIX" "${COMMON[@]}"
NORMAL_BRIEF="$LAST_BRIEF"
assert_eq "켜져 있던 비율 창 = 최근 24시간 (직전 판정 기준점)" 1 "$(grep -c '켜져 있던 비율 <code>12%</code> <i>(최근 24시간, 90% 이상이면 🔴)</i>$' <<< "$LAST_BRIEF" || true)"
PREV_PS=2026-09-01T00:00:00Z brief "브리프 — 결제 기간 전환 직후 (비율 창 = 기간 시작 이후)" "$FIX" "${COMMON[@]}"
assert_eq "결제 기간 전환 → '결제 기간 시작 이후'" 1 "$(grep -c '<i>(결제 기간 시작 이후, 90% 이상이면 🔴)</i>$' <<< "$LAST_BRIEF" || true)"
assert_eq "옛 문구 '직전 브리프 이후' 없음" 0 "$(grep -c '직전 브리프 이후' <<< "$LAST_BRIEF" || true)"
brief "브리프 🟡 감시 0회·25시간 멈춤 (github)" "$FIX" "${COMMON[@]}" UPTIME_RUNS_24H=0 UPTIME_LAST_SUCCESS="$(ISO $((NOW - 90000)))"
assert_eq "감시 멈춤 → 첫 줄 🟡 멈췄어요" "🟡" "$(sed -n 1p <<< "$LAST_BRIEF" | cut -d' ' -f1)"
assert_eq "감시 멈춘 날엔 '감시 고장 아님' 문장 없음" 0 "$(grep -c '감시 고장 아님' <<< "$LAST_BRIEF" || true)"
brief "브리프 — 예상 비용 = 예산 (반올림 후 같음)" "$FIX" "${COMMON[@]}" NEON_BUDGET_USD=3.12
assert_eq "\$3.12 / \$3.12 → '넘을 것' 아니라 '거의 닿을 것'" "🟡 <b>예산에 거의 닿을 것 같아요 — 기간 말 예상 \$3.12 / 예산 \$3.12 (100%)</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "\$3.12 / \$3.12 → 비용 섹션 문구" 1 "$(grep -c '^🟡 <b>DB 사용량과 비용</b> (Neon): 예산에 거의 닿을 것 같아요$' <<< "$LAST_BRIEF" || true)"
brief "브리프 — 예상 비용 \$3.12 / 예산 \$3.11 (초과)" "$FIX" "${COMMON[@]}" NEON_BUDGET_USD=3.11
assert_eq "\$3.12 / \$3.11 → 넘을 것 같아요" "🟡 <b>예산을 넘을 것 같아요 — 기간 말 예상 \$3.12 / 예산 \$3.11</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
LAST_BRIEF="$NORMAL_BRIEF"   # 아래 기존 단언들은 정상 브리프를 본다
assert_eq "🟢 브리프 첫 줄" "🟢 <b>이상 없음 — 기간 말 예상 비용 \$3.12 / 예산 \$15, DB 자동 절전 작동 중</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
# M3: 점검 묶음 이름 통일 — quick = 빠른 점검, full = DB 포함 점검(readiness = DB 연결). 옛 이름 'DB 연결 점검'·'DB 점검' 없음
assert_eq "M3: 빠른 점검 줄" 1 "$(grep -c '^- 빠른 점검(서버 응답 / 화면 응답) 마지막 확인 ' <<< "$LAST_BRIEF" || true)"
assert_eq "M3: DB 포함 점검 줄" 1 "$(grep -c '^- DB 포함 점검(DB 연결 / 의상 API / 홈 화면) 마지막 확인 ' <<< "$LAST_BRIEF" || true)"
assert_eq "M3: 옛 이름 없음" 0 "$(grep -Ec 'DB 연결 점검|DB 점검' <<< "$LAST_BRIEF" || true)"
# L6: 쉬운 말 — '월말'(기간이 달 중간에 끝남)·맨 '기본 브랜치' 대신 '기간 말'·'운영 DB(기본 브랜치)'
assert_eq "L6: 월말 없음" 0 "$(grep -c '월말' <<< "$LAST_BRIEF" || true)"
assert_eq "L6: 운영 DB(기본 브랜치)" 1 "$(grep -c '^- 운영 DB(기본 브랜치)가 켜져 있던 비율 ' <<< "$LAST_BRIEF" || true)"
assert_eq "🟢 섹션: 사이트" 1 "$(grep -c '^🟢 <b>사이트</b>: 정상 (열린 장애 이슈 없음)$' <<< "$LAST_BRIEF" || true)"
assert_eq "🟢 섹션: 비용" 1 "$(grep -c '^🟢 <b>DB 사용량과 비용</b> (Neon): 예산 안$' <<< "$LAST_BRIEF" || true)"
assert_eq "🟢 섹션: 절전" 1 "$(grep -c '^🟢 <b>DB 자동 절전</b> (autosuspend): 작동 중$' <<< "$LAST_BRIEF" || true)"
assert_eq "🟢 섹션: 감시" 1 "$(grep -c '^🟢 <b>감시 자체</b>: 정상$' <<< "$LAST_BRIEF" || true)"
assert_eq "결제 기간 n일째 (경과 12.0일 = 13일째)" 1 "$(grep -c '^- 이번 결제 기간 <code>13</code>일째 / 31일$' <<< "$LAST_BRIEF" || true)"
assert_eq "SCHEDULER 기본(github) → 지연 안내" "$GH_NOTE" "$(tail -n 1 <<< "$LAST_BRIEF")"
assert_eq "SCHEDULER github → cron 드롭 설명 줄" 1 "$(grep -c 'GitHub 무료 스케줄이 늦거나 건너뛴 것' <<< "$LAST_BRIEF" || true)"
assert_eq "RUNS_WARN_PCT 기본 0 → 31/144 여도 🟢" 0 "$(grep -c '예정의 .*%보다 적' <<< "$LAST_BRIEF" || true)"
brief "브리프 🟢 정상 — preview" "$FIX" "${COMMON[@]}" BRIEF_MODE=preview
assert_eq "preview 태그 + 신호등" "[미리보기] 🟢" "$(sed -n 1p <<< "$LAST_BRIEF" | cut -d' ' -f1-2)"
# SCHEDULER=cloudflare: 정시 안내, GitHub 드롭 설명 없음 / 알 수 없는 값은 github 로
# 실제 워크플로는 cloudflare 모드에서 hb 가 UPTIME_CF_STALE 를 0/1 로 채운다(빈 값 = 조회 실패 = 확인 불가 🟡) — 정상 경로 테스트는 0 을 준다
brief "브리프 — SCHEDULER=cloudflare" "$FIX" "${COMMON[@]}" SCHEDULER=cloudflare UPTIME_CF_STALE=0
assert_eq "SCHEDULER cloudflare → 정시 안내" "다음 브리프: 내일 09:17" "$(tail -n 1 <<< "$LAST_BRIEF")"
assert_eq "SCHEDULER cloudflare → GitHub 드롭 설명 없음" 0 "$(grep -c 'GitHub 무료 스케줄' <<< "$LAST_BRIEF" || true)"
brief "브리프 — SCHEDULER=이상한값" "$FIX" "${COMMON[@]}" SCHEDULER=bogus
assert_eq "SCHEDULER 알 수 없음 → github 문구" "$GH_NOTE" "$(tail -n 1 <<< "$LAST_BRIEF")"
assert_eq "SCHEDULER 알 수 없음 → 첫 줄 🟡" "🟡 <b>repo 변수 SCHEDULER 값이 잘못됐어요 — github 또는 cloudflare 만 돼요 (지금은 GitHub 스케줄로 동작)</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "SCHEDULER 알 수 없음 → ⑤ 줄" 1 "$(grep -c '^- repo 변수 SCHEDULER 값 오류 🟡' <<< "$LAST_BRIEF" || true)"
brief "브리프 — SCHEDULER 대소문자·공백 (' Cloudflare ')" "$FIX" "${COMMON[@]}" "SCHEDULER= Cloudflare " UPTIME_CF_STALE=0
assert_eq "SCHEDULER ' Cloudflare ' → cloudflare 로 (gate 와 같은 해석)" "다음 브리프: 내일 09:17" "$(tail -n 1 <<< "$LAST_BRIEF")"
assert_eq "SCHEDULER ' Cloudflare ' → 🟡 아님" "🟢" "$(sed -n 1p <<< "$LAST_BRIEF" | cut -d' ' -f1)"
brief "브리프 — SCHEDULER 오류 (hb 가 SCHEDULER_BAD=1)" "$FIX" "${COMMON[@]}" SCHEDULER=github SCHEDULER_BAD=1
assert_eq "SCHEDULER_BAD=1 → 첫 줄 🟡" "🟡" "$(sed -n 1p <<< "$LAST_BRIEF" | cut -d' ' -f1)"
# 예약 실행기(Worker) 상태 — cloudflare 모드에서만. 60분 넘게 Worker run 없음 = 🟡 (GitHub 대비책으로 동작 중)
brief "브리프 🟡 예약 실행기 멈춤 (cloudflare)" "$FIX" "${COMMON[@]}" SCHEDULER=cloudflare UPTIME_CF_STALE=1 \
  UPTIME_CF_LAST="$(ISO $((NOW - 7200)))" UPTIME_CF_RUNS_24H=120 UPTIME_FALLBACK_RUNS_24H=3
assert_eq "CF 멈춤 → 첫 줄" "🟡 <b>예약 실행기(Cloudflare)가 1시간 넘게 안 돌았어요 — GitHub 대비책으로 도는 중이라 점검 시각이 불규칙해요 (토큰 만료 확인)</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "CF 멈춤 → 감시 자체 🟡" 1 "$(grep -c '^🟡 <b>감시 자체</b>: 확인 필요$' <<< "$LAST_BRIEF" || true)"
assert_eq "CF 멈춤 → 실행기 줄" 1 "$(grep -c '^- 예약 실행기(Cloudflare) 마지막 실행 <code>2시간 전</code> 🟡 / 최근 24시간 예약 실행기 120번, GitHub 대비책 3번 ' <<< "$LAST_BRIEF" || true)"
assert_eq "CF 멈춤 → 끝 줄" "다음 브리프: 내일 09:17 예정(예약 실행기가 멈춰 있으면 GitHub 대비책이 오후에 보내요)" "$(tail -n 1 <<< "$LAST_BRIEF")"
brief "브리프 🟢 예약 실행기 정상 (cloudflare)" "$FIX" "${COMMON[@]}" SCHEDULER=cloudflare UPTIME_CF_STALE=0 \
  UPTIME_CF_LAST="$(ISO $((NOW - 180)))" UPTIME_CF_RUNS_24H=144 UPTIME_FALLBACK_RUNS_24H=0
assert_eq "CF 정상 → 🟢" "🟢" "$(sed -n 1p <<< "$LAST_BRIEF" | cut -d' ' -f1)"
assert_eq "CF 정상 → 실행기 줄" 1 "$(grep -c '^- 예약 실행기(Cloudflare) 마지막 실행 <code>3분 전</code> / 최근 24시간 예약 실행기 144번, GitHub 대비책 0번 ' <<< "$LAST_BRIEF" || true)"
brief "브리프 🟡 예약 실행기 확인 불가 (cloudflare, 조회 실패)" "$FIX" "${COMMON[@]}" SCHEDULER=cloudflare
assert_eq "CF 확인 불가 → 첫 줄" "🟡 <b>예약 실행기(Cloudflare) 상태를 확인할 수 없어요 — 실행 목록 조회 실패</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "CF 확인 불가 → 실행기 줄" 1 "$(grep -c '^- 예약 실행기(Cloudflare) 마지막 실행 확인 불가 🟡 ' <<< "$LAST_BRIEF" || true)"
assert_eq "CF 확인 불가 → '기록 없음' 아님" 0 "$(grep -c '마지막 실행 기록 없음' <<< "$LAST_BRIEF" || true)"
brief "브리프 — github 모드는 UPTIME_CF_STALE 무시" "$FIX" "${COMMON[@]}" UPTIME_CF_STALE=1
assert_eq "github + CF_STALE=1 → 🟢 (Worker 없음)" "🟢" "$(sed -n 1p <<< "$LAST_BRIEF" | cut -d' ' -f1)"
assert_eq "github → 실행기 줄 없음" 0 "$(grep -c '예약 실행기' <<< "$LAST_BRIEF" || true)"
# 🟡 주의: 예산 85% 예상(80% 이상) + DB 점검 40시간 없음
brief "브리프 🟡 주의 — 예산 85% 예상 + DB 점검 40시간 없음" "$FIX" "${COMMON[@]}" NEON_BUDGET_USD=3.67 \
  UPTIME_LAST_FULL="$(ISO $((NOW - 144000)))" UPTIME_FULL_24H=0 UPTIME_FULL_EXEC_24H=0
WARN_BRIEF="$LAST_BRIEF"
assert_eq "🟡 첫 줄" "🟡 <b>예산의 80%를 넘을 것 같아요 — 기간 말 예상 \$3.12 / 예산 \$3.67 (85%) 외 1건</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "🟡 추가 줄" "- 🟡 DB 포함 점검이 40시간째 없어요 (기준 36시간)" "$(sed -n 3p <<< "$LAST_BRIEF")"
assert_eq "🟡 섹션: 비용" 1 "$(grep -c '^🟡 <b>DB 사용량과 비용</b> (Neon): 예산의 80%를 넘을 것 같아요$' <<< "$LAST_BRIEF" || true)"
assert_eq "🟡 섹션: 감시" 1 "$(grep -c '^🟡 <b>감시 자체</b>: 확인 필요$' <<< "$LAST_BRIEF" || true)"
assert_eq "🟡 섹션: 사이트는 🟢 그대로" 1 "$(grep -c '^🟢 <b>사이트</b>: 정상' <<< "$LAST_BRIEF" || true)"
# 임계값: NEON_BUDGET_WARN_PCT=90 이면 85% 는 🟢 / 0 이면 끔 / 숫자 아니면 기본 80
brief "브리프 — 예산 85%, 경고 90%" "$FIX" "${COMMON[@]}" NEON_BUDGET_USD=3.67 NEON_BUDGET_WARN_PCT=90
assert_eq "85% < 90% → 비용 🟢" 1 "$(grep -c '^🟢 <b>DB 사용량과 비용</b> (Neon): 예산 안$' <<< "$LAST_BRIEF" || true)"
brief "브리프 — 예산 85%, 경고 끔(0)" "$FIX" "${COMMON[@]}" NEON_BUDGET_USD=3.67 NEON_BUDGET_WARN_PCT=0
assert_eq "경고 0 → 첫 줄 🟢" "🟢" "$(sed -n 1p <<< "$LAST_BRIEF" | cut -d' ' -f1)"
brief "브리프 — 예산 경고 값 이상(abc → 기본 80)" "$FIX" "${COMMON[@]}" NEON_BUDGET_USD=3.67 NEON_BUDGET_WARN_PCT=abc
assert_eq "경고 값 이상 → 기본 80 적용" 1 "$(grep -c '^🟡 <b>DB 사용량과 비용</b>' <<< "$LAST_BRIEF" || true)"
# L1: 판정과 표시가 같은 값 — 3.12 / 3.915 = 79.7% 는 "(80%)" 로 보이므로 🟡 (표시 80% 인데 🟢 이면 어긋남)
brief "브리프 — 예산 79.7% (표시 80%)" "$FIX" "${COMMON[@]}" NEON_BUDGET_USD=3.915
assert_eq "L1: 표시 (80%) → 🟡" 1 "$(grep -c '^- 기간 말 예상 비용 <code>\$3.12</code> / 예산 <code>\$3.915</code> (80%) 🟡 <i>(80%부터 🟡)</i>$' <<< "$LAST_BRIEF" || true)"
assert_eq "L1: 비용 섹션 🟡" 1 "$(grep -c '^🟡 <b>DB 사용량과 비용</b>' <<< "$LAST_BRIEF" || true)"
brief "브리프 — 예산 77% (표시 77%)" "$FIX" "${COMMON[@]}" NEON_BUDGET_USD=4.05
assert_eq "L1: 77% → 🟢" 1 "$(grep -c '^🟢 <b>DB 사용량과 비용</b> (Neon): 예산 안$' <<< "$LAST_BRIEF" || true)"
# L2: 예산 0 = 미설정 — "예산 \$0 을 넘을 것 같아요" 가 아니라 비교 생략, 첫 줄 🟢
brief "브리프 — 예산 0 (미설정)" "$FIX" "${COMMON[@]}" NEON_BUDGET_USD=0
assert_eq "L2: 예산 0 → 첫 줄 🟢·예산 언급 없음" "🟢 <b>이상 없음 — 기간 말 예상 비용 \$3.12, DB 자동 절전 작동 중</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "L2: 예산 0 → 섹션 문구" 1 "$(grep -c '^🟢 <b>DB 사용량과 비용</b> (Neon): 예산 미설정 (비교 안 함)$' <<< "$LAST_BRIEF" || true)"
assert_eq "L2: 예산 0 → '넘을 것 같아요' 없음" 0 "$(grep -c '넘을 것 같아요\|\$0' <<< "$LAST_BRIEF" || true)"
# 경고 0(끔)이면 "(0%부터 🟡)" 대신 초과 때만이라고 쓴다
brief "브리프 — 예산 경고 끔 문구" "$FIX" "${COMMON[@]}" NEON_BUDGET_WARN_PCT=0
assert_eq "경고 0 → 안내 문구" 1 "$(grep -c '(넘을 것 같을 때만 🟡)' <<< "$LAST_BRIEF" || true)"
# 예산 초과는 '80%' 가 아니라 '예산을 넘을 것 같아요' + 47일 무커밋
brief "브리프 🟡 예산 초과 + DB 점검 40시간 + 47일 무커밋" "$FIX" "${COMMON[@]}" NEON_BUDGET_USD=3 \
  UPTIME_LAST_FULL="$(ISO $((NOW - 144000)))" UPTIME_FULL_24H=0 UPTIME_FULL_EXEC_24H=0 REPO_LAST_COMMIT_EPOCH=$((NOW - 47 * 86400))
assert_eq "예산 초과 첫 줄" "🟡 <b>예산을 넘을 것 같아요 — 기간 말 예상 \$3.12 / 예산 \$3 외 2건</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "예산 초과 → 80% 문구 아님" 0 "$(grep -c '예산의 80%를' <<< "$LAST_BRIEF" || true)"
assert_eq "47일 무커밋 줄" 1 "$(grep -c '^- 🟡 감시 저장소 47일째 커밋 없음 — 13일 뒤 감시가 자동으로 멈춰요' <<< "$LAST_BRIEF" || true)"
# RUNS_WARN_PCT: 50 이면 31/144(21%) → 🟡, 20 이면 전체 21% 는 통과지만 DB 점검 2/13(15%) → 🟡
brief "브리프 🟡 RUNS_WARN_PCT=50" "$FIX" "${COMMON[@]}" RUNS_WARN_PCT=50
assert_eq "RUNS_WARN_PCT=50 첫 줄" "🟡 <b>24시간 점검 횟수와 DB 포함 점검 횟수가 예정의 50%보다 적어요 — 예약 실행이 제대로 도는지 확인</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "RUNS_WARN_PCT=50 → 두 숫자 모두 🟡 + 기준 설명" 2 "$(grep -Ec '^- 최근 24시간 점검 <code>31</code>번 / 예정 144번 🟡 \(DB 포함 점검 <code>2</code>번 / 예정 13번 🟡\)$|예정의 50%보다 적으면 🟡' <<< "$LAST_BRIEF" || true)"
brief "브리프 🟡 RUNS_WARN_PCT=20 (DB 포함 점검만 미달)" "$FIX" "${COMMON[@]}" RUNS_WARN_PCT=20
assert_eq "RUNS_WARN_PCT=20 → DB 포함 점검 미달로 🟡" 1 "$(grep -c '^🟡 <b>감시 자체</b>' <<< "$LAST_BRIEF" || true)"
# L3: 전체(31/144=21%)는 통과라 첫 줄은 DB 포함 점검만 말하고, 🟡 도 그 숫자 뒤에만
assert_eq "L3: 첫 줄 = DB 포함 점검만" "🟡 <b>24시간 DB 포함 점검 횟수가 예정의 20%보다 적어요 — 예약 실행이 제대로 도는지 확인</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "L3: 🟡 는 DB 포함 점검 숫자 뒤에만" 1 "$(grep -c '^- 최근 24시간 점검 <code>31</code>번 / 예정 144번 (DB 포함 점검 <code>2</code>번 / 예정 13번 🟡)$' <<< "$LAST_BRIEF" || true)"
brief "브리프 — RUNS_WARN_PCT=10 (둘 다 통과)" "$FIX" "${COMMON[@]}" RUNS_WARN_PCT=10
assert_eq "RUNS_WARN_PCT=10 → 🟢" "🟢" "$(sed -n 1p <<< "$LAST_BRIEF" | cut -d' ' -f1)"
# 🔴 문제: 사이트 장애 중
brief "브리프 🔴 문제 — 사이트 장애 중" "$FIX" "${COMMON[@]}" \
  UPTIME_INCIDENT="{\"open\":true,\"number\":7,\"url\":\"$ISSUE\",\"failed\":\"liveness,robots\",\"since\":\"$(ISO $((NOW - 2700)))\"}"
CRIT_BRIEF="$LAST_BRIEF"
assert_eq "🔴 사이트 장애 첫 줄" "🔴 <b>사이트 장애 중 — 서버 응답(liveness), 화면 응답(robots) 실패</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "🔴 사이트 섹션" 1 "$(grep -c '^🔴 <b>사이트</b>: 장애 중$' <<< "$LAST_BRIEF" || true)"
BADFX="$(mktemp -d)"; cp "$FIX"/*.json "$BADFX/"; cp "$FIX/consumption_hourly_bad.json" "$BADFX/consumption_hourly.json"
PREV_DELTA=82080 brief "브리프 🔴 DB 자동 절전 의심 + 사이트 장애 중" "$BADFX" "${COMMON[@]}" \
  UPTIME_INCIDENT="{\"open\":true,\"number\":7,\"url\":\"$ISSUE\",\"failed\":\"liveness\",\"since\":\"$(ISO $((NOW - 2700)))\"}"
assert_eq "🔴 브리프 추가 문제 줄" "- 🔴 사이트 장애 중 — 서버 응답(liveness) 실패" "$(sed -n 3p <<< "$LAST_BRIEF")"
assert_eq "🔴 브리프 첫 줄" "🔴 <b>DB 자동 절전 미작동 의심 — 최근 24시간 중 22시간이 한 시간 내내 켜져 있었어요 외 1건</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "🔴 절전 섹션" 1 "$(grep -c '^🔴 <b>DB 자동 절전</b> (autosuspend): 미작동 의심$' <<< "$LAST_BRIEF" || true)"
brief "브리프 — heartbeat·incident 확인 불가" "$FIX" UPTIME_LAST_SUCCESS= UPTIME_LAST_FULL= UPTIME_INCIDENT= REPO_LAST_COMMIT_EPOCH=
# F3: heartbeat 를 못 읽으면 첫 줄 🟡 — 감시가 도는지 모르는 상태를 🟢 로 보이지 않게. 확인 불가 항목은 전부 '외 N건'
assert_eq "heartbeat 확인 불가 → 첫 줄 🟡" "🟡 <b>사이트 점검 마지막 성공을 확인할 수 없어요 — 감시가 도는지 직접 확인 외 3건</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "확인 불가 → 사이트 🟡" 1 "$(grep -c '^🟡 <b>사이트</b>: 확인 불가 (장애 이슈 조회 실패)$' <<< "$LAST_BRIEF" || true)"
# F3: 22시에 멈춘 감시(09:17 기준 11h) — 첫 줄 🟡, ② 사이트는 🟢 정상이 아님
brief "브리프 🟡 사이트 점검 11h 전 (밤사이 멈춤)" "$FIX" "${COMMON[@]}" UPTIME_LAST_SUCCESS="$(ISO $((NOW - 39600)))"
assert_eq "uptime 11h → 첫 줄 🟡 (중복 문장 없이 1건)" "🟡 <b>사이트 점검이 6시간 넘게 멈췄어요 — 장애가 나도 알림이 안 와요</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "uptime 11h → 사이트 🟢 아님" 0 "$(grep -c '^🟢 <b>사이트</b>' <<< "$LAST_BRIEF" || true)"
assert_eq "uptime 11h → 마지막 확인 표시" 1 "$(grep -c '^🟡 <b>사이트</b>: 확인 필요 — 열린 장애 이슈는 없지만 마지막 확인이 11시간 전' <<< "$LAST_BRIEF" || true)"
# H1: 4h 전 — SCHEDULER=github(기본)에서는 cron 지연이 일상(실측 브리프 시간대 절반이 3h 초과, 6h 초과 0회)이라
#   🟡 로 올리지 않고 글자로만 알린다. ⑤ "GitHub 지연 — 감시 고장 아님" 과 첫 줄 색이 모순되지 않게
brief "브리프 🟢 사이트 마지막 확인 4h 전 (github)" "$FIX" "${COMMON[@]}" UPTIME_LAST_SUCCESS="$(ISO $((NOW - 14400)))"
assert_eq "H1 github: uptime 4h → 첫 줄 🟢" "🟢" "$(sed -n 1p <<< "$LAST_BRIEF" | cut -d' ' -f1)"
assert_eq "H1 github: uptime 4h → 사이트 🟢 + 글자 표시" 1 "$(grep -c '^🟢 <b>사이트</b>: 열린 장애 이슈 없음 (마지막 확인 4시간 전 — GitHub 지연으로 점검이 드문드문 돌아요)$' <<< "$LAST_BRIEF" || true)"
assert_eq "H1 github: uptime 4h → '정상인지 몰라요' 없음" 0 "$(grep -c '정상인지 몰라요' <<< "$LAST_BRIEF" || true)"
# 경계: 5h59m 은 🟢, 6h01m 은 🟡 (= 감시 멈춤 기준 HB_UPTIME_MAX_H 와 같은 선)
brief "브리프 — uptime 5h59m (github)" "$FIX" "${COMMON[@]}" UPTIME_LAST_SUCCESS="$(ISO $((NOW - 21540)))"
assert_eq "H1 github: 5h59m → 🟢" "🟢" "$(sed -n 1p <<< "$LAST_BRIEF" | cut -d' ' -f1)"
brief "브리프 — uptime 6h01m (github)" "$FIX" "${COMMON[@]}" UPTIME_LAST_SUCCESS="$(ISO $((NOW - 21660)))"
assert_eq "H1 github: 6h01m → 첫 줄 🟡 (중복 문장 없이)" "🟡 <b>사이트 점검이 6시간 넘게 멈췄어요 — 장애가 나도 알림이 안 와요</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "H1 github: 6h01m → 사이트 🟡 확인 필요" 1 "$(grep -c '^🟡 <b>사이트</b>: 확인 필요 — 열린 장애 이슈는 없지만 마지막 확인이 6시간 전 <i>(6시간 넘게' <<< "$LAST_BRIEF" || true)"
# SCHEDULER=cloudflare(정시 실행)에서는 3h 공백이 실제 이상 → 사이트 🟡 = 첫 줄 🟡
brief "브리프 🟡 사이트 마지막 확인 4h 전 (cloudflare)" "$FIX" "${COMMON[@]}" UPTIME_LAST_SUCCESS="$(ISO $((NOW - 14400)))" SCHEDULER=cloudflare UPTIME_CF_STALE=0
assert_eq "H1 cloudflare: uptime 4h → 첫 줄 🟡" "🟡 <b>사이트 마지막 확인이 4시간 전 — 지금 정상인지 몰라요</b>" "$(sed -n 1p <<< "$LAST_BRIEF")"
assert_eq "H1 cloudflare: uptime 4h → 사이트 🟡 (3시간 기준)" 1 "$(grep -c '^🟡 <b>사이트</b>: 확인 필요 — .*(3시간 넘게' <<< "$LAST_BRIEF" || true)"
assert_eq "H1 cloudflare: uptime 4h → 감시 자체는 🟢 (6h 미만)" 1 "$(grep -c '^🟢 <b>감시 자체</b>: 정상$' <<< "$LAST_BRIEF" || true)"
brief "브리프 — uptime 2h59m (cloudflare)" "$FIX" "${COMMON[@]}" UPTIME_LAST_SUCCESS="$(ISO $((NOW - 10740)))" SCHEDULER=cloudflare UPTIME_CF_STALE=0
assert_eq "H1 cloudflare: 2h59m → 🟢 정상" 1 "$(grep -c '^🟢 <b>사이트</b>: 정상 (열린 장애 이슈 없음)$' <<< "$LAST_BRIEF" || true)"
assert_eq "uptime 7분 전 → 사이트 🟢 (정상 경로)" 1 "$(grep -c '^🟢 <b>사이트</b>: 정상' <<< "$NORMAL_BRIEF" || true)"
rm -rf "$BADFX"
# 09:17 전 실행(수동 preview 등)은 '오늘 09:17' — 최소 brief.json 으로 fmt_brief 직접
printf '{"now":%s,"sched":"cloudflare"}' $((NOW - 3600)) > "$RUNNER_TEMP/mini.json"
assert_eq "09:17 전 → 오늘" "다음 브리프: 오늘 09:17" "$(fmt_brief json="$RUNNER_TEMP/mini.json" | tail -n 1)"
# L5: N일째는 period.day(반올림 전 경과일 기준)를 쓴다 — elapsed 12.96 이 r(1) 로 13.0 이 돼도 13일째(14일째 아님)
printf '{"now":%s,"period":{"elapsed":13.0,"total":31,"day":13}}' "$NOW" > "$RUNNER_TEMP/mini.json"
assert_eq "L5: period.day 우선" 1 "$(fmt_brief json="$RUNNER_TEMP/mini.json" | grep -c '^- 이번 결제 기간 <code>13</code>일째 / 31일$' || true)"
printf '{"now":%s,"period":{"elapsed":12.0,"total":31}}' "$NOW" > "$RUNNER_TEMP/mini.json"
assert_eq "L5: 옛 brief.json(day 없음) → elapsed 내림+1" 1 "$(fmt_brief json="$RUNNER_TEMP/mini.json" | grep -c '<code>13</code>일째' || true)"
# L4: 기본(plain) 형식 브리프 — N일째 31 상한·"N분 전"·점검 횟수 줄(🟡 이유)·점검 이름 통일
printf '%s' "{\"now\":$NOW,\"period\":{\"elapsed\":32.4,\"total\":31},\"cu\":{},\"cost\":{\"budget\":15},\"site\":{\"open\":false},\"as\":{},\"hb\":{\"uptime_at\":$((NOW - 420)),\"full_at\":$((NOW - 36780)),\"runs24\":31,\"full24\":3,\"full_exec24\":2,\"design_runs\":144,\"design_full\":13,\"full_low\":true},\"repo\":{\"idle_days\":14},\"level\":{\"site\":\"ok\",\"watch\":\"warn\",\"overall\":\"warn\"}}" > "$RUNNER_TEMP/pl.json"
PLB="$(plain_brief json="$RUNNER_TEMP/pl.json")"
shown_plain "기본(plain) 형식 브리프 — 직접 렌더" "$PLB"
assert_eq "L4: plain N일째 상한" "🟡 simparty 일일 브리프 10-13 (결제 기간 31일째 / 31일)" "$(sed -n 1p <<< "$PLB")"
assert_eq "L4: plain 'N분 전' (소수 시간 아님)" 1 "$(grep -c '^감시: 사이트 점검 7분 전 / DB 포함 점검 10시간 전$' <<< "$PLB" || true)"
assert_eq "L4: plain 점검 횟수 줄 + 🟡 이유" 1 "$(grep -c '^최근 24시간 점검 31번 / 예정 144번 (DB 포함 점검 2번 / 예정 13번 🟡)$' <<< "$PLB" || true)"
# M1: 알림이 주기를 단정하지 않는다 — github(기본)면 "10분 주기"·"약 10분 간격" 대신 GitHub 지연 안내, cloudflare 면 10분 그대로
SF_GH="$(fmt_sample selffail now="$NOW" run="$RUN")"
assert_eq "M1 github: selffail '10분 주기' 단정 없음" 0 "$(grep -c '10분 주기\|10분 뒤' <<< "$SF_GH" || true)"
assert_eq "M1 github: selffail 지연 안내" 1 "$(grep -c '^- 정기 점검은 설계상 10분마다지만 지금은 GitHub 무료 스케줄 지연으로 몇 시간 걸릴 수 있어요$' <<< "$SF_GH" || true)"
SF_CF="$(SCHEDULER=cloudflare fmt_sample selffail now="$NOW" run="$RUN")"
assert_eq "M1 cloudflare: selffail 10분 뒤" 1 "$(grep -c '^- 다음 정기 점검(10분 뒤)이 성공하면' <<< "$SF_CF" || true)"
assert_eq "M1 cloudflare: 지연 안내 없음" 0 "$(grep -c 'GitHub 무료 스케줄 지연' <<< "$SF_CF" || true)"
show "🟡 감시 자체 실패 — uptime (SCHEDULER=cloudflare)" "$SF_CF"
DT_GH="$(fmt_sample detected now="$NOW" run="$RUN")"
assert_eq "M1 github: 감지 '약 10분 간격' 없음" 0 "$(grep -c '약 10분 간격' <<< "$DT_GH" || true)"
assert_eq "M1 github: 감지 지연 안내 1줄" 1 "$(grep -c '^- 점검은 설계상 10분마다지만 지금은 GitHub 무료 스케줄 지연으로' <<< "$DT_GH" || true)"
DT_CF="$(SCHEDULER=cloudflare fmt_sample detected now="$NOW" run="$RUN")"
assert_eq "M1 cloudflare: 감지 '약 10분 간격' 유지" 1 "$(grep -c '연속 2번(약 10분 간격)' <<< "$DT_CF" || true)"
assert_eq "M1 cloudflare: 감지 지연 안내 없음" 0 "$(grep -c 'GitHub 무료 스케줄 지연' <<< "$DT_CF" || true)"
show "🔴 감지 샘플 (SCHEDULER=cloudflare)" "$DT_CF"
NSF_GH="$(fmt_selffail workflow=neon-usage now="$NOW" run="$RUN" reason=x)"
assert_eq "M1 github: neon selffail 지연 안내" 1 "$(grep -c '^- 지금은 GitHub 무료 스케줄 지연으로 정기 브리프가 오후에 올 수 있어요$' <<< "$NSF_GH" || true)"
# M3·L6: DB 포함 점검 실패 알림 — 판정 이름·조사
DBA="$(fmt_outage_detected kind=new results="$R" now="$NOW" mode=full issue="$ISSUE" run="$RUN")"
assert_eq "M3: readiness 실패 판정 = DB 연결 실패" 1 "$(sed -n 1p <<< "$DBA" | grep -c 'DB 연결 실패 (서버가 DB 를 못 읽어요)' || true)"
assert_eq "L6: 조사 '(home) 는' 없음" 0 "$(grep -c ') 는 DB' <<< "$DBA" || true)"
assert_eq "L6: DB 를 거치는 점검(…)은" 1 "$(grep -c '^- DB 를 거치는 점검(DB 연결(readiness), 의상 API(categories))은 DB 포함 점검에서만 다시 확인해요' <<< "$DBA" || true)"
printf '%s\t%s\t%s\t%s\t%s\n' liveness 1 200 0.2 ok readiness 1 200 0.3 ok categories 0 500 0.4 'HTTP 500' > "$RUNNER_TEMP/cat.tsv"
assert_eq "M3: categories 만 실패 = 의상 API 실패" 1 "$(fmt_outage_detected kind=new results="$RUNNER_TEMP/cat.tsv" now="$NOW" mode=full | sed -n 1p | grep -c '의상 API 실패' || true)"

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
  grep -c '🔴 readiness: 503' <<< "$TG_MSG" >> "$RUNNER_TEMP/guard.out" || true
) >/dev/null 2>&1
assert_eq "오타 렌더 → plain 비상 메시지" "plain|1|🔴 simparty 장애 확대 — 새로 실패: categories" "$(sed -n 1p "$RUNNER_TEMP/guard.out" | sed -E 's/ \([0-9-]+ [0-9:]+ KST, full\)$//')"
assert_eq "비상 메시지에 옛 형식 체크 표" 1 "$(sed -n 2p "$RUNNER_TEMP/guard.out")"
assert_eq "오타 렌더 → note_fail" 1 "$(grep -c '템플릿 렌더 실패: fmt_outage_expanded' "$RUNNER_TEMP/monitor_fail_reason")"
# 빈 출력(rc 0)도 같은 처리
( fmt_test() { :; }; tg_render fmt_test run="$RUN"; x=no; [[ "$TG_MSG" == "[샘플] "* ]] && x=yes; printf '%s|%s' "$TG_MSG_PM" "$x" > "$RUNNER_TEMP/guard.out" ) >/dev/null 2>&1
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
  if [ "${TG_FAKE_FAIL:-0}" = "1" ]; then
    [ -z "$out" ] || printf '{"ok":false,"error_code":401,"description":"Unauthorized"}' > "$out"
    printf '401'; exit 0
  fi
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
assert_eq "(a) 옛 형식 체크 표 (실패 🔴)" 1 "$(grep -c '^🔴 liveness: 503' "$TG_DIR/0.txt" 2>/dev/null || true)"
assert_eq "(a) 이슈 URL" 1 "$(grep -c '^이슈: https://github.com/o/r/issues/9$' "$TG_DIR/0.txt" 2>/dev/null || true)"
assert_eq "(a) 상태 기록(이슈 본문 마커 편집) 진행" 1 "$(grep -c '^issue edit 9 ' "$GH_LOG")"
assert_eq "(a) 실패 사유에 템플릿 고장" 1 "$(grep -c 'telegram-format.sh 사용 불가' "$D/rt/monitor_fail_reason")"
shown_plain "고장 주입 (a) 문법 오류 — uptime.sh 가 실제 보낸 🔴 (plain)" "$(cat "$TG_DIR/0.txt" 2>/dev/null)"
if [ -n "$PY" ]; then
  # 이어서 워크플로 '감시 자체 실패' 스텝 (같은 RUNNER_TEMP — 위 실패 사유가 실린다)
  run_selffail "$D" uptime.yml MODE=quick || bad "(a) uptime.yml selffail 스텝 비0 종료"
  assert_eq "(a) selffail: 텔레그램 추가 1건" 2 "$(fi_count)"
  assert_eq "(a) selffail: plain" plain "$(cat "$TG_DIR/1.pm" 2>/dev/null)"
  assert_eq "(a) selffail: 제목" "🟡 감시 자체 실패: uptime (quick) — 이후 6시간 같은 알림 억제" "$(sed -n 1p "$TG_DIR/1.txt" 2>/dev/null)"
  assert_eq "(a) selffail: 사유 실림" 1 "$(grep -c 'telegram-format.sh 사용 불가' "$TG_DIR/1.txt" 2>/dev/null || true)"
  assert_eq "(a) selffail: 억제 상태 저장" "saved=1" "$(cat "$D/rt/out" 2>/dev/null | grep saved || true)"
  shown_plain "고장 주입 (a) 문법 오류 — '감시 자체 실패' 스텝이 실제 보낸 🟡 (plain)" "$(cat "$TG_DIR/1.txt" 2>/dev/null)"
  # neon-usage.yml 의 같은 스텝
  fi_env "$D"; echo "Neon API 401" > "$D/rt/monitor_fail_reason"; rm -rf "$D/.selffail"
  run_selffail "$D" neon-usage.yml BRIEF_MODE=normal || bad "(a) neon-usage.yml selffail 스텝 비0 종료"
  assert_eq "(a) neon selffail: plain 1건" "1|plain" "$(fi_count)|$(cat "$TG_DIR/0.pm" 2>/dev/null)"
  assert_eq "(a) neon selffail: 제목" "🟡 감시 자체 실패: neon-usage (normal) — 이후 6시간 같은 알림 억제" "$(sed -n 1p "$TG_DIR/0.txt" 2>/dev/null)"
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
shown_plain "고장 주입 (b) 변수 오타 — uptime.sh 가 실제 보낸 비상 🔴 (plain)" "$(cat "$TG_DIR/0.txt" 2>/dev/null)"

# (b') 브리프 변수 오타 — neon-usage.sh 가 옛 형식 plain 브리프를 보낸다
D="$(mk_broken brieftypo brieftypo)"; fi_env "$D"
BST="$(mktemp -d)"
RC=0
( cd "$D" && env PATH="$FI/bin:$PATH" RUNNER_TEMP="$D/rt" NEON_FIXTURE_DIR="$FIX" NEON_PROJECT_ID=proj-fixture NOW_EPOCH="$NOW" \
    STATE_DIR="$BST" GITHUB_STEP_SUMMARY= GITHUB_OUTPUT="$D/rt/ghout" TELEGRAM_BOT_TOKEN=x TELEGRAM_CHAT_ID=1 "${COMMON[@]}" \
    bash .github/scripts/neon-usage.sh ) > "$D/neon.log" 2>&1 || RC=$?
assert_eq "(b') neon-usage.sh 종료코드 1 + plain 1건" "1|1|plain" "$RC|$(fi_count)|$(cat "$TG_DIR/0.pm" 2>/dev/null)"
# 템플릿 고장으로 job 은 실패해도 브리프는 갔다 → sent=1 (schedule-gate 가 대비책 2통째를 막는 근거)
assert_eq "(b') 전송 표식 sent=1" "sent=1" "$(grep '^sent=' "$D/rt/ghout" 2>/dev/null || true)"
shown_plain "고장 주입 (b') 브리프 변수 오타 — neon-usage.sh 가 실제 보낸 브리프 (plain)" "$(cat "$TG_DIR/0.txt" 2>/dev/null)"
assert_eq "(b') 기본 형식 브리프 첫 줄" "🟢 simparty 일일 브리프 10-13 (결제 기간 13일째 / 31일)" "$(sed -n 1p "$TG_DIR/0.txt" 2>/dev/null)"
# 텔레그램 전송 실패면 표식 없음 → 대비책이 다시 보낸다
fi_env "$D"; : > "$D/rt/ghout"; RC=0
( cd "$D" && env PATH="$FI/bin:$PATH" TG_FAKE_FAIL=1 RUNNER_TEMP="$D/rt" NEON_FIXTURE_DIR="$FIX" NEON_PROJECT_ID=proj-fixture NOW_EPOCH="$NOW" \
    STATE_DIR="$BST" GITHUB_STEP_SUMMARY= GITHUB_OUTPUT="$D/rt/ghout" TELEGRAM_BOT_TOKEN=x TELEGRAM_CHAT_ID=1 "${COMMON[@]}" \
    bash .github/scripts/neon-usage.sh ) > "$D/neon.log" 2>&1 || RC=$?
assert_eq "(b'') 전송 실패 → 종료코드 1·표식 없음" "1|0" "$RC|$(grep -c '^sent=' "$D/rt/ghout" 2>/dev/null || true)"
rm -rf "$BST"

# (정상) 템플릿 정상 + 전송 성공 → 종료코드 0, HTML 1건, sent=1 (고장 주입 아님 — 원본 스크립트 그대로)
D0="$(mktemp -d)"; fi_env "$D0"; BST0="$(mktemp -d)"; RC=0
( env PATH="$FI/bin:$PATH" RUNNER_TEMP="$D0/rt" NEON_FIXTURE_DIR="$FIX" NEON_PROJECT_ID=proj-fixture NOW_EPOCH="$NOW" \
    STATE_DIR="$BST0" GITHUB_STEP_SUMMARY= GITHUB_OUTPUT="$D0/rt/ghout" TELEGRAM_BOT_TOKEN=x TELEGRAM_CHAT_ID=1 "${COMMON[@]}" \
    bash "$SCRIPTS/neon-usage.sh" ) > "$D0/neon.log" 2>&1 || RC=$?
assert_eq "(정상) 종료코드 0 + HTML 1건 + sent=1" "0|1|HTML|sent=1" "$RC|$(fi_count)|$(cat "$TG_DIR/0.pm" 2>/dev/null)|$(grep '^sent=' "$D0/rt/ghout" 2>/dev/null || true)"
rm -rf "$D0" "$BST0"

# (c) monitor-lib.sh 자체 고장 — selffail 스텝 서브셸이 죽어도 인라인 plain 으로 전송
if [ -n "$PY" ]; then
  D="$(mk_broken libbroken libbroken)"; fi_env "$D"; echo "uptime.sh 비정상 종료" > "$D/rt/monitor_fail_reason"
  run_selffail "$D" uptime.yml MODE=quick || bad "(c) selffail 비0"
  assert_eq "(c) 인라인 plain 1건" "1|plain" "$(fi_count)|$(cat "$TG_DIR/0.pm" 2>/dev/null)"
  assert_eq "(c) 인라인 제목" "🟡 감시 자체 실패: uptime (quick) — 이후 6시간 같은 알림 억제" "$(sed -n 1p "$TG_DIR/0.txt" 2>/dev/null)"
  assert_eq "(c) 억제 상태 저장" "saved=1" "$(grep saved "$D/rt/out" 2>/dev/null || true)"
  shown_plain "고장 주입 (c) monitor-lib.sh 고장 — 인라인 plain 🟡" "$(cat "$TG_DIR/0.txt" 2>/dev/null)"
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
