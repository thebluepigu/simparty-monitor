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
#   fmt_brief             Neon 일일 브리프 (🟢 / 🟡 / 🔴 — 섹션별 신호등 + 첫 줄)    neon-usage.sh §5
#   fmt_outage_detected   🔴 장애 감지 — kind=new(신규) | reopen(재발) |            uptime.sh
#                            selffail(GitHub 이슈 기록 실패 → 직접 알림)
#   fmt_flap              🟡 장애·복구 반복 (12시간 안 재발 2회째)                   uptime.sh
#   fmt_outage_ongoing    🔴 장애 지속 — kind=remind(6h 재알림) | retry(전송 실패분   uptime.sh
#                            재시도) | flap_remind(반복 중 재알림)
#   fmt_outage_expanded   🔴 장애 확대 (아직 알리지 않은 점검이 새로 실패)            uptime.sh
#   fmt_recovered         🟢 복구                                                   uptime.sh
#   fmt_selffail          🟡 감시 자체 실패                                          uptime.yml · neon-usage.yml
#   fmt_test              [샘플] test-alert 머리 메시지 (이모지 없음)                 uptime.sh test-alert
#   fmt_sample            test-alert 샘플 4종(detected·recovered·selffail·flap)       uptime.sh test-alert
#
#   - 각 함수는 key=value 인자만 받는다(순서 무관, 빠진 키 = 빈 값). 예:
#       fmt_outage_detected kind=new results=/tmp/r.tsv now=1760000000 mode=quick issue=https://… run=https://…
#   - results = uptime.sh 의 체크 결과 TSV (name \t ok(1/0) \t http \t 초 \t detail)
#   - 시각 인자(now·since·pass_at)는 epoch 또는 ISO-8601 둘 다 받는다. 출력은 전부 KST.
#
# ■ 신호등 (상태 이모지는 이 셋만 쓴다 — 2026-10-30)
#
#   🟢 정상 · 복구   🟡 주의(지금 당장 장애는 아니지만 확인 필요 · 감시 자체 실패 · 장애·복구 반복)   🔴 문제 · 장애
#   - 옛 기호 ✅ ⚠️ 🟠 ≈ 🧪 ⏭ 는 쓰지 않는다(테스트가 렌더 본문에서 검사). 근사치·판정 생략은 글자로 쓴다.
#   - 브리프: 섹션 머리 = "🟢 <b>사이트</b>: 정상" 처럼 색을 맨 앞에(왼쪽 끝에 색이 세로로 줄 서 훑어보기 쉽게).
#     첫 줄 = 가장 나쁜 색 + 한 문장 판정(여러 개면 "외 N건", 나머지는 바로 아래 "- 🟡 …" 줄).
#     판정(어느 섹션이 무슨 색인지)은 neon-usage.sh 가 brief.json .level 에 계산한다 — 여기서는 표현만.
#     문제 줄을 하나 더 만들려면 neon-usage.sh 의 .level 조건과 fmt_brief 의 probs 를 같이 고친다(색만 있고 문장이
#     없으면 첫 줄이 "확인할 항목이 있어요" 로 대신 나온다).
#
# ■ 서식 규칙 (parse_mode=HTML)
#
#   - 허용 태그는 <b> <i> <code> <pre> <a href> 만. 동적 값(체크 이름·HTTP 코드·오류 문구·이슈 제목·URL)은
#     반드시 h(=html_escape, & < > 치환)를 거쳐 넣는다. href 값은 _ha(따옴표까지 치환).
#     태그 짝이 틀리면 텔레그램이 400 "can't parse entities" → tg_send 가 태그를 벗긴 plain 으로 1회 재전송한다(내용은 감).
#   - 첫 줄 = [태그] 신호등 + <b>한 문장 판정</b>. 둘째 줄 = 언제·무엇(평문). 섹션 사이 빈 줄 1개.
#   - 섹션 제목은 <b>제목</b>, 항목 줄은 "- " 로 시작, 한 줄 안 항목 구분은 " / ". 숫자는 <code>…</code>.
#   - 말은 쉽게: 영어 식별자는 필요할 때 괄호로 한 번만 — "서버 응답(liveness)", "DB 사용량(CU-h)", "DB 자동 절전".
#   - 표는 <pre>…</pre> 고정폭 — 한글은 2칸이라 정렬이 깨지므로 표 안에는 ASCII 만 쓰고, 바로 아래 범례 한 줄로 한글 설명.
#   - 시각: 같은 날 "HH:MM", 어제 "어제 HH:MM", 그 외 "MM-DD HH:MM" (fmt_when) / 상대 "N분 전·N시간 전·N일 전" (fmt_ago).
#   - 한 줄 바꾸려면 해당 L+=( … ) 줄만 고친다. 줄을 빼려면 그 줄을 지우면 된다(빈 줄 L+=("") 짝 주의).
#
# ■ 미리 보기
#   로컬:  bash .github/scripts/tests/telegram-format.test.sh        # 렌더 전문 + html_escape 단위 테스트
#          bash .github/scripts/tests/telegram-format.test.sh --plain  # 텔레그램에 보이는 모습(태그 제거)
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
# "liveness,robots" → "서버 응답(liveness), 화면 응답(robots)" — _txt 는 평문(제목처럼 나중에 h 할 곳), _fmt_labels 는 h 처리본
_fmt_labels_txt() {
  local IFS=, x out=()
  for x in $1; do [ -n "$x" ] && out+=("$(_fmt_label "$x")"); done
  local j; j="$(printf '%s, ' "${out[@]}")"; printf '%s' "${j%, }"
}
_fmt_labels() { h "$(_fmt_labels_txt "$1")"; }
_fmt_join() { local sep="$1"; shift; local j=""; local x; for x in "$@"; do [ -n "$x" ] || continue; j="${j:+$j$sep}$x"; done; printf '%s' "$j"; }
# 신호등: ok|warn|crit → 🟢|🟡|🔴
_fmt_light() { case "${1-}" in crit) printf '🔴' ;; warn) printf '🟡' ;; *) printf '🟢' ;; esac; }
# 점검 모드 → 쉬운 말. $2=long 이면 식별자를 괄호로 한 번
_fmt_mode() {
  local m="${1-}" t
  case "$m" in
    quick) t="빠른 점검" ;;
    full)  t="DB 포함 점검" ;;
    '')    printf '?'; return ;;
    *)     printf '%s' "$(h "$m")"; return ;;
  esac
  if [ "${2-}" = long ]; then printf '%s(%s)' "$t" "$m"; else printf '%s' "$t"; fi
}

# ---- 업타임 체크: 이름별 설명 ---------------------------------------------------
# 영향 — "어떤 화면이 안 열리나". 체크를 추가하면 여기와 _fmt_verdict 에 한 줄씩.
# 체크 식별자 → 한글 라벨 (문장 줄에서 사용. <pre> 표는 폭 유지를 위해 영문 식별자 그대로 + 아래 범례)
_fmt_label() {
  case "$1" in
    liveness)   printf '서버 응답(liveness)' ;;
    robots)     printf '화면 응답(robots)' ;;
    readiness)  printf 'DB 연결(readiness)' ;;
    categories) printf '의상 API(categories)' ;;
    home)       printf '홈 화면(home)' ;;
    *)          printf '%s' "$1" ;;
  esac
}
_FMT_LEGEND='liveness=서버 응답 / robots=화면 응답 / readiness=DB 연결 / categories=의상 API / home=홈 화면'
_fmt_impact() {
  case "$1" in
    liveness)   printf '서버(API) 전체 — 의상 목록·상세·예약, 관리자 화면 모두 데이터가 안 나와요' ;;
    robots)     printf '웹 화면 전체 — simparty.shop 접속 자체가 안 돼요' ;;
    readiness)  printf '서버는 살아 있지만 DB 를 못 읽어 의상·예약 데이터가 안 나와요' ;;
    categories) printf '고객 의상 목록(DB 경유) — 홈 카테고리·의상 목록이 비어 보여요' ;;
    home)       printf 'simparty.shop 첫 화면(SSR)이 안 그려져요' ;;
    *)          printf '%s 점검 실패' "$(h "$1")" ;;
  esac
}
# 실패 집합 → 한 문장 판정 (첫 줄 굵게 부분). **평문**을 돌려준다 — 부르는 쪽이 h 로 한 번만 이스케이프(이중 이스케이프 방지)
_fmt_verdict() {
  local f="$1"
  if _csv_has "$f" liveness && _csv_has "$f" robots; then printf '사이트 전체 접속 불가 (서버·화면 모두 응답 없음)'
  elif _csv_has "$f" liveness; then printf '서버(API) 응답 없음'
  elif _csv_has "$f" robots; then printf '웹 화면 응답 없음'
  elif _csv_has "$f" readiness || _csv_has "$f" categories; then printf 'DB 연결 점검 실패'
  elif _csv_has "$f" home; then printf '홈 화면이 안 열림'
  elif [ -n "$f" ]; then printf '점검 실패: %s' "$f"
  else printf '실패한 점검 없음'; fi
}
_FMT_DB_CHECKS="readiness,categories,home"

# 결과 TSV → <pre> 표 + 범례 + 실패 상세 줄. $1 results
#   표는 원문으로 칸을 맞춘 뒤 통째로 h — 텔레그램은 &lt; 를 한 글자(<)로 보여 주므로 원문 기준 패딩이 화면 정렬과 같다
#   (이스케이프 후 패딩하면 &lt; 가 4칸으로 세여 오히려 어긋난다 — 테스트 'pre 표 정렬')
_fmt_results() {
  local file="$1" name ok code t detail rows dets=()
  [ -s "$file" ] || { printf '<i>(이번 실행 점검 결과 없음)</i>'; return; }
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
      [ "$code" = "000" ] && [ "${detail#네트워크}" = "$detail" ] && detail="응답 없음 / $detail"
      dets+=("- <code>$(h "$name")</code>: <i>$(h "${detail:0:140}")</i>")
    fi
  done < "$file"
  printf '<pre>%s</pre>\n<i>%s</i>' "$(h "$rows")" "$(h "$_FMT_LEGEND")"
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
  _fmt_join ' / ' "${a[@]}" "${b[@]}"
}
_fmt_print() { local IFS=$'\n'; printf '%s' "${L[*]}"; }
# 0.123 → "12%"
_fmt_pct() { jq -rn --arg x "$1" '($x | tonumber * 100 | round | tostring) + "%"' 2>/dev/null || printf '%s' "$1"; }

# =============================================================================
# 업타임 알림 (🔴 · 🟡) — 공통 골격: ① 판정 ② 점검 결과 표 ③ 영향 ④ 다음 동작 ⑤ 링크
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
  local nf_label; nf_label="$(_fmt_labels_txt "${a[new_fails]-}")"

  # ① 판정 — kind 별 첫 줄·둘째 줄 (둘째 줄은 평문, 마지막에 통째로 h)
  case "$kind" in
    new)         emoji="🔴"; title="simparty 장애 감지 — $verdict"
                 sub="$when KST 감지 / $(_fmt_mode "$mode" long) / 10초 뒤 다시 해 봐도 실패" ;;
    reopen)      emoji="🔴"; title="simparty 장애 재발 — $verdict"
                 sub="$when KST 감지 / 복구 후 ${reopen_h}시간 안에 다시 나서 같은 이슈를 다시 열었어요" ;;
    selffail)    emoji="🔴"; title="simparty 장애 감지 — $verdict"
                 sub="$when KST 감지 / GitHub 이슈 기록이 안 돼 상태 추적 없이 직접 보내는 알림" ;;
    flap)        emoji="🟡"; title="simparty 장애·복구 반복 — 12시간 안 재발 2회째"
                 sub="$when KST / 지금 상태: $verdict" ;;
    remind)      emoji="🔴"; title="simparty 장애 지속 — 다운 약 $(fmt_dur "$down_min")"
                 sub="$verdict / $(fmt_when "$since" "$now") 부터 / ${remind_h}시간마다 다시 알림" ;;
    retry)       emoji="🔴"; title="simparty 장애 지속 — 다운 약 $(fmt_dur "$down_min")"
                 sub="$verdict / $(fmt_when "$since" "$now") 부터 / 직전 알림이 전송 실패해 다시 보냄" ;;
    flap_remind) emoji="🔴"; title="simparty 장애 반복 중 — 다운 약 $(fmt_dur "$down_min")"
                 sub="$verdict / ${remind_h}시간마다 다시 알림 (재발·복구 알림은 멈춘 상태)" ;;
    expanded)    emoji="🔴"; title="simparty 장애 확대 — 새로 실패: ${nf_label:-?}"
                 sub="$verdict / 다운 약 $(fmt_dur "$down_min") ($(fmt_when "$since" "$now") 부터)" ;;
    *)           emoji="🔴"; title="simparty 장애 — $verdict"; sub="$when KST" ;;
  esac
  local -a L; L=("${tag}${emoji} <b>$(h "$title")</b>" "$(h "$sub")")

  # ② 점검 결과
  L+=("" "<b>점검 결과</b> ($(_fmt_mode "$mode") / $when KST)" "$(_fmt_results "$res")")
  local carried; carried="$(jq -rn --arg a "$failed" --arg b "$ran_failed" '($a|split(",")|map(select(.!=""))) - ($b|split(",")) | join(",")' 2>/dev/null || true)"
  if [ -n "$carried" ]; then
    L+=("- 이번 점검에서 다시 확인 못 한 실패: $(_fmt_labels "$carried") — DB 를 거치는 점검이라 DB 포함 점검에서만 다시 확인")
  fi

  # ③ 영향
  L+=("" "<b>영향</b>")
  local IFS_OLD="$IFS" c dep
  IFS=,
  for c in $failed; do
    [ -n "$c" ] || continue
    dep=""
    if _csv_has "$failed" liveness && _csv_has "$_FMT_DB_CHECKS" "$c"; then dep=" (서버가 멈춘 탓)"; fi
    L+=("- <b>$(h "$(_fmt_label "$c")")</b>: $(_fmt_impact "$c")$dep")
  done
  IFS="$IFS_OLD"

  # ④ 다음 동작
  L+=("" "<b>다음 동작</b>")
  local remind_at; remind_at=$(( now + remind_h * 3600 ))
  case "$kind" in
    selffail)
      L+=("- 이슈 기록이 안 되는 동안 같은 알림을 1→3→6시간 간격으로 다시 보내요")
      L+=("- GitHub API 가 회복되면 평소 흐름(장애 이슈 / 다시 알림 / 🟢 복구)으로 돌아가요") ;;
    flap)
      L+=("- 이제 재발·복구 알림은 보내지 않아요 — 장애가 이어지면 <b>$(fmt_when "$remind_at" "$now")</b> KST(${remind_h}시간 뒤)부터 ${remind_h}시간마다만 다시 알림")
      L+=("- 복구 조건 강화: 모두 통과가 <b>${hold_min}분</b> 이어져야 🟢 + 이슈 close") ;;
    *)
      L+=("- 장애가 이어지면 <b>$(fmt_when "$remind_at" "$now")</b> KST(${remind_h}시간 뒤)에 다시 알림")
      [ "$kind" = "flap_remind" ] || L+=("- 아직 알리지 않은 점검이 새로 실패하면 '확대' 알림 1건 (직전 알림 1시간 뒤부터)")
      if [ "$kind" = "flap_remind" ] || [ "${a[flap_hold]-}" = "1" ]; then
        L+=("- 반복 장애라 모두 통과가 <b>${hold_min}분</b> 이어져야 🟢 + 이슈 close")
      else
        L+=("- 실패한 점검이 연속 2번(약 10분 간격) 모두 통과하면 🟢 복구 알림 + 이슈 자동 close")
      fi
      [ "$kind" = "reopen" ] && L+=("- 12시간 안에 또 재발하면 🟡 1건만 보내고 그 뒤 재발·복구 알림은 멈춰요") ;;
  esac
  local dbf=""
  for c in readiness categories home; do _csv_has "$failed" "$c" && dbf="${dbf:+$dbf,}$c"; done
  if [ -n "$dbf" ] && [ "$kind" != "selffail" ]; then
    L+=("- $(_fmt_labels "$dbf") 는 DB 를 거치는 점검이라 DB 포함 점검(다음 <b>$(fmt_when "$(_fmt_next_full "$now")" "$now")</b> KST)에서만 다시 확인 → 그때 통과해야 복구 확정")
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
# 🟢 복구 — ① 판정 ② 장애 요약 ③ 지금 점검 결과 ④ 링크
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

  local hold_min="${a[flap_hold_min]:-120}" reopen_h=$(( ${a[reopen_min]:-360} / 60 )) how="연속 2번 모두 통과"
  # 반복 장애(flap-hold)는 close 조건이 '전부 통과가 hold_min 분 지속' 이다 (uptime.sh FLAP_HOLD_MIN)
  [ "${a[flap_hold]-}" != "1" ] || how="전부 통과가 ${hold_min}분 이어짐 (반복 장애 강화 조건)"
  local -a L; L=("${tag}🟢 <b>simparty 복구 — 다운 약 $(fmt_dur "$down_min")</b>"
     "$(fmt_when "$now" "$now") KST 확인 / $how")
  L+=("" "<b>장애 요약</b>")
  L+=("- 시작 <code>$(fmt_when "$since" "$now")</code> → 첫 통과 <code>$(fmt_when "$pass_at" "$now")</code> → 복구 확정 <code>$(fmt_when "$now" "$now")</code> KST")
  if [ -n "$seen" ]; then
    L+=("- 실패했던 점검: $(_fmt_labels "$seen")")
    L+=("- 그동안 영향: $(h "$(_fmt_verdict "$seen")")")
  fi
  local n="${a[reopens]:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -eq 0 ] || L+=("- 최근 12시간 재발 <code>$n</code>번 — 또 반복되면 재발·복구 알림은 멈춰요")
  L+=("- 장애 이슈는 지금 자동 close — ${reopen_h}시간 안에 재발하면 같은 이슈를 다시 열어요")
  L+=("" "<b>지금 점검 결과</b> ($(_fmt_mode "${a[mode]-}"))" "$(_fmt_results "${a[results]-}")")
  local links; links="$(_fmt_links "${a[issue]-}" "${a[run]-}" "${a[issue_text]-}")"
  [ -z "$links" ] || L+=("" "$links")
  _fmt_print
}

# =============================================================================
# 🟡 감시 자체 실패 — 사이트가 아니라 감시가 끝까지 못 돈 경우
# =============================================================================
# 인자: workflow(uptime|neon-usage) mode reason(여러 줄) run suppress_h(기본 6) now tag
fmt_selffail() {
  local -A a=(); _fmt_args a "$@"
  local wf="${a[workflow]:-?}" mode="${a[mode]-}" reason="${a[reason]-}" sh="${a[suppress_h]:-6}" now next hint
  now="$(_epoch "${a[now]-}")"; now="${now:-$(_fmt_now)}"
  local -a L; L=("${a[tag]-}🟡 <b>감시 자체 실패 — $(h "$wf")${mode:+ ($(h "$mode"))}</b>"
     "$(fmt_when "$now" "$now") KST / 사이트가 아니라 감시 스크립트 쪽 문제예요")
  L+=("" "<b>사유</b>")
  if [ -n "$reason" ]; then L+=("<pre>$(h "${reason:0:900}")</pre>"); else L+=("<i>(사유 기록 없음 — 실행 로그 확인)</i>"); fi
  L+=("" "<b>영향</b>")
  if [ "$wf" = "neon-usage" ]; then
    L+=("- 오늘 일일 브리프(DB 사용량 / DB 자동 절전 판정)가 빠졌어요")
    next="내일 09:17 KST 정기 실행"
    hint="NEON_API_KEY 만료·권한 / 텔레그램 시크릿 / Neon API 장애"
  else
    L+=("- 이번 점검은 장애 여부를 판정하지 못했어요 — 그 사이 사이트가 멈췄어도 알림이 없었을 수 있어요")
    next="다음 정기 점검(10분 주기)"
    hint="권한(issues: write) / 텔레그램 시크릿 / GitHub API 장애"
  fi
  L+=("" "<b>다음 동작</b>")
  L+=("- 같은 알림은 <b>${sh}시간</b> 동안 다시 보내지 않아요 (GitHub 실패 메일은 매번 발송)")
  L+=("- ${next}이 성공하면 자동으로 정상화 — 따로 🟢 알림은 없어요")
  L+=("- 반복되면 실행 로그 확인: $hint")
  local links; links="$(_fmt_links "" "${a[run]-}")"
  [ -z "$links" ] || L+=("" "$links")
  _fmt_print
}

# =============================================================================
# test-alert 머리(이모지 없이 [샘플]) + 샘플 4종 (fixture — 실제 체크·이슈와 무관)
# =============================================================================
fmt_test() {
  local -A a=(); _fmt_args a "$@"
  local now; now="$(_epoch "${a[now]-}")"; now="${now:-$(_fmt_now)}"
  local -a L; L=("<b>[샘플] 텔레그램 알림 미리보기 — 실제 장애 아님</b>"
     "$(fmt_when "$now" "$now") KST / 연동 확인 겸 알림 서식 샘플")
  L+=("" "이어서 샘플 4건이 와요: 🔴 장애 감지 / 🟢 복구 / 🟡 감시 자체 실패 / 🟡 장애·복구 반복")
  L+=("색 뜻: 🟢 정상 / 🟡 주의(확인 필요) / 🔴 문제·장애")
  L+=("문구·줄바꿈 조정은 <code>.github/scripts/telegram-format.sh</code> 한 파일에서 해요.")
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
# Neon 일일 브리프 — ① 판정 ② 사이트 ③ DB 사용량과 비용 ④ DB 자동 절전 ⑤ 감시 자체 ⑥ 다음 브리프
# =============================================================================
# 인자: json=<neon-usage.sh 가 만든 brief.json 경로> tag(옵션, 예: "[미리보기] ")
# brief.json 의 값·판정 플래그·섹션 신호등(.level)은 neon-usage.sh 가 계산한다(이 함수는 표현만). 기준값을 바꾸려면 neon-usage.sh.
fmt_brief() {
  local -A a=(); _fmt_args a "$@"
  local json="${a[json]-}"
  [ -s "$json" ] || { printf '🟡 <b>일일 브리프 렌더 실패 — 입력 없음</b>'; return 0; }
  # 스칼라 값을 B_* 셸 변수로 (@sh 인용 — eval 안전). null → 빈 문자열
  local B_now B_preview B_project B_el B_tot B_note B_cu_apx B_cuh B_cuproj B_quota B_cost B_budget B_over B_tx B_st
  local B_cpct B_near B_bwarn
  local B_as_bad B_hj B_hnd B_fon B_hrs B_dj B_dratio B_dwhy B_actsrc B_pratio
  local B_site_known B_site_open B_inc_num B_inc_url B_inc_failed B_inc_since
  local B_up_at B_full_at B_up_max B_full_max B_up_bad B_full_bad B_full_unknown B_runs B_full24 B_fullx B_dr B_df
  local B_up_unknown B_up_fresh B_site_fresh_h B_rwarn B_runs_low B_full_low
  local B_idle B_idle_warn B_idle_bad B_idle_unknown B_sched
  local B_lv_site B_lv_cost B_lv_as B_lv_watch B_lv_all
  eval "$(jq -r '
    def s: if . == null then "" else tostring end;
    def kv($k; $v): "\($k)=\($v | s | @sh)";
    kv("B_now"; .now), kv("B_preview"; .preview), kv("B_project"; .project),
    kv("B_el"; .period.elapsed), kv("B_tot"; .period.total), kv("B_note"; .period.note),
    kv("B_cu_apx"; .cu.approx), kv("B_cuh"; .cu.hours), kv("B_cuproj"; .cu.projected), kv("B_quota"; .cu.quota_pct),
    kv("B_cost"; .cost.projected), kv("B_budget"; .cost.budget), kv("B_over"; .cost.over),
    kv("B_cpct"; .cost.pct), kv("B_near"; .cost.near // false), kv("B_bwarn"; .cost.warn_pct // 80),
    kv("B_tx"; .transfer_gb), kv("B_st"; .storage_gb),
    kv("B_as_bad"; .as.bad), kv("B_hj"; .as.hour_judged), kv("B_hnd"; .as.hour_nodata),
    kv("B_fon"; .as.full_on), kv("B_hrs"; .as.hours), kv("B_dj"; .as.delta_judged),
    kv("B_dratio"; .as.delta_ratio), kv("B_dwhy"; .as.delta_why), kv("B_actsrc"; .as.act_src), kv("B_pratio"; .as.period_ratio),
    kv("B_site_known"; (.site != null)), kv("B_site_open"; (.site.open // false)),
    kv("B_inc_num"; .site.number), kv("B_inc_url"; .site.url), kv("B_inc_failed"; .site.failed), kv("B_inc_since"; .site.since),
    kv("B_up_at"; .hb.uptime_at), kv("B_full_at"; .hb.full_at), kv("B_up_max"; .hb.uptime_max_h), kv("B_full_max"; .hb.full_max_h),
    kv("B_up_bad"; .hb.uptime_bad), kv("B_full_bad"; .hb.full_bad), kv("B_full_unknown"; .hb.full_unknown // (.hb.full_at == null)),
    kv("B_up_unknown"; .hb.uptime_unknown // (.hb.uptime_at == null)), kv("B_up_fresh"; .hb.uptime_fresh // false),
    kv("B_site_fresh_h"; .hb.site_fresh_h // 3),
    kv("B_runs"; .hb.runs24), kv("B_full24"; .hb.full24), kv("B_fullx"; .hb.full_exec24), kv("B_dr"; .hb.design_runs), kv("B_df"; .hb.design_full),
    kv("B_rwarn"; .hb.runs_warn_pct // 0), kv("B_runs_low"; .hb.runs_low // false), kv("B_full_low"; .hb.full_low // false),
    kv("B_idle"; .repo.idle_days), kv("B_idle_warn"; .repo.warn_days), kv("B_idle_bad"; .repo.bad),
    kv("B_idle_unknown"; .repo.unknown // (.repo.idle_days == null)),
    kv("B_sched"; .sched // "github"),
    kv("B_lv_site"; .level.site // "ok"), kv("B_lv_cost"; .level.cost // "ok"), kv("B_lv_as"; .level.as // "ok"),
    kv("B_lv_watch"; .level.watch // "ok"), kv("B_lv_all"; .level.overall // "ok")
  ' "$json")"
  local now="${B_now:-$(_fmt_now)}" apx="" act_label
  [ "$B_cu_apx" = "true" ] && apx=" (근사치)"
  if [ "$B_actsrc" = "branch" ]; then act_label="기본 브랜치"; else act_label="프로젝트 합계"; fi
  local up_ago="" full_ago="" full_h=""
  [ -z "$B_up_at" ] || up_ago="$(fmt_ago $((now - B_up_at)))"
  if [ -n "$B_full_at" ]; then full_ago="$(fmt_ago $((now - B_full_at)))"; full_h=$(( (now - B_full_at) / 3600 )); fi

  # ---- ① 판정: 문제·주의를 심각한 것부터 "색|문장" 으로 모은다 (색 판정은 brief.json .level — 여기 조건은 문장 고르기용) ----
  local probs=()
  if [ "$B_as_bad" = "true" ]; then
    if [ "$B_hj" = "true" ] && [ "${B_fon:-0}" -ge 1 ] 2>/dev/null; then probs+=("crit|DB 자동 절전 미작동 의심 — 최근 24시간 중 ${B_fon}시간이 한 시간 내내 켜져 있었어요")
    else probs+=("crit|DB 자동 절전 미작동 의심 — 직전 브리프 이후 켜져 있던 비율 $(_fmt_pct "$B_dratio")"); fi
  fi
  if [ "$B_site_open" = "true" ]; then
    if [ -n "$B_inc_failed" ]; then probs+=("crit|사이트 장애 중 — $(_fmt_labels_txt "$B_inc_failed") 실패")
    else probs+=("crit|사이트 장애 중 — 복구 확인 대기"); fi
  fi
  if [ "$B_over" = "true" ]; then probs+=("warn|예산을 넘을 것 같아요 — 월말 예상 \$${B_cost} / 예산 \$${B_budget}")
  elif [ "$B_near" = "true" ]; then probs+=("warn|예산의 ${B_bwarn}%를 넘을 것 같아요 — 월말 예상 \$${B_cost} / 예산 \$${B_budget} (${B_cpct}%)"); fi
  if [ "$B_up_unknown" = "true" ]; then probs+=("warn|사이트 점검 마지막 성공을 확인할 수 없어요 — 감시가 도는지 직접 확인")
  elif [ "$B_up_bad" = "true" ]; then probs+=("warn|사이트 점검이 ${B_up_max}시간 넘게 멈췄어요 — 장애가 나도 알림이 안 와요")
  elif [ "$B_site_known" = "true" ] && [ "$B_site_open" != "true" ] && [ "$B_up_fresh" != "true" ]; then
    probs+=("warn|사이트 마지막 확인이 ${up_ago} — 지금 정상인지 몰라요"); fi
  [ "$B_site_known" = "true" ] || probs+=("warn|사이트 장애 여부 확인 불가 — 장애 이슈 조회 실패")
  if [ "$B_full_bad" = "true" ]; then probs+=("warn|DB 점검이 ${full_h}시간째 없어요 (기준 ${B_full_max}시간)")
  elif [ "$B_full_unknown" = "true" ]; then probs+=("warn|DB 점검 기록을 확인할 수 없어요"); fi
  if [ "$B_runs_low" = "true" ] || [ "$B_full_low" = "true" ]; then
    probs+=("warn|24시간 점검 횟수가 예정의 ${B_rwarn}%보다 적어요 — 예약 실행이 제대로 도는지 확인"); fi
  if [ "$B_idle_bad" = "true" ]; then local left=$((60 - B_idle)); [ "$left" -ge 0 ] || left=0
    probs+=("warn|감시 저장소 ${B_idle}일째 커밋 없음 — ${left}일 뒤 감시가 자동으로 멈춰요 (사소한 커밋 1건 필요)")
  elif [ "$B_idle_unknown" = "true" ]; then probs+=("warn|감시 저장소 마지막 커밋을 확인할 수 없어요 — 60일 무활동이면 감시가 멈추니 직접 확인"); fi
  [ "$B_lv_as" != "warn" ] || probs+=("warn|DB 자동 절전 판정 생략 — 판정할 데이터가 부족해요")

  local head
  if [ ${#probs[@]} -eq 0 ]; then
    if [ "$B_lv_all" != "ok" ]; then head="확인할 항목이 있어요 — 아래 색 표시 확인"
    elif [ -n "$B_cost" ]; then head="이상 없음 — 월말 예상 비용 \$${B_cost} / 예산 \$${B_budget}, DB 자동 절전 작동 중"
    else head="이상 없음 — DB 자동 절전 작동 중 (월말 예상 비용은 결제 기간 2일째부터)"; fi
  else
    head="${probs[0]#*|}"; [ ${#probs[@]} -le 1 ] || head+=" 외 $(( ${#probs[@]} - 1 ))건"
  fi
  local tag="${a[tag]-}"; [ "$B_preview" = "true" ] && [ -z "$tag" ] && tag="[미리보기] "
  local -a L; L=("${tag}$(_fmt_light "$B_lv_all") <b>$(h "$head")</b>"
     "simparty 일일 브리프 / $(_kst "$now" %m-%d)($(_kst_wd "$now")) $(_kst "$now" %H:%M) KST")
  if [ ${#probs[@]} -gt 1 ]; then
    local p; for p in "${probs[@]:1}"; do L+=("- $(_fmt_light "${p%%|*}") $(h "${p#*|}")"); done
  fi

  # ---- ② 사이트 ----
  L+=("")
  local site_c; site_c="$(_fmt_light "$B_lv_site")"
  if [ "$B_site_known" != "true" ]; then
    L+=("$site_c <b>사이트</b>: 확인 불가 (장애 이슈 조회 실패)")
  elif [ "$B_site_open" = "true" ]; then
    local since_e; since_e="$(_epoch "$B_inc_since")"
    L+=("$site_c <b>사이트</b>: 장애 중")
    if [ -n "$B_inc_failed" ]; then
      L+=("- 실패: $(_fmt_labels "$B_inc_failed")${since_e:+ / $(fmt_when "$since_e" "$now") 부터 ($(fmt_dur $(( (now - since_e) / 60 ))))}")
    else
      L+=("- 한 번 모두 통과 — 다음 점검도 통과하면 🟢 복구 + 이슈 close${since_e:+ ($(fmt_when "$since_e" "$now") 부터)}")
    fi
    [[ "$B_inc_url" == https://* ]] && L+=("- $(_fmt_links "$B_inc_url" "")")
  elif [ "$B_up_fresh" = "true" ]; then
    L+=("$site_c <b>사이트</b>: 정상 (열린 장애 이슈 없음)")
  elif [ -n "$B_up_at" ]; then
    # 이슈가 없어도 감시가 오래 못 돌았으면 '정상' 이라고 말하지 않는다 — 그 사이 장애는 이슈가 안 열렸을 뿐일 수 있다
    L+=("$site_c <b>사이트</b>: 확인 필요 — 열린 장애 이슈는 없지만 마지막 확인이 ${up_ago} <i>(${B_site_fresh_h}시간 넘게 확인이 없어 지금 정상인지 몰라요)</i>")
  else
    L+=("$site_c <b>사이트</b>: 확인 필요 — 열린 장애 이슈는 없지만 마지막 확인 기록이 없어요 <i>(정상인지 몰라요)</i>")
  fi
  local up_line="서버 응답(liveness) / 화면 응답(robots) 마지막 확인 "
  if [ -n "$B_up_at" ]; then up_line+="<code>$(fmt_when "$B_up_at" "$now")</code>"; else up_line+="기록 없음"; fi
  local full_line="DB 연결 점검(readiness / 의상 API / 홈 화면) 마지막 확인 "
  if [ -n "$B_full_at" ]; then full_line+="<code>$(fmt_when "$B_full_at" "$now")</code> <i>(KST 11~23시에만 점검)</i>"; else full_line+="기록 없음"; fi
  L+=("- $up_line" "- $full_line")

  # ---- ③ DB 사용량과 비용 ----
  local cost_state day="${B_el%%.*}"
  case "$day" in ''|*[!0-9]*) day=0 ;; esac
  day=$(( day + 1 )); case "$B_tot" in ''|*[!0-9]*) ;; *) [ "$day" -le "$B_tot" ] || day="$B_tot" ;; esac   # 경과 12.0일 = 13일째
  if [ "$B_over" = "true" ]; then cost_state="예산을 넘을 것 같아요"
  elif [ "$B_near" = "true" ]; then cost_state="예산의 ${B_bwarn}%를 넘을 것 같아요"
  elif [ -n "$B_cost" ]; then cost_state="예산 안"
  else cost_state="아직 판정 전 (결제 기간 2일째부터)"; fi
  L+=("" "$(_fmt_light "$B_lv_cost") <b>DB 사용량과 비용</b> (Neon): $cost_state")
  L+=("- 이번 결제 기간 <code>${day}</code>일째 / ${B_tot}일${B_note:+ $(h "$B_note")}")
  L+=("- DB 사용량(CU-h) 지금까지 <code>${B_cuh}</code> → 월말 예상 <code>${B_cuproj:-n/a}</code>${apx}${B_quota:+ / 한도 대비 <code>${B_quota}%</code>}")
  if [ -n "$B_cost" ]; then
    local cmark=""; { [ "$B_over" = true ] || [ "$B_near" = true ]; } && cmark=" 🟡"
    L+=("- 월말 예상 비용 <code>\$${B_cost}</code> / 예산 <code>\$${B_budget}</code>${B_cpct:+ (${B_cpct}%)}${cmark} <i>(${B_bwarn}%부터 🟡)</i>")
  else
    L+=("- 월말 예상 비용 n/a <i>(결제 기간 시작 1일 미만 — 예상 생략)</i> / 예산 <code>\$${B_budget}</code>")
  fi
  L+=("- 데이터 전송 <code>${B_tx} GB</code> / 저장 용량 <code>${B_st} GB</code>")
  [ -z "$apx" ] || L+=("- <i>근사치 = 요금 API(v2)를 못 써 compute_time 으로 추정한 값</i>")

  # ---- ④ DB 자동 절전 (autosuspend) ----
  local as_state
  case "$B_lv_as" in crit) as_state="미작동 의심" ;; warn) as_state="판정 생략 (데이터 부족)" ;; *) as_state="작동 중" ;; esac
  L+=("" "$(_fmt_light "$B_lv_as") <b>DB 자동 절전</b> (autosuspend): $as_state")
  if [ "$B_hj" = "true" ]; then
    L+=("- 최근 24시간 중 한 시간 내내 켜져 있던 시간 <code>${B_fon}/${B_hrs}</code>시간 <i>(프로젝트 합계, 90% 이상이면 🔴)</i>")
  elif [ "$B_hnd" = "true" ]; then
    L+=("- 시간별 데이터 없음 — 하루 종일 잠들었거나 API 형식이 바뀜 (판정 불가)")
  fi
  if [ "$B_dj" = "true" ]; then
    L+=("- ${act_label}가 켜져 있던 비율 <code>$(_fmt_pct "$B_dratio")</code> <i>(직전 브리프 이후, 90% 이상이면 🔴)</i>")
  else
    L+=("- ${act_label}: $(h "$B_dwhy")${B_pratio:+ / 이번 결제 기간 평균 켜져 있던 비율 <code>$(_fmt_pct "$B_pratio")</code>}")
  fi
  if [ "$B_as_bad" = "true" ]; then
    L+=("- 확인할 것: DB 가 거의 쉬지 않아요 — 5분보다 잦은 DB 호출(헬스체크 / 감시 / keepalive / 스케줄러)")
  elif [ "$B_lv_as" = "ok" ]; then
    L+=("- 요청이 5분 끊기면 DB 가 잠들고 있어요 → 쓴 만큼만 과금")
  fi

  # ---- ⑤ 감시 자체 ----
  local watch_state="정상"; [ "$B_lv_watch" = "ok" ] || watch_state="확인 필요"
  L+=("" "$(_fmt_light "$B_lv_watch") <b>감시 자체</b>: $watch_state")
  local hb1 hb2
  if [ -n "$B_up_at" ]; then hb1="사이트 점검 마지막 성공 <code>${up_ago}</code>"; [ "$B_up_bad" = true ] && hb1+=" 🟡"
  else hb1="사이트 점검 마지막 성공 확인 불가 🟡"; fi
  if [ -n "$B_full_at" ]; then hb2="DB 점검 <code>${full_ago}</code>"; [ "$B_full_bad" = true ] && hb2+=" 🟡"
  else hb2="DB 점검 기록 확인 불가 🟡"; fi
  L+=("- $hb1 / $hb2 <i>(이보다 오래되면 🟡: ${B_up_max}시간 / ${B_full_max}시간)</i>")
  if [ -n "$B_runs" ]; then
    local runs_line="- 최근 24시간 점검 <code>${B_runs}</code>번 / 예정 ${B_dr}번"
    [ -z "$B_full24" ] || runs_line+=" (DB 점검 <code>${B_fullx:-$B_full24}</code>번 / 예정 ${B_df}번)"
    { [ "$B_runs_low" = true ] || [ "$B_full_low" = true ]; } && runs_line+=" 🟡"
    L+=("$runs_line")
    if [ "$B_runs_low" = true ] || [ "$B_full_low" = true ]; then
      L+=("  <i>예정의 ${B_rwarn}%보다 적으면 🟡 — 예약 실행이 제대로 도는지 확인</i>")
    elif [ "$B_sched" = "github" ] && [ "${B_dr:-0}" -gt 0 ] 2>/dev/null && [ $(( B_runs * 100 / B_dr )) -lt 50 ]; then
      L+=("  <i>GitHub 무료 스케줄이 늦거나 건너뛴 것 — 감시 고장 아님 (위 🟡 기준을 넘을 때만 문제)</i>")
    fi
  else
    L+=("- 최근 24시간 점검 횟수 확인 불가")
  fi
  if [ -n "$B_idle" ]; then
    L+=("- 감시 저장소 마지막 커밋 <code>$(fmt_ago $((B_idle * 86400)))</code>$([ "$B_idle_bad" = true ] && printf ' 🟡 사소한 커밋 1건 필요') <i>(60일 동안 커밋이 없으면 GitHub 가 감시를 자동으로 멈춤, ${B_idle_warn}일부터 🟡)</i>")
  else
    L+=("- 감시 저장소 마지막 커밋 확인 불가 🟡 <i>(60일 동안 커밋이 없으면 감시가 자동으로 멈춤 — 직접 확인)</i>")
  fi

  # ---- ⑥ 다음 브리프 (정기 실행 시각 09:17 KST — neon-usage.yml cron '17 0 * * *') ----
  local nday="내일"; [ "$(_kst "$now" %H%M)" -ge 917 ] 2>/dev/null || nday="오늘"
  if [ "$B_sched" = "cloudflare" ]; then L+=("" "다음 브리프: ${nday} 09:17")
  else L+=("" "다음 브리프: ${nday} 09:17 예정(지금은 GitHub 지연으로 오후에 올 수 있음)"); fi
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
