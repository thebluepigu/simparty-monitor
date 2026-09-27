# shellcheck shell=bash
# 감시 워크플로(uptime.yml / neon-usage.yml) 공통 함수. source 해서 쓴다.
#
# 보안 규칙: set -x 금지, curl -v 금지, 토큰 echo 금지.
# 텔레그램 토큰은 argv 에 올리지 않고 curl 설정을 stdin(-K -)으로 넘긴다
# (GitHub 로그 마스킹에 더해 프로세스 목록 노출도 피함).

MONITOR_UA="simparty-monitor/1.0 (+GitHub Actions; thebluepigu/simparty-monitor)"
TG_FAILED=0

# KST 현재 시각 "YYYY-MM-DD HH:MM" (러너 tzdata 의존 없이 UTC+9 계산)
kst_now() { date -u -d '+9 hours' '+%Y-%m-%d %H:%M'; }

# 감시 자체 실패 사유 기록 → 워크플로의 if: failure() 스텝이 텔레그램에 첨부
note_fail() { printf '%s\n' "$*" >> "${RUNNER_TEMP:-/tmp}/monitor_fail_reason"; }

# 텔레그램 전송. 실패해도 호출부를 죽이지 않도록 반환값만 준다 (호출부: tg_send "..." || true).
# 실패 시 TG_FAILED=1 → 스크립트 마지막에 job 을 실패로 표시해 GitHub 실패 메일이라도 가게 한다.
tg_send() {
  local text="$1" resp err http ok desc migrate
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "::warning::TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID 비어 있음 — 텔레그램 전송 생략"
    TG_FAILED=1; return 1
  fi
  text="${text:0:4000}"   # sendMessage 한도 4096자, 여유 두고 자름
  resp="$(mktemp)"; err="$(mktemp)"
  http="$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" \
    | curl -sS -K - -X POST --max-time 20 -o "$resp" -w '%{http_code}' \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data-urlencode 'link_preview_options={"is_disabled":true}' 2>"$err")" || http="000"
  ok="$(jq -r '.ok // false' "$resp" 2>/dev/null || echo false)"
  if [ "$ok" = "true" ]; then
    rm -f "$resp" "$err"; return 0
  fi
  desc="$(jq -r '.description // empty' "$resp" 2>/dev/null || true)"
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
