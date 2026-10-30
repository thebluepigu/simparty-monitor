#!/usr/bin/env bash
# 정기 실행 중복 확인 (Cloudflare 예약 실행기 대비책). 사용: schedule-gate.sh uptime|brief
# 출력: GITHUB_OUTPUT 에 run=1(진행) | run=0(이번 run 은 건너뜀 — 뒤 스텝 전부 skipped, run 은 success 로 끝남)
#
# 입력 env: EVENT(github.event_name) SOURCE(inputs.source — 'cf' = Worker, 그 외 = 사람) SCHEDULER(vars.SCHEDULER, 없으면 github)
#           RUN_ID GH_REPO GH_TOKEN, 선택: CF_ALIVE_WINDOW_SEC(1200) NOW_EPOCH(테스트용)
#
# 배경: 주 경로 = Cloudflare Worker(scheduler/)가 정시에 workflow_dispatch(source=cf)를 보낸다.
#       GitHub `schedule:` 은 지우지 않고 대비책으로 남긴다 — Worker·토큰이 죽어도 감시가 끊기지 않게.
#
#   SCHEDULER 없음/github (기본 — 지금 운영): schedule run 은 언제나 진행 = 오늘과 똑같다(gh 호출도 안 함).
#   SCHEDULER=cloudflare:
#     uptime: schedule run 은 최근 CF_ALIVE_WINDOW_SEC(20분) 안에 Worker 가 보낸 uptime run(run-name '· cf ·')이 하나라도 있으면
#             건너뛴다. 취소·기동 실패·skipped 로 끝난 Worker run 은 세지 않는다(진행 중 run 은 셈). 종류(quick/full)는 따지지
#             않는다 — Worker 가 살아 있으면 그 슬롯은 이미 Worker run 이 모드 결정(FULL_EVERY_HOURS 주기 포함)을 거쳤다.
#             없으면 진행 = 대비책. Worker 는 10분마다 보내므로 20분 = 한 번 놓쳐도 살아 있다고 본다.
#     brief : schedule run 은 오늘(KST) 다른 정기 브리프(schedule 또는 cf)가 이미 "보냄" 이면 건너뛴다.
#             보냄 = '브리프 전송 표식' 스텝 success(neon-usage.sh 가 텔레그램 전송 성공 시 sent=1 — 템플릿 고장으로 plain 폴백을
#             보낸 뒤 job 이 실패로 끝나도 보냄) 또는 브리프 스텝 success(표식 도입 전 run 호환). 전송 실패 run 은 보냄이 아니라 재시도.
#   Worker run(source=cf)의 brief 는 SCHEDULER 와 무관하게 같은 규칙으로 확인한다 — GitHub schedule 이 정시에 와서 먼저
#     보냈으면 Worker 쪽이 건너뛴다(neon-usage concurrency 그룹이 두 run 을 직렬화하므로 뒤에 도는 쪽이 앞의 결과를 본다).
#   사람이 손으로 돌린 run(source≠cf: test-alert·preview·normal·quick·full)은 언제나 진행하고, 남의 run 을 건너뛰게 하지도 않는다.
#   SCHEDULER 가 github·cloudflare 가 아닌 값(오타 'cloudfare' 등)이면 ::warning:: 을 남기고 github 으로 취급한다(= 지금 동작).
#
# 🔴 fail-open: gh 조회가 실패하면 진행(run=1). 감시가 빠지는 것보다 한 번 더 도는 게 낫다 —
#   uptime 은 concurrency 그룹 'uptime' 이 직렬화하고 장애 알림은 이슈 본문 마커(alerted·tg-sent 6h)로 막혀 두 번 알리지 않으며,
#   DB 체크는 uptime-mode.sh 의 45분 가드가 막는다. brief 는 최악이 "그날 브리프 2통"이다.
# ⚠️ BRIEF_STEP·SENT_STEP 은 neon-usage.yml 의 스텝 이름과, '· cf ·'(uptime)·'· cf'(brief) 는 두 워크플로의 run-name 과 같아야 한다.
set -uo pipefail

KIND="${1:-}"
EVENT="${EVENT:-}"; SOURCE="${SOURCE:-}"; RUN_ID="${RUN_ID:-0}"
SCHEDULER_RAW="${SCHEDULER:-}"
SCHEDULER="$(printf '%s' "${SCHEDULER:-github}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
case "$SCHEDULER" in
  ''|github|cloudflare) [ -n "$SCHEDULER" ] || SCHEDULER=github ;;
  *) echo "::warning::repo 변수 SCHEDULER='${SCHEDULER_RAW}' 를 알 수 없음(github|cloudflare) — github 으로 취급. 오타면 Worker 와 GitHub schedule 이 둘 다 돈다"
     SCHEDULER=github ;;
esac
WINDOW="${CF_ALIVE_WINDOW_SEC:-1200}"
NOW="${NOW_EPOCH:-$(date -u +%s)}"
BRIEF_STEP='Neon 사용량 조회 + 텔레그램 브리프'
SENT_STEP='브리프 전송 표식'
case "$RUN_ID" in ''|*[!0-9]*) RUN_ID=0 ;; esac
case "$WINDOW" in ''|*[!0-9]*) WINDOW=1200 ;; esac

# 대비책 표식 — SCHEDULER=cloudflare 인데 이 schedule run 이 Worker 대신 체크한다(Worker 멈춤·조회 실패). uptime.yml 이 이 값을 보고
#   알림 템플릿에 SCHEDULER=github 를 넘긴다: 실제 주기가 GitHub cron(몇 시간)이라 '약 10분 간격' 이라고 말하면 틀리기 때문
fallback() { echo "fallback=1" >> "${GITHUB_OUTPUT:-/dev/null}"; }
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
    if ! recent="$(gh run list --workflow uptime.yml --event workflow_dispatch --limit 20 --json databaseId,displayTitle,createdAt,status,conclusion 2>/dev/null \
        | jq -r --argjson me "$RUN_ID" --argjson now "$NOW" --argjson w "$WINDOW" \
            '[.[] | select(.databaseId != $me) | select((.displayTitle // "") | contains("· cf ·"))
                  | select((.conclusion // "") | IN("cancelled", "startup_failure", "skipped") | not)
                  | select(($now - (.createdAt | fromdateiso8601)) < $w)] | length' | tr -d '\r')"; then
      echo "::warning::Worker 실행 조회 실패 — 대비책으로 진행 (fail-open)"; fallback; out 1 "조회 실패 → 진행"
    fi
    case "$recent" in ''|*[!0-9]*) echo "::warning::Worker 실행 조회 결과 해석 불가 — 대비책으로 진행"; fallback; out 1 "조회 실패 → 진행" ;; esac
    if [ "$recent" -gt 0 ]; then out 0 "최근 $((WINDOW / 60))분 안에 Cloudflare Worker 가 보낸 uptime run ${recent}건 — Worker 정상"; fi
    echo "::warning::최근 $((WINDOW / 60))분 안에 Cloudflare Worker 의 uptime run 이 없음 — GitHub schedule 이 대비책으로 실행 (Worker·토큰 확인 필요)"
    fallback; out 1 "Worker 실행 없음 → 대비책"
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
        | jq -r --arg s "$BRIEF_STEP" --arg m "$SENT_STEP" \
            '[.jobs[]?.steps[]? | select((.name == $s or .name == $m) and .conclusion == "success")] | length' 2>/dev/null | tr -d '\r' || true)"
      case "$sent" in ''|*[!0-9]*) echo "::warning::run $id 스텝 조회 실패 — 무시하고 계속" ; continue ;; esac
      if [ "$sent" -gt 0 ]; then out 0 "오늘(KST $today) 정기 브리프를 이미 보낸 run($id) 있음 — 하루 1통"; fi
    done <<< "$cands"
    out 1 "오늘(KST $today) 보낸 정기 브리프 없음"
    ;;
  *) echo "사용: schedule-gate.sh uptime|brief"; echo "run=1" >> "${GITHUB_OUTPUT:-/dev/null}"; exit 0 ;;
esac
