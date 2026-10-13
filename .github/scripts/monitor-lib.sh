# shellcheck shell=bash
# 감시 워크플로(uptime.yml / neon-usage.yml) 공통 함수. source 해서 쓴다.
#
# 보안 규칙: set -x 금지, curl -v 금지, 토큰 echo 금지.
# 텔레그램 토큰은 argv 에 올리지 않고 curl 설정을 stdin(-K -)으로 넘긴다
# (GitHub 로그 마스킹에 더해 프로세스 목록 노출도 피함).

# 메시지 템플릿(html_escape·html_to_plain·fmt_*) — tg_send 의 plain 재전송도 여기 함수를 쓴다
# shellcheck source=telegram-format.sh
source "$(dirname "${BASH_SOURCE[0]}")/telegram-format.sh"

MONITOR_UA="simparty-monitor/1.0 (+GitHub Actions; thebluepigu/simparty-monitor)"
TG_FAILED=0

# KST 현재 시각 "YYYY-MM-DD HH:MM" (러너 tzdata 의존 없이 UTC+9 계산)
kst_now() { date -u -d '+9 hours' '+%Y-%m-%d %H:%M'; }

# 감시 자체 실패 사유 기록 → 워크플로의 if: failure() 스텝이 텔레그램에 첨부
note_fail() { printf '%s\n' "$*" >> "${RUNNER_TEMP:-/tmp}/monitor_fail_reason"; }

# 텔레그램 POST 1회. $1 text, $2 parse_mode(빈 값 = plain), $3 응답 파일, $4 stderr 파일 → HTTP 코드 출력.
# 테스트는 이 함수만 바꿔 끼워 네트워크 없이 tg_send 의 재전송 로직을 검증한다(tests/telegram-format.test.sh).
_tg_post() {
  local text="$1" pm="$2" resp="$3" err="$4"
  local -a pmopt=()
  if [ -n "$pm" ]; then pmopt=(--data-urlencode "parse_mode=${pm}"); fi
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"
' "$TELEGRAM_BOT_TOKEN"     | curl -sS -K - -X POST --max-time 20 -o "$resp" -w '%{http_code}'         --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}"         --data-urlencode "text=${text}"         "${pmopt[@]}"         --data-urlencode 'link_preview_options={"is_disabled":true}' 2>"$err" || echo "000"
}

# 텔레그램 전송 (parse_mode=HTML — 본문은 telegram-format.sh 가 만든다).
# 실패해도 호출부를 죽이지 않도록 반환값만 준다 (호출부: tg_send "..." || true).
# HTML 파싱 실패(400 "can't parse entities" — 템플릿 태그 짝 오류·미이스케이프 값)면 태그를 벗긴 plain 으로 1회 재전송.
# 실패 시 TG_FAILED=1 → 스크립트 마지막에 job 을 실패로 표시해 GitHub 실패 메일이라도 가게 한다.
tg_send() {
  local text="$1" resp err http ok desc migrate pm="HTML"
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "::warning::TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID 비어 있음 — 텔레그램 전송 생략"
    TG_FAILED=1; return 1
  fi
  # sendMessage 한도 4096자(엔티티 파싱 후). HTML 을 중간에서 자르면 태그가 깨지므로 넘치면 plain 으로 바꿔 자른다
  if [ "${#text}" -gt 4000 ]; then text="$(html_to_plain "$text")"; text="${text:0:4000}"; pm=""; fi
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
      printf '%s
' "${line//"$TELEGRAM_BOT_TOKEN"/***}"; n=$((n + 1))
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
