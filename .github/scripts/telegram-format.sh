# shellcheck shell=bash
# =============================================================================
# 텔레그램 메시지 템플릿 — 감시가 보내는 모든 텔레그램 본문은 이 파일의 함수가 만든다.
# 호출부(uptime.sh · neon-usage.sh · 워크플로 실패 스텝)는 값만 넘긴다. 문구·순서·줄바꿈을 바꾸려면 이 파일만 고친다.
# =============================================================================
#
# ■ 조정 가이드
#
#   함수                  메시지                                                  부르는 곳
#   ------------------    ------------------------------------------------------  ---------------------------
#   fmt_brief             Neon 일일 브리프 (✅ / ⚠️ / 🔴)                          neon-usage.sh §5
#   fmt_outage_detected   🔴 장애 감지 — kind=new(신규) | reopen(재발) |            uptime.sh
#                            selffail(GitHub 이슈 기록 실패 → 직접 알림)
#   fmt_flap              🟠 장애·복구 반복 (12시간 안 재발 2회째)                   uptime.sh
#   fmt_outage_ongoing    🔴 장애 지속 — kind=remind(6h 재알림) | retry(전송 실패분   uptime.sh
#                            재시도) | flap_remind(반복 중 재알림)
#   fmt_outage_expanded   🔴 장애 확대 (아직 알리지 않은 체크가 새로 실패)            uptime.sh
#   fmt_recovered         🟢 복구                                                   uptime.sh
#   fmt_selffail          ⚠️ 감시 자체 실패                                          uptime.yml · neon-usage.yml
#   fmt_test              🧪 test-alert 머리 메시지                                   uptime.sh test-alert
#   fmt_sample            test-alert 샘플 4종(detected·recovered·selffail·flap)       uptime.sh test-alert
#
#   - 각 함수는 key=value 인자만 받는다(순서 무관, 빠진 키 = 빈 값). 예:
#       fmt_outage_detected kind=new results=/tmp/r.tsv now=1760000000 mode=quick issue=https://… run=https://…
#   - results = uptime.sh 의 체크 결과 TSV (name \t ok(1/0) \t http \t 초 \t detail)
#   - 시각 인자(now·since·pass_at)는 epoch 또는 ISO-8601 둘 다 받는다. 출력은 전부 KST.
#
# ■ 서식 규칙 (parse_mode=HTML)
#
#   - 허용 태그는 <b> <i> <code> <pre> <a href> 만. 동적 값(체크 이름·HTTP 코드·오류 문구·이슈 제목·URL)은
#     반드시 h(=html_escape, & < > 치환)를 거쳐 넣는다. href 값은 _ha(따옴표까지 치환).
#     태그 짝이 틀리면 텔레그램이 400 "can't parse entities" → tg_send 가 태그를 벗긴 plain 으로 1회 재전송한다(내용은 감).
#   - 첫 줄 = [태그] 이모지 + <b>한 문장 판정</b>. 둘째 줄 = 언제·무엇(평문). 섹션 사이 빈 줄 1개.
#   - 섹션 제목은 <b>제목</b>, 항목은 "· " 로 시작. 숫자는 <code>…</code>.
#   - 표는 <pre>…</pre> 고정폭 — 한글은 2칸이라 정렬이 깨지므로 표 안에는 ASCII 만 쓴다.
#   - 시각: 같은 날 "HH:MM", 어제 "어제 HH:MM", 그 외 "MM-DD HH:MM" (fmt_when) / 상대 "N분 전·N시간 전·N일 전" (fmt_ago).
#   - 한 줄 바꾸려면 해당 L+=( … ) 줄만 고친다. 줄을 빼려면 그 줄을 지우면 된다(빈 줄 L+=("") 짝 주의).
#
# ■ 미리 보기
#   로컬:  bash .github/scripts/tests/telegram-format.test.sh        # 렌더 전문 + html_escape 단위 테스트
#   커밋 전: bash .github/scripts/tests/ci-check.sh                  # CI(.github/workflows/ci.yml)와 같은 검사 — bash -n·YAML·테스트
#   이 파일이 깨져도(문법 오류·변수 오타) 알림은 monitor-lib.sh 가 옛 plain 형식으로 대체해 보내고 job 을 실패로 표시한다.
#   실전송: gh workflow run neon-usage.yml -f mode=preview  (실데이터 브리프, "[미리보기]" · 상태 저장 안 함)
#           gh workflow run uptime.yml -f mode=test-alert   (샘플 4종, "[샘플]" · 이슈·상태 안 건드림)
#
# 순수 함수만 둔다 — 네트워크·GitHub·파일 쓰기 없음(fmt_sample 의 임시 fixture 파일 제외).

# ---- 이스케이프 --------------------------------------------------------------
# bash 5.2+ 는 patsub_replacement 가 기본 on 이라 치환 문자열의 & 가 "매치된 문자열"로 바뀐다 → 치환 문자열은 반드시 따옴표.
html_escape() {
  local s="${1-}"
  s="${s//'&'/'&amp;'}"; s="${s//'<'/'&lt;'}"; s="${s//'>'/'&gt;'}"
  printf '%s' "$s"
}
h() { html_escape "$@"; }
# href 속성값용 — 따옴표까지
_ha() { local s; s="$(html_escape "${1-}")"; s="${s//'"'/'&quot;'}"; printf '%s' "$s"; }

# HTML → plain (parse 실패 재전송·step summary 용). <a href="U">T</a> → "T (U)", 허용 태그 제거, 엔티티 복원(&amp; 는 마지막).
html_to_plain() {
  printf '%s' "${1-}" | sed -E \
    -e 's#<a href="([^"]*)">([^<]*)</a>#\2 (\1)#g' \
    -e 's#</?(b|i|code|pre|a)( [^>]*)?>##g' \
    -e 's/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g' -e "s/&#39;/'/g" -e 's/&amp;/\&/g'
}

# ---- 인자 · 시각 도우미 -------------------------------------------------------
# key=value 인자를 호출 함수의 연관 배열에 푼다: local -A a=(); _fmt_args a "$@"
_fmt_args() {
  local -n _fa_map="$1"; shift
  local kv
  for kv in "$@"; do
    case "$kv" in *=*) _fa_map["${kv%%=*}"]="${kv#*=}" ;; esac
  done
}
_fmt_now() { printf '%s' "${FMT_NOW_EPOCH:-$(date -u +%s)}"; }
# epoch | ISO → epoch (빈 값·실패는 빈 출력)
_epoch() {
  case "${1-}" in
    ''|null) return 0 ;;
    *[!0-9]*) date -u -d "$1" +%s 2>/dev/null || true ;;
    *) printf '%s' "$1" ;;
  esac
}
_kst() { date -u -d "@$(( $1 + 32400 ))" "+$2"; }
_kst_wd() { local d; d="$(_kst "$1" %u)"; case "$d" in 1) printf 월 ;; 2) printf 화 ;; 3) printf 수 ;; 4) printf 목 ;; 5) printf 금 ;; 6) printf 토 ;; *) printf 일 ;; esac; }
# epoch [now] → "09:10" | "어제 23:04" | "10-11 23:04" (KST)
fmt_when() {
  local e="$1" n="${2:-$(_fmt_now)}"
  if [ "$(_kst "$e" %Y%m%d)" = "$(_kst "$n" %Y%m%d)" ]; then _kst "$e" %H:%M
  elif [ "$(_kst "$e" %Y%m%d)" = "$(_kst $((n - 86400)) %Y%m%d)" ]; then printf '어제 %s' "$(_kst "$e" %H:%M)"
  else _kst "$e" '%m-%d %H:%M'; fi
}
# 경과 초 → "방금" | "7분 전" | "10시간 전" | "3일 전"
fmt_ago() {
  local s="${1:-0}"
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if [ "$s" -lt 60 ]; then printf '방금'
  elif [ "$s" -lt 3600 ]; then printf '%d분 전' $((s / 60))
  elif [ "$s" -lt 172800 ]; then printf '%d시간 전' $((s / 3600))
  else printf '%d일 전' $((s / 86400)); fi
}
# 분 → "35분" | "1시간 20분" | "2일 3시간"
fmt_dur() {
  local m="${1:-0}"
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  if [ "$m" -lt 60 ]; then printf '%d분' "$m"
  elif [ "$m" -lt 1440 ]; then
    if [ $((m % 60)) -eq 0 ]; then printf '%d시간' $((m / 60)); else printf '%d시간 %d분' $((m / 60)) $((m % 60)); fi
  else printf '%d일 %d시간' $((m / 1440)) $(((m % 1440) / 60)); fi
}
# 다음 full(DB 경유) 슬롯 epoch — KST 11:04~23:04 매시 04분 (uptime.yml full cron '4 2-14 * * *' 과 같은 뜻)
_fmt_next_full() {
  local k=$(( $1 + 32400 )) day hr t
  day=$(( k / 86400 * 86400 ))
  for hr in 11 12 13 14 15 16 17 18 19 20 21 22 23; do
    t=$(( day + hr * 3600 + 240 ))
    if [ "$t" -gt "$k" ]; then printf '%s' $(( t - 32400 )); return; fi
  done
  printf '%s' $(( day + 86400 + 11 * 3600 + 240 - 32400 ))
}
_csv_has() { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }
# "a,b" → "<code>a</code>, <code>b</code>"
_fmt_codes() {
  local IFS=, x out=()
  for x in $1; do [ -n "$x" ] && out+=("<code>$(h "$x")</code>"); done
  local j; j="$(printf '%s, ' "${out[@]}")"; printf '%s' "${j%, }"
}
_fmt_join() { local sep="$1"; shift; local j=""; local x; for x in "$@"; do [ -n "$x" ] || continue; j="${j:+$j$sep}$x"; done; printf '%s' "$j"; }

# ---- 업타임 체크: 이름별 설명 ---------------------------------------------------
# 영향 — "어떤 화면이 안 열리나". 체크를 추가하면 여기와 _fmt_verdict 에 한 줄씩.
# 체크 식별자 → 한글 라벨 (문장 줄에서 사용. <pre> 표는 폭 유지를 위해 영문 식별자 그대로 + 아래 범례)
_fmt_label() {
  case "$1" in
    liveness)   printf 'BE 생존(liveness)' ;;
    robots)     printf 'FE 응답(robots)' ;;
    readiness)  printf 'DB 준비(readiness)' ;;
    categories) printf '의상 API(categories)' ;;
    home)       printf '홈 화면(home)' ;;
    *)          printf '%s' "$1" ;;
  esac
}
_FMT_LEGEND='liveness=BE 생존 · robots=FE 응답 · readiness=DB 준비 · categories=의상 API · home=홈 화면'
_fmt_impact() {
  case "$1" in
    liveness)   printf 'BE(API 서버) 전체 — 의상 목록·상세·예약, 관리자 화면 전부 데이터가 안 나옴' ;;
    robots)     printf 'FE(웹 서버) 전체 — simparty.shop 접속 자체가 안 됨' ;;
    readiness)  printf 'DB 연결 — BE 는 살아 있지만 의상·예약 데이터 조회 실패' ;;
    categories) printf '고객 의상 API(DB 경유) — 홈 카테고리 칩·의상 목록이 비어 보임' ;;
    home)       printf 'SSR 홈 — simparty.shop 첫 화면 렌더 실패' ;;
    *)          printf '%s 체크 실패' "$(h "$1")" ;;
  esac
}
# 실패 집합 → 한 문장 판정 (첫 줄 굵게 부분). **평문**을 돌려준다 — 부르는 쪽이 h 로 한 번만 이스케이프(이중 이스케이프 방지)
_fmt_verdict() {
  local f="$1"
  if _csv_has "$f" liveness && _csv_has "$f" robots; then printf '사이트 전체 접속 불가 (BE·FE 모두 무응답)'
  elif _csv_has "$f" liveness; then printf 'BE(API) 응답 없음'
  elif _csv_has "$f" robots; then printf 'FE(웹) 응답 없음'
  elif _csv_has "$f" readiness || _csv_has "$f" categories; then printf 'DB 경유 조회 실패'
  elif _csv_has "$f" home; then printf '홈 화면(SSR) 렌더 실패'
  elif [ -n "$f" ]; then printf '체크 실패: %s' "$f"
  else printf '실패 체크 없음'; fi
}
_FMT_DB_CHECKS="readiness,categories,home"

# 결과 TSV → <pre> 표 + 실패 상세 줄. $1 results
#   표는 원문으로 칸을 맞춘 뒤 통째로 h — 텔레그램은 &lt; 를 한 글자(<)로 보여 주므로 원문 기준 패딩이 화면 정렬과 같다
#   (이스케이프 후 패딩하면 &lt; 가 4칸으로 세여 오히려 어긋난다 — 테스트 'pre 표 정렬')
_fmt_results() {
  local file="$1" name ok code t detail rows dets=()
  [ -s "$file" ] || { printf '<i>(이번 실행 체크 결과 없음)</i>'; return; }
  rows="$(printf '%-11s %-4s %4s %7s' check stat http time)"
  while IFS=$'\t' read -r name ok code t detail; do
    [ -n "$name" ] || continue
    case "$t" in ''|*[!0-9.]*) t=0 ;; esac
    rows+=$'\n'"$(printf '%-11s %-4s %4s %6.2fs' "$name" "$([ "$ok" = 1 ] && echo OK || echo FAIL)" "$code" "$t")"
    if [ "$ok" != "1" ]; then
      detail="${detail%"${detail##*[![:space:]]}"}"   # 끝 공백 제거
      case "$detail" in
        "HTTP $code") detail="HTTP $code 응답" ;;
        "") detail="실패" ;;
      esac
      [ "$code" = "000" ] && [ "${detail#네트워크}" = "$detail" ] && detail="무응답 · $detail"
      dets+=("· <code>$(h "$name")</code> — <i>$(h "${detail:0:140}")</i>")
    fi
  done < "$file"
  printf '<pre>%s</pre>' "$(h "$rows")"
  [ "${#dets[@]}" -eq 0 ] || printf '\n%s' "${dets[@]}"
}
_fmt_failed_of() { awk -F'\t' '$2=="0"{print $1}' "$1" 2>/dev/null | paste -sd, - 2>/dev/null || true; }
# 링크 줄. $1 issue url, $2 run url, $3 이슈 링크 문구(옵션)
_fmt_links() {
  local issue="$1" run="$2" itext="${3-}" a=() b=()
  if [[ "$issue" == https://* ]]; then
    [ -n "$itext" ] || itext="장애 이슈 #${issue##*/}"
    a+=("<a href=\"$(_ha "$issue")\">$(h "$itext")</a>")
  fi
  [[ "$run" == https://* ]] && b+=("<a href=\"$(_ha "$run")\">실행 로그</a>")
  _fmt_join ' · ' "${a[@]}" "${b[@]}"
}
_fmt_print() { local IFS=$'\n'; printf '%s' "${L[*]}"; }
# 0.123 → "12%"
_fmt_pct() { jq -rn --arg x "$1" '($x | tonumber * 100 | round | tostring) + "%"' 2>/dev/null || printf '%s' "$1"; }

# =============================================================================
# 업타임 알림 (🔴 · 🟠) — 공통 골격: ① 판정 ② 체크 결과 표 ③ 영향 ④ 다음 동작 ⑤ 링크
# =============================================================================
# 인자: kind results now mode issue run since failed(이월 포함 실패 집합, 생략 = results 의 실패)
#       new_fails remind_h reopen_min flap_hold flap_hold_min reopens tag issue_text
_fmt_outage() {
  local -A a=(); _fmt_args a "$@"
  local kind="${a[kind]-new}" res="${a[results]-}" mode="${a[mode]-}" tag="${a[tag]-}"
  local now since remind_h="${a[remind_h]:-6}" reopen_h=$(( ${a[reopen_min]:-360} / 60 )) hold_min="${a[flap_hold_min]:-120}"
  now="$(_epoch "${a[now]-}")"; now="${now:-$(_fmt_now)}"
  since="$(_epoch "${a[since]-}")"; since="${since:-$now}"
  local ran_failed failed down_min verdict emoji title sub
  ran_failed="$(_fmt_failed_of "$res")"
  failed="${a[failed]:-$ran_failed}"
  down_min=$(( (now - since) / 60 )); [ "$down_min" -ge 0 ] || down_min=0
  verdict="$(_fmt_verdict "$failed")"
  local when; when="$(fmt_when "$now" "$now")"

  # ① 판정 — kind 별 첫 줄·둘째 줄
  case "$kind" in
    new)         emoji="🔴"; title="simparty 장애 감지 — $verdict"
                 sub="$when KST 감지 · ${mode:-?} 체크 · 10초 뒤 재시도 후에도 실패" ;;
    reopen)      emoji="🔴"; title="simparty 장애 재발 — $verdict"
                 sub="$when KST 감지 · 복구 후 ${reopen_h}시간 안 재발이라 같은 이슈를 다시 열었습니다" ;;
    selffail)    emoji="🔴"; title="simparty 장애 감지 — $verdict"
                 sub="$when KST 감지 · ⚠️ GitHub 이슈 기록 실패 — 상태 추적 없이 직접 보내는 알림" ;;
    flap)        emoji="🟠"; title="simparty 장애·복구 반복 — 12시간 안 재발 2회째"
                 sub="$when KST · 지금 상태: $verdict" ;;
    remind)      emoji="🔴"; title="simparty 장애 지속 — 다운 약 $(fmt_dur "$down_min")"
                 sub="$verdict · $(fmt_when "$since" "$now") 부터 · ${remind_h}시간 재알림" ;;
    retry)       emoji="🔴"; title="simparty 장애 지속 — 다운 약 $(fmt_dur "$down_min")"
                 sub="$verdict · $(fmt_when "$since" "$now") 부터 · 직전 알림이 전송 실패해 다시 보냄" ;;
    flap_remind) emoji="🔴"; title="simparty 장애 반복 중 — 다운 약 $(fmt_dur "$down_min")"
                 sub="$verdict · ${remind_h}시간 재알림 (재발·복구 알림은 억제 중)" ;;
    expanded)    emoji="🔴"; title="simparty 장애 확대 — 새로 실패: ${a[new_fails]-?}"
                 sub="$verdict · 다운 약 $(fmt_dur "$down_min") ($(fmt_when "$since" "$now") 부터)" ;;
    *)           emoji="🔴"; title="simparty 장애 — $verdict"; sub="$when KST" ;;
  esac
  local -a L; L=("${tag}${emoji} <b>$(h "$title")</b>" "$(h "$sub")")

  # ② 체크 결과
  L+=("" "<b>체크 결과</b> (${mode:-?} · $when KST)" "$(_fmt_results "$res")" "<i>$(h "$_FMT_LEGEND")</i>")
  local carried; carried="$(jq -rn --arg a "$failed" --arg b "$ran_failed" '($a|split(",")|map(select(.!=""))) - ($b|split(",")) | join(",")' 2>/dev/null || true)"
  if [ -n "$carried" ]; then
    L+=("· 이번 실행에서 다시 보지 못한 실패: $(_fmt_codes "$carried") — DB 경유라 full 실행에서만 재확인")
  fi

  # ③ 영향
  L+=("" "<b>영향</b>")
  local IFS_OLD="$IFS" c dep
  IFS=,
  for c in $failed; do
    [ -n "$c" ] || continue
    dep=""
    if _csv_has "$failed" liveness && _csv_has "$_FMT_DB_CHECKS" "$c"; then dep=" (BE 다운의 결과)"; fi
    L+=("· <b>$(h "$(_fmt_label "$c")")</b> — $(_fmt_impact "$c")$dep")
  done
  IFS="$IFS_OLD"

  # ④ 다음 동작
  L+=("" "<b>다음 동작</b>")
  local remind_at; remind_at=$(( now + remind_h * 3600 ))
  case "$kind" in
    selffail)
      L+=("· 이슈 기록이 안 되는 동안 같은 알림을 1→3→6시간 간격으로 반복합니다")
      L+=("· GitHub API 가 회복되면 평소 흐름(장애 이슈·재알림·🟢 복구)으로 돌아갑니다") ;;
    flap)
      L+=("· 이후 재발·복구 텔레그램은 억제 — 장애가 이어지면 <b>$(fmt_when "$remind_at" "$now")</b> KST(${remind_h}시간 뒤)부터 ${remind_h}시간마다만 재알림")
      L+=("· close 조건 강화: 전부 통과가 <b>${hold_min}분</b> 이어져야 🟢 + 이슈 close") ;;
    *)
      L+=("· 장애가 이어지면 <b>$(fmt_when "$remind_at" "$now")</b> KST(${remind_h}시간 뒤) 재알림")
      [ "$kind" = "flap_remind" ] || L+=("· 아직 알리지 않은 체크가 새로 실패하면 '확대' 1건 (직전 알림 1시간 뒤부터)")
      if [ "$kind" = "flap_remind" ] || [ "${a[flap_hold]-}" = "1" ]; then
        L+=("· 반복 장애라 전부 통과가 <b>${hold_min}분</b> 이어져야 🟢 + 이슈 close")
      else
        L+=("· 실패 체크가 연속 2회(약 10분 간격) 전부 통과하면 🟢 복구 알림 + 이슈 자동 close")
      fi
      [ "$kind" = "reopen" ] && L+=("· 12시간 안에 또 재발하면 🟠 1건 뒤 재발·복구 알림은 억제") ;;
  esac
  local dbf=""
  for c in readiness categories home; do _csv_has "$failed" "$c" && dbf="${dbf:+$dbf,}$c"; done
  if [ -n "$dbf" ] && [ "$kind" != "selffail" ]; then
    L+=("· $(_fmt_codes "$dbf") 는 DB 경유라 full 실행(다음 <b>$(fmt_when "$(_fmt_next_full "$now")" "$now")</b> KST)에서만 다시 확인 → 그 재통과로 복구 확정")
  fi

  # ⑤ 링크
  local links; links="$(_fmt_links "${a[issue]-}" "${a[run]-}" "${a[issue_text]-}")"
  [ -z "$links" ] || L+=("" "$links")
  _fmt_print
}

fmt_outage_detected() { _fmt_outage kind=new "$@"; }        # kind=new|reopen|selffail 로 덮어씀
fmt_flap()            { _fmt_outage "$@" kind=flap; }
fmt_outage_ongoing()  { _fmt_outage kind=remind "$@"; }     # kind=remind|retry|flap_remind
fmt_outage_expanded() { _fmt_outage "$@" kind=expanded; }

# =============================================================================
# 🟢 복구 — ① 판정 ② 장애 요약 ③ 지금 체크 결과 ④ 링크
# =============================================================================
# 인자: results now mode issue run since(장애 시작) pass_at(1차 전부 통과) seen(이번 장애에서 실패했던 체크 누적)
#       reopens(최근 12시간 재발 횟수) flap_hold(1=반복 장애 강화 close) flap_hold_min reopen_min tag issue_text
fmt_recovered() {
  local -A a=(); _fmt_args a "$@"
  local now since pass_at seen="${a[seen]-}" tag="${a[tag]-}" down_min
  now="$(_epoch "${a[now]-}")"; now="${now:-$(_fmt_now)}"
  since="$(_epoch "${a[since]-}")"; since="${since:-$now}"
  pass_at="$(_epoch "${a[pass_at]-}")"; pass_at="${pass_at:-$now}"
  down_min=$(( (pass_at - since) / 60 )); [ "$down_min" -ge 0 ] || down_min=0

  local hold_min="${a[flap_hold_min]:-120}" reopen_h=$(( ${a[reopen_min]:-360} / 60 )) how="연속 2회 전부 통과"
  # 반복 장애(flap-hold)는 close 조건이 '전부 통과가 hold_min 분 지속' 이다 (uptime.sh FLAP_HOLD_MIN)
  [ "${a[flap_hold]-}" != "1" ] || how="전부 통과가 ${hold_min}분 이어짐 (반복 장애 강화 조건)"
  local -a L; L=("${tag}🟢 <b>simparty 복구 — 다운 약 $(fmt_dur "$down_min")</b>"
     "$(fmt_when "$now" "$now") KST 확인 · $how")
  L+=("" "<b>장애 요약</b>")
  L+=("· 시작 <code>$(fmt_when "$since" "$now")</code> → 첫 통과 <code>$(fmt_when "$pass_at" "$now")</code> → 복구 확정 <code>$(fmt_when "$now" "$now")</code> KST")
  if [ -n "$seen" ]; then
    L+=("· 실패했던 체크: $(_fmt_codes "$seen")")
    L+=("· 그동안 영향: $(h "$(_fmt_verdict "$seen")")")
  fi
  local n="${a[reopens]:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -eq 0 ] || L+=("· 최근 12시간 재발 <code>$n</code>회 — 또 반복되면 재발·복구 알림은 억제됩니다")
  L+=("· 장애 이슈는 지금 자동 close — ${reopen_h}시간 안에 재발하면 같은 이슈를 다시 엽니다")
  L+=("" "<b>지금 체크 결과</b> (${a[mode]:-?})" "$(_fmt_results "${a[results]-}")")
  local links; links="$(_fmt_links "${a[issue]-}" "${a[run]-}" "${a[issue_text]-}")"
  [ -z "$links" ] || L+=("" "$links")
  _fmt_print
}

# =============================================================================
# ⚠️ 감시 자체 실패 — 사이트가 아니라 감시가 끝까지 못 돈 경우
# =============================================================================
# 인자: workflow(uptime|neon-usage) mode reason(여러 줄) run suppress_h(기본 6) now tag
fmt_selffail() {
  local -A a=(); _fmt_args a "$@"
  local wf="${a[workflow]:-?}" mode="${a[mode]-}" reason="${a[reason]-}" sh="${a[suppress_h]:-6}" now next hint
  now="$(_epoch "${a[now]-}")"; now="${now:-$(_fmt_now)}"
  local -a L; L=("${a[tag]-}⚠️ <b>감시 자체 실패 — $(h "$wf")${mode:+ ($(h "$mode"))}</b>"
     "$(fmt_when "$now" "$now") KST · 사이트 상태가 아니라 감시 스크립트 쪽 문제입니다")
  L+=("" "<b>사유</b>")
  if [ -n "$reason" ]; then L+=("<pre>$(h "${reason:0:900}")</pre>"); else L+=("<i>(사유 기록 없음 — 실행 로그 확인)</i>"); fi
  L+=("" "<b>영향</b>")
  if [ "$wf" = "neon-usage" ]; then
    L+=("· 오늘 Neon 브리프(사용량·autosuspend 판정)가 빠졌습니다")
    next="내일 09:17 KST 정기 실행"
    hint="NEON_API_KEY 만료·권한 · 텔레그램 시크릿 · Neon API 장애"
  else
    L+=("· 이번 실행은 장애를 판정하지 못했습니다 — 그 사이 사이트가 내려갔어도 알림이 없었을 수 있음")
    next="다음 정기 실행(10분 주기)"
    hint="권한(issues: write) · 텔레그램 시크릿 · GitHub API 장애"
  fi
  L+=("" "<b>다음 동작</b>")
  L+=("· 같은 알림은 <b>${sh}시간</b> 억제 (GitHub 실패 메일은 매번 발송)")
  L+=("· ${next}이 성공하면 자동 정상화 — 별도 🟢 알림은 없습니다")
  L+=("· 반복되면 실행 로그 확인: $hint")
  local links; links="$(_fmt_links "" "${a[run]-}")"
  [ -z "$links" ] || L+=("" "$links")
  _fmt_print
}

# =============================================================================
# 🧪 test-alert 머리 + 샘플 4종 (fixture — 실제 체크·이슈와 무관)
# =============================================================================
fmt_test() {
  local -A a=(); _fmt_args a "$@"
  local now; now="$(_epoch "${a[now]-}")"; now="${now:-$(_fmt_now)}"
  local -a L; L=("🧪 <b>[샘플] 텔레그램 알림 미리보기 — 실제 장애 아님</b>"
     "$(fmt_when "$now" "$now") KST · 연동 확인 겸 알림 서식 샘플")
  L+=("" "이어서 샘플 4건이 옵니다: 🔴 장애 감지 · 🟢 복구 · ⚠️ 감시 자체 실패 · 🟠 장애·복구 반복")
  L+=("문구·줄바꿈 조정은 <code>.github/scripts/telegram-format.sh</code> 한 파일에서 합니다.")
  local links; links="$(_fmt_links "" "${a[run]-}")"
  [ -z "$links" ] || L+=("" "$links")
  _fmt_print
}

# $1 detected|recovered|selffail|flap, 이후 key=value(now run repo). 이슈·상태는 건드리지 않는다.
fmt_sample() {
  local which="$1"; shift
  local -A a=(); _fmt_args a "$@"
  local now run="${a[run]-}" repo="${a[repo]:-thebluepigu/simparty-monitor}" f out
  now="$(_epoch "${a[now]-}")"; now="${now:-$(_fmt_now)}"
  local issue="https://github.com/${repo}/issues"
  f="$(mktemp)"
  case "$which" in
    detected|flap)
      printf '%s\t%s\t%s\t%s\t%s\n' \
        liveness 0 000 20.003 "네트워크 오류: curl: (28) Operation timed out after 20002 milliseconds with 0 bytes received" \
        robots 1 200 0.412 ok > "$f"
      if [ "$which" = detected ]; then
        out="$(fmt_outage_detected tag="[샘플] " kind=new results="$f" now="$now" mode=quick issue="$issue" issue_text="장애 이슈 (샘플 — 실제 이슈 없음)" run="$run")"
      else
        out="$(fmt_flap tag="[샘플] " results="$f" now="$now" mode=quick issue="$issue" issue_text="장애 이슈 (샘플 — 실제 이슈 없음)" run="$run")"
      fi ;;
    recovered)
      printf '%s\t%s\t%s\t%s\t%s\n' \
        liveness 1 200 0.231 ok robots 1 200 0.388 "ok (재시도 후)" > "$f"
      out="$(fmt_recovered tag="[샘플] " results="$f" now="$now" mode=quick since=$((now - 2700)) pass_at=$((now - 600)) \
               seen=liveness,robots issue="$issue" issue_text="장애 이슈 (샘플 — 실제 이슈 없음)" run="$run")" ;;
    selffail)
      out="$(fmt_selffail tag="[샘플] " workflow=uptime mode=quick now="$now" run="$run" \
               reason=$'uptime.sh 비정상 종료 (단계: state, rc=1, failed_now=[])\n라벨 \'uptime-incident\' 생성 실패 → 장애 이슈 미생성 (HTTP 403 <Resource not accessible by integration>)')" ;;
    *) rm -f "$f"; return 1 ;;
  esac
  rm -f "$f"
  printf '%s' "$out"
}

# =============================================================================
# Neon 일일 브리프 — ① 판정 ② 사이트 ③ Neon 사용·비용 ④ autosuspend ⑤ 감시 자체
# =============================================================================
# 인자: json=<neon-usage.sh 가 만든 brief.json 경로> tag(옵션, 예: "[미리보기] ")
# brief.json 의 값·판정 플래그는 neon-usage.sh 가 계산한다(이 함수는 표현만). 기준값을 바꾸려면 neon-usage.sh.
fmt_brief() {
  local -A a=(); _fmt_args a "$@"
  local json="${a[json]-}"
  [ -s "$json" ] || { printf '⚠️ <b>Neon 브리프 렌더 실패 — 입력 없음</b>'; return 0; }
  # 스칼라 값을 B_* 셸 변수로 (@sh 인용 — eval 안전). null → 빈 문자열
  local B_now B_preview B_project B_el B_tot B_note B_cu_apx B_cuh B_cuproj B_quota B_cost B_budget B_over B_tx B_st
  local B_as_bad B_hj B_hnd B_fon B_hrs B_dj B_dratio B_dwhy B_actsrc B_pratio
  local B_site_known B_site_open B_inc_num B_inc_url B_inc_failed B_inc_since
  local B_up_at B_full_at B_up_max B_full_max B_up_bad B_full_bad B_runs B_full24 B_fullx B_dr B_df
  local B_up_unknown B_up_fresh B_site_fresh_h
  local B_idle B_idle_warn B_idle_bad
  eval "$(jq -r '
    def s: if . == null then "" else tostring end;
    def kv($k; $v): "\($k)=\($v | s | @sh)";
    kv("B_now"; .now), kv("B_preview"; .preview), kv("B_project"; .project),
    kv("B_el"; .period.elapsed), kv("B_tot"; .period.total), kv("B_note"; .period.note),
    kv("B_cu_apx"; .cu.approx), kv("B_cuh"; .cu.hours), kv("B_cuproj"; .cu.projected), kv("B_quota"; .cu.quota_pct),
    kv("B_cost"; .cost.projected), kv("B_budget"; .cost.budget), kv("B_over"; .cost.over),
    kv("B_tx"; .transfer_gb), kv("B_st"; .storage_gb),
    kv("B_as_bad"; .as.bad), kv("B_hj"; .as.hour_judged), kv("B_hnd"; .as.hour_nodata),
    kv("B_fon"; .as.full_on), kv("B_hrs"; .as.hours), kv("B_dj"; .as.delta_judged),
    kv("B_dratio"; .as.delta_ratio), kv("B_dwhy"; .as.delta_why), kv("B_actsrc"; .as.act_src), kv("B_pratio"; .as.period_ratio),
    kv("B_site_known"; (.site != null)), kv("B_site_open"; (.site.open // false)),
    kv("B_inc_num"; .site.number), kv("B_inc_url"; .site.url), kv("B_inc_failed"; .site.failed), kv("B_inc_since"; .site.since),
    kv("B_up_at"; .hb.uptime_at), kv("B_full_at"; .hb.full_at), kv("B_up_max"; .hb.uptime_max_h), kv("B_full_max"; .hb.full_max_h),
    kv("B_up_bad"; .hb.uptime_bad), kv("B_full_bad"; .hb.full_bad),
    kv("B_up_unknown"; .hb.uptime_unknown // (.hb.uptime_at == null)), kv("B_up_fresh"; .hb.uptime_fresh // false),
    kv("B_site_fresh_h"; .hb.site_fresh_h // 3),
    kv("B_runs"; .hb.runs24), kv("B_full24"; .hb.full24), kv("B_fullx"; .hb.full_exec24), kv("B_dr"; .hb.design_runs), kv("B_df"; .hb.design_full),
    kv("B_idle"; .repo.idle_days), kv("B_idle_warn"; .repo.warn_days), kv("B_idle_bad"; .repo.bad)
  ' "$json")"
  local now="${B_now:-$(_fmt_now)}" apx="" act_label
  [ "$B_cu_apx" = "true" ] && apx="≈"
  if [ "$B_actsrc" = "branch" ]; then act_label="기본 브랜치"; else act_label="프로젝트 합계"; fi

  # ---- ① 판정: 실제 문제만 첫 줄 이모지에 반영 (심각한 것부터, 여러 개면 "외 N건") ----
  local probs=() level=ok
  if [ "$B_as_bad" = "true" ]; then
    level=crit
    if [ "$B_hj" = "true" ] && [ "${B_fon:-0}" -ge 1 ] 2>/dev/null; then probs+=("Neon autosuspend 미작동 의심 — 24h 중 ${B_fon}시간 내내 켜짐")
    else probs+=("Neon autosuspend 미작동 의심 — 직전 대비 가동률 $(_fmt_pct "$B_dratio")"); fi
  fi
  if [ "$B_site_open" = "true" ]; then level=crit; if [ -n "$B_inc_failed" ]; then probs+=("사이트 장애 중 — ${B_inc_failed} 실패"); else probs+=("사이트 장애 중 — 복구 확인 대기"); fi; fi
  if [ "$B_over" = "true" ]; then [ "$level" = crit ] || level=warn; probs+=("Neon 예산 초과 예상 — \$${B_cost} / \$${B_budget}"); fi
  if [ "$B_up_unknown" = "true" ]; then [ "$level" = crit ] || level=warn; probs+=("업타임 감시 마지막 성공 확인 불가 — 감시가 도는지 직접 확인")
  elif [ "$B_up_bad" = "true" ]; then [ "$level" = crit ] || level=warn; probs+=("업타임 감시가 ${B_up_max}시간 넘게 멈춤 — 장애를 못 잡는 상태"); fi
  if [ "$B_full_bad" = "true" ]; then [ "$level" = crit ] || level=warn; probs+=("DB 경유 체크가 ${B_full_max}시간 넘게 없음"); fi
  if [ "$B_idle_bad" = "true" ]; then [ "$level" = crit ] || level=warn; local left=$((60 - B_idle)); [ "$left" -ge 0 ] || left=0
    probs+=("저장소 ${B_idle}일 무커밋 — ${left}일 뒤 감시 스케줄 자동 정지"); fi
  local emoji head
  case "$level" in crit) emoji="🔴" ;; warn) emoji="⚠️" ;; *) emoji="✅" ;; esac
  if [ ${#probs[@]} -eq 0 ]; then
    if [ -n "$B_cost" ]; then head="이상 없음 — 예상 비용 \$${B_cost} / 예산 \$${B_budget}, autosuspend 작동"
    else head="이상 없음 — autosuspend 작동 (예상 비용은 기간 2일차부터)"; fi
  else
    head="${probs[0]}"; [ ${#probs[@]} -le 1 ] || head+=" 외 $(( ${#probs[@]} - 1 ))건"
  fi
  local tag="${a[tag]-}"; [ "$B_preview" = "true" ] && [ -z "$tag" ] && tag="[미리보기] "
  local -a L; L=("${tag}${emoji} <b>$(h "$head")</b>"
     "simparty 일일 브리프 · $(_kst "$now" %m-%d)($(_kst_wd "$now")) $(_kst "$now" %H:%M) KST")
  if [ ${#probs[@]} -gt 1 ]; then
    local p; for p in "${probs[@]:1}"; do L+=("· $(h "$p")"); done
  fi

  # ---- ② 사이트 ----
  L+=("")
  if [ "$B_site_known" != "true" ]; then
    L+=("<b>사이트</b> — 확인 불가 (장애 이슈 조회 실패)")
  elif [ "$B_site_open" = "true" ]; then
    local since_e; since_e="$(_epoch "$B_inc_since")"
    L+=("<b>사이트</b> — 🔴 장애 중")
    if [ -n "$B_inc_failed" ]; then
      L+=("· 실패: $(_fmt_codes "$B_inc_failed")${since_e:+ · $(fmt_when "$since_e" "$now") 부터 ($(fmt_dur $(( (now - since_e) / 60 ))))}")
    else
      L+=("· 1차 전부 통과 — 다음 실행도 통과하면 🟢 복구 + close${since_e:+ ($(fmt_when "$since_e" "$now") 부터)}")
    fi
    [[ "$B_inc_url" == https://* ]] && L+=("· $(_fmt_links "$B_inc_url" "")")
  elif [ "$B_up_fresh" = "true" ]; then
    L+=("<b>사이트</b> — ✅ 정상 (열린 장애 이슈 없음)")
  elif [ -n "$B_up_at" ]; then
    # 이슈가 없어도 감시가 오래 못 돌았으면 '정상' 이라고 말하지 않는다 — 그 사이 장애는 이슈가 안 열렸을 뿐일 수 있다
    L+=("<b>사이트</b> — 열린 장애 이슈 없음 · 마지막 확인 $(fmt_ago $((now - B_up_at))) ⚠️ <i>(${B_site_fresh_h}시간 넘게 확인 없음 — 정상 여부 모름)</i>")
  else
    L+=("<b>사이트</b> — 열린 장애 이슈 없음 · 마지막 확인 기록 없음 ⚠️ <i>(정상 여부 모름)</i>")
  fi
  local up_line="BE 생존(liveness) · FE 응답(robots) 마지막 확인 "
  if [ -n "$B_up_at" ]; then up_line+="<code>$(fmt_when "$B_up_at" "$now")</code>"; else up_line+="기록 없음"; fi
  local full_line="DB 포함 점검(readiness·의상 API·홈 화면) 마지막 확인 "
  if [ -n "$B_full_at" ]; then full_line+="<code>$(fmt_when "$B_full_at" "$now")</code> <i>(KST 11~23시에만)</i>"; else full_line+="기록 없음"; fi
  L+=("· $up_line" "· $full_line")

  # ---- ③ Neon 사용·비용 ----
  L+=("" "<b>Neon 사용·비용</b> — 결제기간 <code>${B_el}/${B_tot}</code>일차${B_note:+ $(h "$B_note")}")
  L+=("· CU-h 누적 <code>${apx}${B_cuh}</code> → 기간말 예상 <code>${apx}${B_cuproj:-n/a}</code>${B_quota:+ · quota <code>${B_quota}%</code>}")
  if [ -n "$B_cost" ]; then
    local bp; bp="$(jq -rn --arg c "$B_cost" --arg b "$B_budget" 'if ($b|tonumber) > 0 then (($c|tonumber) / ($b|tonumber) * 100 | round | tostring) + "%" else "" end' 2>/dev/null || true)"
    L+=("· 예상 비용 <code>\$${B_cost}</code> / 예산 <code>\$${B_budget}</code>${bp:+ ($bp)}$([ "$B_over" = true ] && printf ' ⚠️ 초과')")
  else
    L+=("· 예상 비용 n/a <i>(기간 시작 1일 미만 — 외삽 생략)</i> / 예산 <code>\$${B_budget}</code>")
  fi
  L+=("· 전송 <code>${B_tx} GB</code> · 스토리지 <code>${B_st} GB</code>")
  [ -z "$apx" ] || L+=("· <i>≈ = 요금 API(v2) 미사용, compute_time 근사치</i>")

  # ---- ④ autosuspend ----
  local as_state
  if [ "$B_as_bad" = "true" ]; then as_state="🔴 미작동 의심"
  elif [ "$B_hj" = "true" ] || [ "$B_dj" = "true" ]; then as_state="✅ 작동 중"
  else as_state="⏭ 판정 생략"; fi
  L+=("" "<b>autosuspend</b> — $as_state")
  if [ "$B_hj" = "true" ]; then
    L+=("· 최근 24h 중 내내 켜져 있던 시간 <code>${B_fon}/${B_hrs}</code>시간 <i>(프로젝트 합계 · 90% 이상이면 🔴)</i>")
  elif [ "$B_hnd" = "true" ]; then
    L+=("· 24h 시간별 데이터 없음 — 종일 수면 또는 API 형식 변경 (판정 불가)")
  fi
  if [ "$B_dj" = "true" ]; then
    L+=("· ${act_label} 직전 실행 대비 가동률 <code>$(_fmt_pct "$B_dratio")</code> <i>(90% 이상이면 🔴)</i>")
  else
    L+=("· ${act_label}: $(h "$B_dwhy")${B_pratio:+ · 기간 평균 가동률 <code>$(_fmt_pct "$B_pratio")</code>}")
  fi
  if [ "$B_as_bad" = "true" ]; then
    L+=("· 근거: compute 가 거의 쉬지 않음 — 5분보다 잦은 DB 호출(헬스체크·감시·keepalive·스케줄러) 확인")
  elif [ "$as_state" = "✅ 작동 중" ]; then
    L+=("· 근거: 요청이 5분 끊기면 compute 가 잠들고 있음 → 쓴 만큼만 과금")
  fi

  # ---- ⑤ 감시 자체 ----
  L+=("" "<b>감시 자체</b>")
  local hb1 hb2
  if [ -n "$B_up_at" ]; then hb1="uptime 최근 성공 $(fmt_ago $((now - B_up_at)))"; [ "$B_up_bad" = true ] && hb1+=" ⚠️"
  else hb1="uptime 성공 기록 확인 불가 ⚠️"; fi
  if [ -n "$B_full_at" ]; then hb2="DB체크 $(fmt_ago $((now - B_full_at)))"; [ "$B_full_bad" = true ] && hb2+=" ⚠️"
  else hb2="DB체크 기록 확인 불가 ⚠️"; fi
  L+=("· $hb1 · $hb2 <i>(⚠️ 기준 ${B_up_max}시간 / ${B_full_max}시간)</i>")
  if [ -n "$B_runs" ]; then
    local runs_line="· 최근 24h 정기 실행 <code>${B_runs}</code>회 / 설계 ${B_dr}"
    [ -z "$B_full24" ] || runs_line+=" · DB체크 <code>${B_fullx:-$B_full24}</code>회 / 설계 ${B_df}"
    L+=("$runs_line")
    if [ "${B_dr:-0}" -gt 0 ] 2>/dev/null && [ $(( B_runs * 100 / B_dr )) -lt 50 ]; then
      L+=("  <i>GitHub cron 이 무료 스케줄을 지연·드롭한 것 — 감시 고장 아님(위 ⚠️ 기준을 넘을 때만 문제)</i>")
    fi
  else
    L+=("· 최근 24h 실행 횟수 확인 불가")
  fi
  if [ -n "$B_idle" ]; then
    L+=("· 저장소 마지막 커밋 $(fmt_ago $((B_idle * 86400)))$([ "$B_idle_bad" = true ] && printf ' ⚠️ 사소한 커밋 1건 필요') <i>(60일 무활동이면 스케줄 자동 정지 · ${B_idle_warn}일부터 ⚠️)</i>")
  else
    L+=("· 저장소 마지막 커밋 확인 불가 ⚠️ <i>(60일 무활동이면 스케줄 자동 정지 — 직접 확인)</i>")
  fi
  _fmt_print
}

# ---- 직접 실행: 렌더 미리보기 (예: bash telegram-format.sh sample detected) ----
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  case "${1:-}" in
    sample) shift; fmt_sample "${1:-detected}"; echo ;;
    plain)  shift; html_to_plain "$(cat)"; echo ;;
    *) echo "사용: bash telegram-format.sh sample detected|recovered|selffail|flap  |  ... | bash telegram-format.sh plain"; exit 64 ;;
  esac
fi
