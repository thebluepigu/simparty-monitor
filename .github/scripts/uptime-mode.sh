#!/usr/bin/env bash
# uptime.yml '모드 결정' 스텝 본체. 출력: GITHUB_OUTPUT 에 mode=quick|full|test-alert
#
# 입력 env: EVENT(github.event_name) SCHED(github.event.schedule) INPUT_MODE RUN_ID RUN_ATTEMPT GH_REPO GH_TOKEN
#
# 🔴 DB 경유(full) 는 "영업시간(UTC 02~14시)·시간당 1회" 를 cron 에만 맡기지 않고 여기서 강제한다. fail-safe = quick.
#   1) UTC 02~14시 밖이면(스케줄 지연 포함) quick
#   2) 재실행(run_attempt>1)이면 quick — 1차 시도가 이미 DB 를 건드렸다
#   3) 스케줄·수동 구분 없이, 최근 45분 안에 **실제로 DB 체크를 실행한** 다른 run 이 있으면 quick
#      - 창을 55→45분으로 줄인 이유: 스케줄 지연 편차(예: 직전 full 13분 지연·이번 2분 지연 = 간격 49분)로 정상 full 이
#        강등돼 DB 체크가 2시간에 1번이 되는 것 방지. 45분 간격 DB 접근 2회도 5분 autosuspend 와 무관(각각 5분 뒤 잠듦).
#      - run-name(displayTitle)은 "의도"만 담는다(강등돼도 '· full'). 그래서 후보를 displayTitle 로 좁힌 뒤
#        각 run 의 스텝 FULL_MARKER_STEP 이 success 였는지(= 그 run 이 DB 를 실제로 건드렸는지)로 확정한다.
#        강등된 run 은 그 스텝이 skipped 라 세지 않는다 → 강등이 다음 시간 슬롯을 연쇄로 막지 않는다.
#      - 재실행된 run(attempt>1)은 "DB 건드림"으로 간주 — gh run view --json jobs 는 **최신 attempt** 의 job 만 보여 줘서,
#        1차 시도가 DB 를 건드린 뒤 재실행(강등 → 표식 skipped)된 run 을 "안 건드림"으로 오판하기 때문 (보수적 = fail-safe)
#      - gh 조회 실패 → quick
#
# ⚠️ FULL_CRON 은 uptime.yml 의 on.schedule(full 줄)·run-name 과 문자열이 같아야 한다(3곳 동기).
#    어긋나면 full 이 영영 안 돈다 → neon-usage 브리프의 "DB체크(full) 마지막 성공" heartbeat 가 ⚠️ 로 드러낸다.
#    QUICK_CRONS 는 on.schedule 의 quick 2줄과 같아야 한다(어긋나면 "알 수 없는 schedule" 경고 + quick 동작).
set -euo pipefail

FULL_CRON='4 2-14 * * *'
QUICK_CRONS=('14,24,34,44,54 * * * *' '4 0-1,15-23 * * *')   # uptime.yml on.schedule 의 quick 2줄과 동기 (10분 주기)
FULL_MARKER_STEP='DB 경유(full) 실행 표식'
WINDOW_SEC="${FULL_WINDOW_SEC:-2700}"   # 45분

EVENT="${EVENT:-}"; SCHED="${SCHED:-}"; RUN_ID="${RUN_ID:-0}"; RUN_ATTEMPT="${RUN_ATTEMPT:-1}"
out() { echo "event=$EVENT schedule='$SCHED' attempt=$RUN_ATTEMPT → mode=$1"; echo "mode=$1" >> "${GITHUB_OUTPUT:-/dev/null}"; exit 0; }

case "$EVENT" in
  schedule)
    if [ "$SCHED" = "$FULL_CRON" ]; then MODE=full
    else
      MODE=quick; known=0
      for q in "${QUICK_CRONS[@]}"; do [ "$SCHED" = "$q" ] && known=1; done
      if [ "$known" = "0" ]; then
        echo "::warning::알 수 없는 schedule '$SCHED' — uptime.yml 의 cron 과 uptime-mode.sh 의 FULL_CRON/QUICK_CRONS 동기 확인 필요 (quick 으로 진행)"
      fi
    fi ;;
  workflow_dispatch) MODE="${INPUT_MODE:-quick}" ;;
  *) MODE=quick ;;
esac

[ "$MODE" = "full" ] || out "$MODE"

H=$((10#$(date -u +%H)))
if [ "$H" -lt 2 ] || [ "$H" -gt 14 ]; then
  echo "::notice::UTC ${H}시 = 영업시간(UTC 02~14시) 밖 → full 을 quick 으로 강등 (Neon 보호)"; out quick
fi
if [ "$RUN_ATTEMPT" != "1" ]; then
  echo "::notice::재실행(attempt ${RUN_ATTEMPT}) → 1차 시도가 이미 DB 를 건드렸으므로 quick 으로 강등"; out quick
fi

# 최근 45분 안의 full "의도" run 후보 (자기 자신 제외). 한 줄에 "<id> <attempt>"
if ! CANDS="$(gh run list --workflow uptime.yml --limit 20 --json databaseId,displayTitle,createdAt,attempt 2>/dev/null \
    | jq -r --argjson me "$RUN_ID" --argjson w "$WINDOW_SEC" \
        '.[] | select(.databaseId != $me) | select((.displayTitle // "") | endswith("· full"))
         | select((now - (.createdAt | fromdateiso8601)) < $w) | "\(.databaseId) \(.attempt // 1)"')"; then
  echo "::notice::최근 실행 조회 실패 → 안전하게 quick 으로 강등"; out quick
fi
while read -r id att; do
  [ -n "$id" ] || continue
  if [ "$att" != "1" ]; then
    echo "::notice::최근 45분 안의 full run($id)이 재실행됨(attempt ${att}) — 1차 시도의 DB 접근을 확인할 수 없어 건드린 것으로 간주 → quick 으로 강등"; out quick
  fi
  if ! did="$(gh run view "$id" --json jobs 2>/dev/null < /dev/null \
      | jq -r --arg s "$FULL_MARKER_STEP" '[.jobs[]?.steps[]? | select(.name == $s and .conclusion == "success")] | length')"; then
    echo "::notice::run $id 스텝 조회 실패 → 안전하게 quick 으로 강등"; out quick
  fi
  if [ "$did" != "0" ]; then
    echo "::notice::최근 45분 안에 DB 체크를 실제 실행한 run($id) 있음 → quick 으로 강등 (DB 체크 시간당 1회)"; out quick
  fi
done <<< "$CANDS"
out full
