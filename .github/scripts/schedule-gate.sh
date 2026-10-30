#!/usr/bin/env bash
# 정기 실행 중복 확인 (Cloudflare 예약 실행기 대비책). 사용: schedule-gate.sh uptime|brief
# 출력: GITHUB_OUTPUT 에 run=1(진행) | run=0(이번 run 은 건너뜀 — 뒤 스텝 전부 skipped, run 은 success 로 끝남)
#
# 입력 env: EVENT(github.event_name) SOURCE(inputs.source — 'cf' = Worker, 그 외 = 사람) SCHEDULER(vars.SCHEDULER, 없으면 github)
#           RUN_ID GH_REPO GH_TOKEN, 선택: CF_ALIVE_WINDOW_SEC(1200) NOW_EPOCH(테스트용)
#
# 배경: 주 경로 = Cloudflare Worker(scheduler/worker.js)가 정시에 workflow_dispatch(source=cf)를 보낸다.
#       GitHub `schedule:` 은 지우지 않고 대비책으로 남긴다 — Worker·토큰이 죽어도 감시가 끊기지 않게.
#
#   SCHEDULER 없음/github (기본 — 지금 운영): schedule run 은 언제나 진행 = 오늘과 똑같다(gh 호출도 안 함).
#   SCHEDULER=cloudflare:
#     uptime: schedule run 은 최근 CF_ALIVE_WINDOW_SEC(20분) 안에 Worker 가 보낸 uptime run(run-name '· cf ·')이 하나라도 있으면
#             건너뛴다. 종류(quick/full)는 따지지 않는다 — Worker 가 살아 있으면 full 여부도 Worker(FULL_EVERY_HOURS)가 정한 것이다.
#             (full 슬롯이라고 GitHub 가 따로 full 을 돌리면 FULL_EVERY_HOURS 로 줄인 DB 접근이 되살아난다.)
#             없으면 진행 = 대비책. Worker 는 10분마다 보내므로 20분 = 한 번 놓쳐도 살아 있다고 본다.
#     brief : schedule run 은 오늘(KST) 다른 정기 브리프(schedule 또는 cf)가 이미 '브리프 스텝 success' 면 건너뛴다.
#   Worker run(source=cf)의 brief 는 SCHEDULER 와 무관하게 같은 규칙으로 확인한다 — GitHub schedule 이 정시에 와서 먼저
#     보냈으면 Worker 쪽이 건너뛴다(neon-usage concurrency 그룹이 두 run 을 직렬화하므로 뒤에 도는 쪽이 앞의 결과를 본다).
#   사람이 손으로 돌린 run(source≠cf: test-alert·preview·normal·quick·full)은 언제나 진행하고, 남의 run 을 건너뛰게 하지도 않는다.
#
# 🔴 fail-open: gh 조회가 실패하면 진행(run=1). 감시가 빠지는 것보다 한 번 더 도는 게 낫다 —
#   uptime 은 concurrency 그룹 'uptime' 이 직렬화하고 장애 알림은 이슈 본문 마커(alerted·tg-sent 6h)로 막혀 두 번 알리지 않으며,
#   DB 체크는 uptime-mode.sh 의 45분 가드가 막는다. brief 는 최악이 "그날 브리프 2통"이다.
# ⚠️ BRIEF_STEP 은 neon-usage.yml 의 브리프 스텝 이름과, '· cf ·'(uptime)·'· cf'(brief) 는 두 워크플로의 run-name 과 같아야 한다.
set -uo pipefail

KIND="${1:-}"
EVENT="${EVENT:-}"; SOURCE="${SOURCE:-}"; RUN_ID="${RUN_ID:-0}"
SCHEDULER="$(printf '%s' "${SCHEDULER:-github}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
[ -n "$SCHEDULER" ] || SCHEDULER=github
WINDOW="${CF_ALIVE_WINDOW_SEC:-1200}"
NOW="${NOW_EPOCH:-$(date -u +%s)}"
BRIEF_STEP='Neon 사용량 조회 + 텔레그램 브리프'
case "$RUN_ID" in ''|*[!0-9]*) RUN_ID=0 ;; esac
case "$WINDOW" in ''|*[!0-9]*) WINDOW=1200 ;; esac

out() {  # $1 run=0|1, $2 사유
  echo "kind=$KIND event=$EVENT source=${SOURCE:-} scheduler=$SCHEDULER → run=$1 ($2)"
  if [ "$1" = "0" ]; then echo "::notice::이번 run 은 건너뜀 — $2"; fi
  echo "run=$1" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
}

case "$KIND" in
  uptime)
    [ "$EVENT" = "schedule" ] || out 1 "schedule 이 아님(수동·Worker run 은 항상 진행)"
    [ "$SCHEDULER" = "cloudflare" ] || out 1 "SCHEDULER=$SCHEDULER — GitHub schedule 이 주 경로"
    if ! recent="$(gh run list --workflow uptime.yml --event workflow_dispatch --limit 20 --json databaseId,displayTitle,createdAt 2>/dev/null \
        | jq -r --argjson me "$RUN_ID" --argjson now "$NOW" --argjson w "$WINDOW" \
            '[.[] | select(.databaseId != $me) | select((.displayTitle // "") | contains("· cf ·"))
                  | select(($now - (.createdAt | fromdateiso8601)) < $w)] | length')"; then
      echo "::warning::Worker 실행 조회 실패 — 대비책으로 진행 (fail-open)"; out 1 "조회 실패 → 진행"
    fi
    case "$recent" in ''|*[!0-9]*) echo "::warning::Worker 실행 조회 결과 해석 불가 — 대비책으로 진행"; out 1 "조회 실패 → 진행" ;; esac
    if [ "$recent" -gt 0 ]; then out 0 "최근 $((WINDOW / 60))분 안에 Cloudflare Worker 가 보낸 uptime run ${recent}건 — Worker 정상"; fi
    echo "::warning::최근 $((WINDOW / 60))분 안에 Cloudflare Worker 의 uptime run 이 없음 — GitHub schedule 이 대비책으로 실행 (Worker·토큰 확인 필요)"
    out 1 "Worker 실행 없음 → 대비책"
    ;;
  brief)
    if [ "$EVENT" = "schedule" ]; then
      [ "$SCHEDULER" = "cloudflare" ] || out 1 "SCHEDULER=$SCHEDULER — GitHub schedule 이 주 경로"
    elif [ "$EVENT" = "workflow_dispatch" ] && [ "$SOURCE" = "cf" ]; then :
    else out 1 "수동 실행(source=${SOURCE:-manual}) — 항상 진행"
    fi
    today="$(TZ=Asia/Seoul date -d "@$NOW" +%F 2>/dev/null || date -u +%F)"
    if ! cands="$(gh run list --workflow neon-usage.yml --limit 20 --json databaseId,event,displayTitle,createdAt 2>/dev/null \
        | jq -r --argjson me "$RUN_ID" --arg today "$today" \
            '.[] | select(.databaseId != $me)
                 | select(.event == "schedule" or (.event == "workflow_dispatch" and ((.displayTitle // "") | endswith("· cf"))))
                 | select(((.createdAt | fromdateiso8601) + 32400 | strftime("%Y-%m-%d")) == $today)
                 | .databaseId' | tr -d '\r')"; then
      echo "::warning::오늘 브리프 실행 조회 실패 — 진행 (fail-open, 최악 = 브리프 2통)"; out 1 "조회 실패 → 진행"
    fi
    while read -r id; do
      [ -n "$id" ] || continue
      sent="$(gh run view "$id" --json jobs 2>/dev/null < /dev/null \
        | jq -r --arg s "$BRIEF_STEP" '[.jobs[]?.steps[]? | select(.name == $s and .conclusion == "success")] | length' 2>/dev/null || true)"
      case "$sent" in ''|*[!0-9]*) echo "::warning::run $id 스텝 조회 실패 — 무시하고 계속" ; continue ;; esac
      if [ "$sent" -gt 0 ]; then out 0 "오늘(KST $today) 정기 브리프를 이미 보낸 run($id) 있음 — 하루 1통"; fi
    done <<< "$cands"
    out 1 "오늘(KST $today) 보낸 정기 브리프 없음"
    ;;
  *) echo "사용: schedule-gate.sh uptime|brief"; echo "run=1" >> "${GITHUB_OUTPUT:-/dev/null}"; exit 0 ;;
esac
