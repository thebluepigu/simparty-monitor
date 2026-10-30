# shellcheck shell=bash
# 감시 워크플로(uptime.yml / neon-usage.yml) 공통 함수. source 해서 쓴다.
#
# 보안 규칙: set -x 금지, curl -v 금지, 토큰 echo 금지.
# 텔레그램 토큰은 argv 에 올리지 않고 curl 설정을 stdin(-K -)으로 넘긴다
# (GitHub 로그 마스킹에 더해 프로세스 목록 노출도 피함).
#
# 템플릿 오류 내성 (telegram-format.sh 를 고치다 실수해도 알림은 간다):
#   1) 로드 가드 — telegram-format.sh 를 `bash -n` 으로 검사하고 서브셸에서 시험 source(필수 함수 존재 확인)까지 통과해야
#      진짜로 source 한다. 하나라도 실패하면 source 하지 않고 fmt_* 를 아래 plain_*(옛 형식: 제목 + 체크 표 + URL)로
#      대체하고, 모든 전송을 parse_mode 없이 보낸다(TG_FORCE_PLAIN). note_fail + TG_DEGRADED=1(호출부가 job 실패 처리).
#   2) 렌더 가드 — tg_render/tg_fmt_send 가 fmt_* 를 서브셸로 돌려 비0 종료(set -u 미정의 변수 등)·빈 출력이면
#      같은 이름의 plain_* 로 대체해 plain 으로 보낸다. note_fail + TG_DEGRADED=1.
#   3) tg_send 는 빈 본문을 보내지 않는다(텔레그램 400 "message text is empty" 는 재전송 대상이 아니라 조용히 사라짐).
#   plain_* 는 이 파일에만 의존한다(telegram-format.sh 를 부르지 않음). CI(.github/workflows/ci.yml)가 bash -n·테스트로 사전 차단.

MONITOR_UA="simparty-monitor/1.0 (+GitHub Actions; thebluepigu/simparty-monitor)"
TG_FAILED=0
TG_DEGRADED=0      # 템플릿 오류로 기본(plain) 형식을 쓴 적 있음 → 호출부가 job 을 실패로 표시(GitHub 메일 + 감시 실패 알림)
TG_FORCE_PLAIN=0   # telegram-format.sh 를 못 써 plain_* 대체 중 → 모든 전송을 parse_mode 없이
TG_MSG=""; TG_MSG_PM=""   # tg_render 결과 (본문 · ""=HTML | plain)

# KST 현재 시각 "YYYY-MM-DD HH:MM" (러너 tzdata 의존 없이 UTC+9 계산)
kst_now() { date -u -d '+9 hours' '+%Y-%m-%d %H:%M'; }

# 감시 자체 실패 사유 기록 → 워크플로의 if: failure() 스텝이 텔레그램에 첨부
note_fail() { printf '%s\n' "$*" >> "${RUNNER_TEMP:-/tmp}/monitor_fail_reason"; }

# =============================================================================
# 기본(plain) 형식 — 템플릿을 쓸 수 없을 때의 비상 본문. telegram-format.sh 의 fmt_* 와 같은 key=value 인자를 받는다.
# 옛 형식(2026-10 이전)과 같은 모양: 제목 한 줄 + 체크 표 + 이슈·run URL. parse_mode 없이 보내므로 이스케이프 불필요.
# 신호등은 템플릿과 같다: 🟢 정상·복구 / 🟡 주의(감시 자체 실패·장애·복구 반복) / 🔴 문제·장애. 한 줄 안 구분은 " / ".
# =============================================================================
_pl_args() {
  local -n _pl_map="$1"; shift
  local kv
  for kv in "$@"; do
    case "$kv" in *=*) _pl_map["${kv%%=*}"]="${kv#*=}" ;; esac
  done
}
# 결과 TSV → "🟢 name: code (t s) detail" 줄 (통과 🟢 · 실패 🔴)
_pl_table() { [ -s "${1-}" ] || return 0; awk -F'\t' '{printf "%s %s: %s (%ss) %s\n", ($2=="1"?"🟢":"🔴"), $1, $3, $4, $5}' "$1"; }
_pl_note() { printf '%s' "[기본 형식] 텔레그램 템플릿(telegram-format.sh) 오류로 대체 전송 — 실행 로그 확인"; }
_pl_print() { local IFS=$'\n'; printf '%s' "${L[*]}"; }

plain_outage() {
  local -A a=(); _pl_args a "$@"
  local head
  case "${a[kind]:-new}" in
    new)         head="🔴 simparty 장애 감지" ;;
    reopen)      head="🔴 simparty 장애 재발" ;;
    selffail)    head="🔴 simparty 장애 감지 — GitHub 이슈 기록 실패로 상태 추적 불가" ;;
    flap)        head="🟡 simparty 장애·복구 반복" ;;
    remind)      head="🔴 simparty 장애 지속" ;;
    retry)       head="🔴 simparty 장애 지속 — 직전 알림 전송 실패분 재시도" ;;
    flap_remind) head="🔴 simparty 장애 반복 중" ;;
    expanded)    head="🔴 simparty 장애 확대 — 새로 실패: ${a[new_fails]:-?}" ;;
    *)           head="🔴 simparty 장애" ;;
  esac
  local -a L=("${a[tag]-}${head} ($(kst_now) KST, ${a[mode]:-?})")
  [ -z "${a[failed]-}" ] || L+=("실패 점검: ${a[failed]}")
  local t; t="$(_pl_table "${a[results]-}")"; [ -z "$t" ] || L+=("$t")
  [ -z "${a[issue]-}" ] || L+=("이슈: ${a[issue]}")
  [ -z "${a[run]-}" ] || L+=("run: ${a[run]}")
  L+=("" "$(_pl_note)")
  _pl_print
}
plain_outage_detected() { plain_outage kind=new "$@"; }
plain_flap()            { plain_outage "$@" kind=flap; }
plain_outage_ongoing()  { plain_outage kind=remind "$@"; }
plain_outage_expanded() { plain_outage "$@" kind=expanded; }
plain_recovered() {
  local -A a=(); _pl_args a "$@"
  local -a L=("${a[tag]-}🟢 simparty 복구 ($(kst_now) KST 확인, ${a[mode]:-?})")
  local t; t="$(_pl_table "${a[results]-}")"; [ -z "$t" ] || L+=("$t")
  [ -z "${a[issue]-}" ] || L+=("이슈: ${a[issue]}")
  [ -z "${a[run]-}" ] || L+=("run: ${a[run]}")
  L+=("" "$(_pl_note)")
  _pl_print
}
plain_selffail() {
  local -A a=(); _pl_args a "$@"
  local -a L=("${a[tag]-}🟡 감시 자체 실패: ${a[workflow]:-?}${a[mode]:+ (${a[mode]})} — 이후 ${a[suppress_h]:-6}시간 같은 알림 억제")
  [ -z "${a[reason]-}" ] || L+=("${a[reason]:0:900}")
  [ -z "${a[run]-}" ] || L+=("${a[run]}")
  L+=("" "$(_pl_note)")
  _pl_print
}
plain_test() {
  local -A a=(); _pl_args a "$@"
  local -a L=("[샘플] simparty 감시 텔레그램 연동 확인 ($(kst_now) KST) — 실제 장애 아님")
  [ -z "${a[run]-}" ] || L+=("${a[run]}")
  L+=("" "$(_pl_note)")
  _pl_print
}
plain_sample() {
  local which="${1:-?}"; shift || true
  local -A a=(); _pl_args a "$@"
  local -a L=("[샘플] ${which} — 템플릿 오류로 서식 샘플을 만들 수 없음 (실제 장애 아님)")
  L+=("" "$(_pl_note)")
  _pl_print
}
# 일일 브리프: neon-usage.sh 가 만든 brief.json 에서 기본 형식 8줄. 색은 brief.json .level(neon-usage.sh 판정)을 그대로 쓴다
# (.level 이 없는 옛 brief.json 이면 옛 플래그로 대략 계산). 말·숫자 규칙은 fmt_brief 와 같게(N일째 상한·"N분 전"·점검 이름)
plain_brief() {
  local -A a=(); _pl_args a "$@"
  local json="${a[json]-}" tag="${a[tag]-}"
  if [ -s "$json" ] && jq -r --arg tag "$tag" '
      def n: if . == null then "n/a" else tostring end;
      def c($l): if $l == "crit" then "🔴" elif $l == "warn" then "🟡" else "🟢" end;
      def ago($t): if $t == null then "기록 없음 🟡"
        else ((.now - $t) as $s
          | if $s < 60 then "방금" elif $s < 3600 then "\($s / 60 | floor)분 전"
            elif $s < 172800 then "\($s / 3600 | floor)시간 전" else "\($s / 86400 | floor)일 전" end) end;
      ((.as.bad // false) or (.site.open // false)) as $crit
      | ((.cost.over // false) or (.cost.near // false) or (.hb.uptime_bad // false) or (.hb.full_bad // false)
         or (.repo.bad // false) or .hb.uptime_at == null or .site == null) as $warn
      | (.level.overall // (if $crit then "crit" elif $warn then "warn" else "ok" end)) as $all
      | (if .preview and $tag == "" then "[미리보기] " else $tag end) as $t
      | (.period.day // (if .period.elapsed == null then null else (.period.elapsed | floor) + 1 end)) as $d0
      | (if $d0 != null and .period.total != null and $d0 > .period.total then .period.total else $d0 end) as $day
      | (if (.cost // {}) | has("budget_set") then .cost.budget_set else ((.cost.budget // 0) > 0) end) as $bset
      | (.level.site // (if .site == null then "warn" elif (.site.open // false) then "crit"
                         elif (if (.hb // {}) | has("site_stale") then .hb.site_stale else ((.hb.uptime_fresh // false) | not) end) then "warn"
                         else "ok" end)) as $lsite
      | [ "\($t)\(c($all)) simparty 일일 브리프 \((.now // now) + 32400 | strftime("%m-%d")) (결제 기간 \($day | n)일째 / \(.period.total | n)일)",
          "DB 사용량(CU-h): 지금까지 \(.cu.hours | n) → 기간 말 예상 \(.cu.projected | n)\(if .cu.approx then " (근사치)" else "" end)",
          "기간 말 예상 비용: $\(.cost.projected | n) / \(if $bset then "예산 $\(.cost.budget | n)\(if .cost.pct == null then "" else " (\(.cost.pct)%)" end)" else "예산 미설정" end)\(if .cost.over then " 🟡 초과 예상" elif (.cost.near // false) then " 🟡 예산의 \(.cost.warn_pct)% 이상" else "" end)",
          "사이트: \(if .site == null then "🟡 확인 불가" elif .site.open then "🔴 장애 중 \(.site.failed // "")" elif $lsite == "warn" then "🟡 열린 장애 이슈 없음 / 최근 확인 없음" else "🟢 열린 장애 이슈 없음" end)",
          "DB 자동 절전: \(if .as.bad then "🔴 미작동 의심" elif (.as.hour_judged or .as.delta_judged) then "🟢 작동 중" else "🟡 판정 생략" end)",
          "감시: 사이트 점검 \(ago(.hb.uptime_at))\(if .hb.uptime_at != null and .hb.uptime_bad then " 🟡" else "" end) / DB 포함 점검 \(ago(.hb.full_at))\(if .hb.full_bad then " 🟡" else "" end)",
          (if .hb.runs24 == null then "최근 24시간 점검 횟수 확인 불가"
           else "최근 24시간 점검 \(.hb.runs24)번 / 예정 \(.hb.design_runs | n)번\(if .hb.runs_low // false then " 🟡" else "" end)\(if .hb.full24 == null then "" else " (DB 포함 점검 \(.hb.full_exec24 // .hb.full24)번 / 예정 \(.hb.design_full | n)번\(if .hb.full_low // false then " 🟡" else "" end))" end)" end),
          "감시 저장소 마지막 커밋 \(if .repo.idle_days == null then "확인 불가 🟡" else "\(.repo.idle_days)일 전\(if .repo.bad then " 🟡" else "" end)" end)"
        ] | join("\n")' "$json" 2>/dev/null; then
    printf '\n%s' "$(_pl_note)"
  else
    printf '%s🟡 일일 브리프 렌더 실패 — 입력(brief.json) 없음·형식 오류. 실행 로그 확인\n\n%s' "$tag" "$(_pl_note)"
  fi
}

# =============================================================================
# 템플릿 로드 가드 — 1) bash -n 2) 서브셸 시험 source + 필수 함수 확인 3) 진짜 source. 실패하면 plain_* 대체
# =============================================================================
_TG_FMT_FILE="$(dirname "${BASH_SOURCE[0]}")/telegram-format.sh"
_TG_FMT_FUNCS=(html_escape html_to_plain fmt_brief fmt_outage_detected fmt_flap fmt_outage_ongoing fmt_outage_expanded
               fmt_recovered fmt_selffail fmt_test fmt_sample)
TG_TEMPLATE_ERR=""
_tg_load_err=""
if [ ! -f "$_TG_FMT_FILE" ]; then
  TG_TEMPLATE_ERR="파일 없음"
elif ! _tg_load_err="$(bash -n "$_TG_FMT_FILE" 2>&1)"; then
  TG_TEMPLATE_ERR="문법 오류(bash -n): ${_tg_load_err:0:300}"
elif ! _tg_load_err="$( (source "$_TG_FMT_FILE" >/dev/null && declare -F "${_TG_FMT_FUNCS[@]}" >/dev/null && echo __TG_LOADED__) 2>&1 )"      || [ "${_tg_load_err##*__TG_LOADED__}" != "" ] || [ "${_tg_load_err%__TG_LOADED__}" = "$_tg_load_err" ]; then
  # 마커(__TG_LOADED__)가 마지막에 찍히지 않으면 top-level exit 등으로 시험 source 가 중간에 끝난 것(L1)
  TG_TEMPLATE_ERR="source 실패·필수 함수 누락·조기 종료: ${_tg_load_err:0:300}"
else
  # shellcheck source=telegram-format.sh
  source "$_TG_FMT_FILE" || TG_TEMPLATE_ERR="source 실패"
fi
unset _tg_load_err
TG_TEMPLATE_ERR="${TG_TEMPLATE_ERR//"$_TG_FMT_FILE"/telegram-format.sh}"   # 러너 절대경로는 알림·로그에서 뺀다
if [ -n "$TG_TEMPLATE_ERR" ]; then
  echo "::error::telegram-format.sh 사용 불가 (${TG_TEMPLATE_ERR}) — 모든 텔레그램을 기본(plain) 형식으로 보냄"
  note_fail "telegram-format.sh 사용 불가 → 기본(plain) 형식으로 전송: ${TG_TEMPLATE_ERR}"
  TG_FORCE_PLAIN=1; TG_DEGRADED=1
  html_escape()         { printf '%s' "${1-}"; }
  h()                   { printf '%s' "${1-}"; }
  html_to_plain()       { printf '%s' "${1-}"; }   # plain 본문이라 항등
  fmt_brief()           { plain_brief "$@"; }
  fmt_outage_detected() { plain_outage_detected "$@"; }
  fmt_flap()            { plain_flap "$@"; }
  fmt_outage_ongoing()  { plain_outage_ongoing "$@"; }
  fmt_outage_expanded() { plain_outage_expanded "$@"; }
  fmt_recovered()       { plain_recovered "$@"; }
  fmt_selffail()        { plain_selffail "$@"; }
  fmt_test()            { plain_test "$@"; }
  fmt_sample()          { plain_sample "$@"; }
fi

# =============================================================================
# 렌더 가드 — fmt_* 를 돌려 TG_MSG·TG_MSG_PM 에 담는다. 비0 종료·빈 출력이면 plain_* 로 대체(항상 0 반환)
# 사용: tg_render fmt_brief json=… ; echo "$TG_MSG" ; tg_send "$TG_MSG" "$TG_MSG_PM"
# =============================================================================
tg_render() {
  local fn="$1" rc=0 pfn ef rerr=""
  shift
  # N1 가드: 템플릿 안쪽 $(...) 의 변수 오타는 내부 서브셸만 죽고 바깥은 rc 0 + 내용 빠진 출력으로 끝난다.
  # 정상 렌더는 stderr 에 아무것도 쓰지 않으므로, stderr 가 비어있지 않으면 rc 와 무관하게 렌더 실패로 본다.
  ef="$(mktemp "${RUNNER_TEMP:-/tmp}/tg_render.XXXXXX")"
  TG_MSG="$("$fn" "$@" 2>"$ef")" || rc=$?
  rerr="$(head -c 600 "$ef" 2>/dev/null)"; rm -f "$ef"
  TG_MSG_PM=""; [ "$TG_FORCE_PLAIN" != "1" ] || TG_MSG_PM=plain
  if [ "$rc" = "0" ] && [ -z "$rerr" ] && [ -n "${TG_MSG//[[:space:]]/}" ]; then return 0; fi
  [ -z "$rerr" ] || printf '%s
' "$rerr" >&2
  echo "::error::텔레그램 템플릿 렌더 실패: ${fn} (rc=${rc}, 출력 ${#TG_MSG}자, stderr ${#rerr}자) — 기본(plain) 형식으로 대체 전송. telegram-format.sh 확인"
  note_fail "텔레그램 템플릿 렌더 실패: ${fn} (rc=${rc}, 출력 ${#TG_MSG}자, stderr: ${rerr:0:200}) → 기본 형식으로 대체 전송. telegram-format.sh 확인"
  TG_DEGRADED=1
  pfn="plain_${fn#fmt_}"; TG_MSG=""
  if declare -F "$pfn" >/dev/null; then TG_MSG="$("$pfn" "$@")" || TG_MSG=""; fi
  [ -n "${TG_MSG//[[:space:]]/}" ] || TG_MSG="🟡 simparty 감시: 텔레그램 템플릿 렌더 실패 (${fn}) — 실행 로그 확인${RUN_URL:+
${RUN_URL}}"
  TG_MSG_PM=plain
  return 0
}
# 렌더 + 전송. 반환 = tg_send 결과
tg_fmt_send() { tg_render "$@"; tg_send "$TG_MSG" "$TG_MSG_PM"; }

# 텔레그램 POST 1회. $1 text, $2 parse_mode(빈 값 = plain), $3 응답 파일, $4 stderr 파일 → HTTP 코드 출력.
# 테스트는 이 함수만 바꿔 끼워 네트워크 없이 tg_send 의 재전송 로직을 검증한다(tests/telegram-format.test.sh).
_tg_post() {
  local text="$1" pm="$2" resp="$3" err="$4"
  local -a pmopt=()
  if [ -n "$pm" ]; then pmopt=(--data-urlencode "parse_mode=${pm}"); fi
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" \
    | curl -sS -K - -X POST --max-time 20 -o "$resp" -w '%{http_code}' \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        "${pmopt[@]}" \
        --data-urlencode 'link_preview_options={"is_disabled":true}' 2>"$err" || echo "000"
}

# 텔레그램 전송. $1 본문, $2 "plain" 이면 parse_mode 없이(기본 = HTML — 본문은 telegram-format.sh 가 만든다).
# 실패해도 호출부를 죽이지 않도록 반환값만 준다 (호출부: tg_send "..." || true).
# 빈 본문은 보내지 않고 실패(템플릿 버그 — 텔레그램은 400 "message text is empty" 로 버린다).
# HTML 파싱 실패(400 "can't parse entities" — 템플릿 태그 짝 오류·미이스케이프 값)면 태그를 벗긴 plain 으로 1회 재전송.
# 실패 시 TG_FAILED=1 → 스크립트 마지막에 job 을 실패로 표시해 GitHub 실패 메일이라도 가게 한다.
tg_send() {
  local text="${1-}" resp err http ok desc migrate pm="HTML"
  if [ "${2-}" = "plain" ] || [ "$TG_FORCE_PLAIN" = "1" ]; then pm=""; fi
  if [ -z "${text//[[:space:]]/}" ]; then
    echo "::error::텔레그램 본문이 비어 있음 — 전송하지 않음 (템플릿 렌더 결과 확인)"
    note_fail "텔레그램 본문이 비어 전송 안 함 — 템플릿 렌더 결과 확인"
    TG_FAILED=1; return 1
  fi
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "::warning::TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID 비어 있음 — 텔레그램 전송 생략"
    TG_FAILED=1; return 1
  fi
  # sendMessage 한도 4096자(엔티티 파싱 후). HTML 을 중간에서 자르면 태그가 깨지므로 넘치면 plain 으로 바꿔 자른다
  if [ "${#text}" -gt 4000 ]; then
    if [ -n "$pm" ]; then text="$(html_to_plain "$text")"; fi
    text="${text:0:4000}"; pm=""
  fi
  resp="$(mktemp)"; err="$(mktemp)"
  http="$(_tg_post "$text" "$pm" "$resp" "$err")"; http="${http:0:3}"
  ok="$(jq -r '.ok // false' "$resp" 2>/dev/null || echo false)"
  desc="$(jq -r '.description // empty' "$resp" 2>/dev/null || true)"
  if [ "$ok" != "true" ] && [ "$http" = "400" ] && [ -n "$pm" ] && [[ "$desc" == *"can't parse entities"* ]]; then
    echo "::warning::텔레그램 HTML 파싱 실패 (${desc}) — 태그를 벗긴 plain 으로 재전송. telegram-format.sh 확인 필요"
    note_fail "텔레그램 HTML 파싱 실패 → plain 재전송: ${desc}"
    text="$(html_to_plain "$text")"; pm=""
    http="$(_tg_post "${text:0:4000}" "" "$resp" "$err")"; http="${http:0:3}"
    ok="$(jq -r '.ok // false' "$resp" 2>/dev/null || echo false)"
    desc="$(jq -r '.description // empty' "$resp" 2>/dev/null || true)"
  fi
  if [ "$ok" = "true" ]; then
    rm -f "$resp" "$err"; return 0
  fi
  migrate="$(jq -r '.parameters.migrate_to_chat_id // empty' "$resp" 2>/dev/null || true)"
  echo "::warning::텔레그램 전송 실패 (HTTP ${http}) ${desc}"
  if [ -s "$err" ]; then
    # curl 오류 메시지에 URL 이 섞일 가능성 대비해 토큰 치환 후 출력.
    # 치환은 bash 내장으로 — sed 인자로 넘기면 토큰이 프로세스 argv(ps)에 잠깐 노출된다.
    local line n=0
    while IFS= read -r line && [ "$n" -lt 3 ]; do
      printf '%s\n' "${line//"$TELEGRAM_BOT_TOKEN"/***}"; n=$((n + 1))
    done < "$err"
  fi
  if [ -n "$migrate" ]; then
    echo "::warning::그룹이 슈퍼그룹으로 전환됨 — TELEGRAM_CHAT_ID 시크릿을 ${migrate} 로 교체 필요"
    note_fail "TELEGRAM_CHAT_ID 교체 필요 (migrate_to_chat_id=${migrate})"
  fi
  note_fail "텔레그램 전송 실패 HTTP ${http} ${desc}"
  TG_FAILED=1
  rm -f "$resp" "$err"
  return 1
}
