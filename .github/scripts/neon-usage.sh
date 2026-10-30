#!/usr/bin/env bash
# Neon 사용량 일일 브리프. 사용: neon-usage.sh
#
# 입력 env:
#   NEON_API_KEY (필수, secret) · NEON_PROJECT_ID (옵션, 없으면 이름 'simparty' 로 검색)
#   NEON_CU_HOUR_USD (기본 0.106) · NEON_STORAGE_GB_USD (기본 0.35) · NEON_BUDGET_USD (기본 15)
#   NEON_BUDGET_WARN_PCT (기본 80) — 기간 말 예상 비용이 예산의 이 % 이상이면 🟡 "예산의 80%를 넘을 것 같아요" (0 = 끔).
#     예산 초과(> 100%)는 따로 🟡 "예산을 넘을 것 같아요"
#   STATE_DIR (직전 실행 상태 파일 위치, 기본 ./.monitor-state) — 워크플로가 actions/cache 로 복원/저장
#   NEON_FIXTURE_DIR (테스트 전용: 지정 시 API 호출 대신 이 폴더의 JSON 사용)
#   NOW_EPOCH (테스트 전용: 현재 시각 고정)
#   NEON_MIN_CU (기본 0.25 — autoscaling 최소 CU, 시간별 상시가동 판정 기준)
#   UPTIME_LAST_SUCCESS (옵션, ISO — uptime.yml 마지막 성공 실행 시각. 워크플로가 gh run list 로 넣어 줌)
#   UPTIME_LAST_FULL (옵션, ISO — uptime.yml 이 DB 경유(full) 체크를 실제로 마친 마지막 시각)
#   HB_UPTIME_MAX_H (기본 6) · HB_FULL_MAX_H (기본 36) — 이 시간을 넘겨야 heartbeat 🟡 (uptime 은 확인 불가여도 🟡).
#     예전 2h/14h 는 GitHub cron 드롭(실측 간격 최대 ~3h) 때문에 매일 경보(옛 ⚠️)라 경보를 희석했고, 12h 는 밤사이 멈춘 감시를
#     놓쳤다 → uptime 6h (2026-10-13)
#   SITE_FRESH_H (기본 3) — 브리프 ② 사이트 "🟢 정상" 은 uptime 마지막 성공이 이 시간 이내일 때만
#   UPTIME_RUNS_24H · UPTIME_FULL_24H · UPTIME_FULL_EXEC_24H (옵션, 최근 24h 정기 실행 수·full 의도 수·DB체크 실제 수 — 드롭 정도 표시)
#   UPTIME_DESIGN_RUNS (기본 144) · UPTIME_DESIGN_FULL (기본 13) — 설계상 하루 실행 수
#   RUNS_WARN_PCT (기본 0 = 끔) — 최근 24h 점검 횟수(전체·DB 점검 각각)가 예정의 이 % 미만이면 🟡.
#     GitHub 무료 cron 은 지연·드롭이 심해(실측 하루 5~13회 / 예정 144회) 켜면 매일 🟡 → 꺼 두고,
#     Cloudflare 예약 실행(SCHEDULER=cloudflare)으로 바꾼 뒤 켠다(예: 80)
#   SCHEDULER (github | cloudflare, 기본 github — 읽기만) — 브리프 끝 "다음 브리프" 안내 문구·드롭 설명 줄·사이트 🟡 기준을 고른다.
#     모르는 값이면 github 로 동작하고 ⑤ 감시 자체 🟡 (SCHEDULER_BAD=1 — hb 가 같은 판정을 내려 주기도 한다)
#   UPTIME_CF_STALE (1 = cloudflare 인데 최근 60분 Worker run 없음 → 🟡 "예약 실행기 멈춤") · UPTIME_CF_LAST(ISO)
#   UPTIME_CF_RUNS_24H · UPTIME_FALLBACK_RUNS_24H — 최근 24h 정기 실행 중 Worker / GitHub 대비책 수(cloudflare 모드에서 표시만)
# 출력: GITHUB_OUTPUT 에 sent=1 (텔레그램 전송 성공 시 — 템플릿 고장으로 job 이 실패해도 남긴다)
#   UPTIME_INCIDENT (옵션, JSON — 열린 장애 이슈 {"open":false} | {"open":true,"number","url","failed","since"}, 빈 값 = 확인 불가)
#   BRIEF_MODE (normal | preview) — preview 는 첫 줄에 "[미리보기] ", 상태(판정 기준점) 저장 안 함
#   REPO_LAST_COMMIT_EPOCH (옵션, epoch — 이 저장소 마지막 커밋 시각. 워크플로가 git log -1 로 넣어 줌)
#   REPO_IDLE_WARN_DAYS (기본 45 — 이 일수 이상이면 🟡. 공개 repo 는 60일 무활동 시 schedule 자동 비활성)
#
# 조회 순서 (Neon API v2, control plane — compute 를 깨우지 않음):
#   1) GET /projects?search=simparty → name=="simparty" 정확 일치 (못 찾거나 200 이 아니면 /users/me/organizations 의 org 로 재시도)
#   2) GET /projects/{id} → compute_time_seconds, active_time_seconds, data_transfer_bytes,
#      written_data_bytes, synthetic_storage_size, consumption_period_start/end, settings.quota
#   3) GET /consumption_history/v2/projects?metrics=compute_unit_seconds (요금 기준 CU초, Launch 이상·org_id 필수)
#      → 403/실패/빈 응답이면 compute_time_seconds/3600 을 근사치로 사용(브리프에 "근사치" 표기)
#   4) GET /projects/{id}/branches → 기본 브랜치 active_time_seconds (프로젝트 합계는 dev 브랜치·리플리카까지
#      더해져 가동률 100% 초과 오탐 → 판정은 기본 브랜치로 한정, 없으면 프로젝트 합계로 대체하고 문구에 명시)
#   5) 같은 v2 API 를 granularity=hourly 로 최근 24시간 → "그 시간 내내 켜져 있던 시간 수"
#      (CU초 ≥ 0.9 × NEON_MIN_CU × 3600). 직전값·캐시가 필요 없어 첫 실행에도 판정되고,
#      Launch 플랜에서 active_time_seconds 가 갱신되지 않아도 동작하는 두 번째 신호.
#
# autosuspend(DB 자동 절전) 판정: 아래 둘 중 하나라도 ≥ 90% 면 🔴
#   (a) 최근 24시간 중 상시가동 시간 비율 (v2 hourly, 프로젝트 합계)
#   (b) 직전 실행 대비 기본 브랜치 active_time_seconds 증가분 / 경과 시간 — 간격 NEON_DELTA_MIN_SEC(20h) 이상일 때만.
#       짧은 창(수동 실행)은 영업시간 가동만 잡혀 정상도 90%+ 로 보이므로 생략하고, 기준점도 덮지 않는다.
# 기간말 예상치: CU 를 v2 에서 가져왔으면 경과일·전체일도 그 v2 period 의 시작/끝으로 계산 (기간 중 플랜 변경 대응)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=monitor-lib.sh
source "$HERE/monitor-lib.sh"

API="https://console.neon.tech/api/v2"
PROJECT_NAME="${NEON_PROJECT_NAME:-simparty}"
CU_RATE="${NEON_CU_HOUR_USD:-0.106}"
ST_RATE="${NEON_STORAGE_GB_USD:-0.35}"
BUDGET="${NEON_BUDGET_USD:-15}"
BUDGET_WARN_PCT="${NEON_BUDGET_WARN_PCT:-80}"   # 기간 말 예상 비용 ≥ 예산의 이 % → 🟡 (0 = 끔). 숫자 검사는 §5
MIN_CU="${NEON_MIN_CU:-0.25}"
DELTA_MIN_SEC="${NEON_DELTA_MIN_SEC:-72000}"   # 직전값 대비 판정 최소 간격 20시간 (짧으면 낮 시간대만 잡혀 오탐)
STATE_DIR="${STATE_DIR:-.monitor-state}"
STATE="$STATE_DIR/neon-state.json"
RUN_URL="${RUN_URL:-local}"
NOW="${NOW_EPOCH:-$(date -u +%s)}"
WORK="$(mktemp -d)"
mkdir -p "$STATE_DIR"

# $1 path(쿼리 포함), $2 out file → HTTP 코드 출력. 5xx/네트워크 오류는 1회 재시도.
neon_get() {
  local path="$1" out="$2" code attempt
  if [ -n "${NEON_FIXTURE_DIR:-}" ]; then
    local f
    case "$path" in
      projects\?*org_id=*)       f=projects_org.json ;;
      projects\?*)                f=projects.json ;;
      users/me/organizations*)    f=orgs.json ;;
      consumption_history/*granularity=hourly*) f=consumption_hourly.json ;;
      consumption_history/*)      f=consumption.json ;;
      projects/*/branches*)       f=branches.json ;;
      projects/*)                 f=project.json ;;
      *)                          f=__none__ ;;
    esac
    if [ -f "$NEON_FIXTURE_DIR/$f" ]; then cp "$NEON_FIXTURE_DIR/$f" "$out"; echo 200; else echo 404; fi
    return 0
  fi
  for attempt in 1 2; do
    code="$(printf 'header = "Authorization: Bearer %s"\n' "$NEON_API_KEY" \
      | curl -sS -K - -H 'Accept: application/json' --max-time 30 -o "$out" -w '%{http_code}' "$API/$path" 2>/dev/null)" || code="000"
    case "$code" in 5*|000) [ "$attempt" = "1" ] && sleep 5 ;; *) break ;; esac
  done
  echo "$code"
}

die() { echo "::error::$*"; note_fail "$*"; exit 1; }

if [ -z "${NEON_FIXTURE_DIR:-}" ] && [ -z "${NEON_API_KEY:-}" ]; then die "NEON_API_KEY 비어 있음"; fi

# ---- 1) 프로젝트 id ----------------------------------------------------------
PID="${NEON_PROJECT_ID:-}"
ORG_ID=""
if [ -z "$PID" ]; then
  # 개인 API 키는 org_id 없이 /projects 를 부르면 200 이 아니라 오류를 줄 수 있다(조직 키만 org 추론) →
  # 200 이 아니어도 죽지 말고 조직 목록으로 재시도, 둘 다 실패할 때만 die.
  C_LIST="$(neon_get "projects?search=${PROJECT_NAME}&limit=400" "$WORK/projects.json")"
  if [ "$C_LIST" = "200" ]; then
    PID="$(jq -r --arg n "$PROJECT_NAME" '[(.projects // [])[] | select(.name == $n)] | .[0].id // empty' "$WORK/projects.json" 2>/dev/null || true)"
  else
    echo "프로젝트 목록(org 미지정) HTTP ${C_LIST} — 조직 목록으로 재시도"
  fi
  C_ORGS="-"
  if [ -z "$PID" ]; then
    C_ORGS="$(neon_get "users/me/organizations" "$WORK/orgs.json")"
    if [ "$C_ORGS" = "200" ]; then
      for org in $(jq -r '(.organizations // [])[].id' "$WORK/orgs.json" 2>/dev/null || true); do
        c="$(neon_get "projects?search=${PROJECT_NAME}&limit=400&org_id=${org}" "$WORK/projects.json")"
        [ "$c" = "200" ] || continue
        PID="$(jq -r --arg n "$PROJECT_NAME" '[(.projects // [])[] | select(.name == $n)] | .[0].id // empty' "$WORK/projects.json" 2>/dev/null || true)"
        if [ -n "$PID" ]; then ORG_ID="$org"; break; fi
      done
    fi
  fi
  [ -n "$PID" ] || die "Neon 프로젝트 '$PROJECT_NAME' 를 찾지 못함 (목록 HTTP ${C_LIST}, 조직 HTTP ${C_ORGS}) — API 키 확인 또는 vars.NEON_PROJECT_ID 지정"
fi

# 공개 repo: run 로그·step summary 가 공개되므로 Neon 프로젝트/조직 id 는 마스킹 (report JSON·오류 문구에 찍힘)
echo "::add-mask::${PID}"

# ---- 2) 프로젝트 상세 --------------------------------------------------------
c="$(neon_get "projects/${PID}" "$WORK/project.json")"
[ "$c" = "200" ] || die "Neon 프로젝트 상세 조회 실패 (HTTP $c, id=$PID)"
jq -e '.project' "$WORK/project.json" >/dev/null 2>&1 || die "Neon 프로젝트 상세 응답 형식 오류"

PSTART="$(jq -r '.project.consumption_period_start // empty' "$WORK/project.json")"
PEND="$(jq -r '.project.consumption_period_end // empty' "$WORK/project.json")"
[ -n "$ORG_ID" ] || ORG_ID="$(jq -r '.project.org_id // empty' "$WORK/project.json")"
[ -z "$ORG_ID" ] || echo "::add-mask::${ORG_ID}"
if [ -z "$PSTART" ]; then
  # 결제기간 정보가 없으면 이번 달 1일 UTC 로 가정
  PSTART="$(date -u -d "@$NOW" '+%Y-%m-01T00:00:00Z')"
  PERIOD_NOTE="(기간 정보 없음 — 월초 가정)"
else
  PERIOD_NOTE=""
fi
if [ -z "$PEND" ]; then
  # "+1 month" 는 08-31 → 10-01 로 넘친다 → 다음 달 같은 날, 없으면 그 달 말일로 클램프
  P_YM="$(date -u -d "$PSTART" '+%Y-%m')"; P_D="$(date -u -d "$PSTART" '+%d')"; P_T="$(date -u -d "$PSTART" '+%H:%M:%S')"
  N_FIRST="$(date -u -d "${P_YM}-01 +1 month" '+%Y-%m-%d')"
  N_LAST="$(date -u -d "${N_FIRST} +1 month -1 day" '+%d')"
  P_DD=$((10#$P_D < 10#$N_LAST ? 10#$P_D : 10#$N_LAST))
  PEND="${N_FIRST%-01}-$(printf '%02d' "$P_DD")T${P_T}Z"
fi

# ---- 3) 요금 기준 CU초 (v2) --------------------------------------------------
CU_SRC="approx"
CU_SEC=""; V2_PSTART=""; V2_PEND=""
if [ -z "$ORG_ID" ] && [ -z "${NEON_FIXTURE_DIR:-}" ]; then
  c="$(neon_get "users/me/organizations" "$WORK/orgs.json")"
  if [ "$c" = "200" ]; then ORG_ID="$(jq -r '(.organizations // [])[0].id // empty' "$WORK/orgs.json")"; [ -z "$ORG_ID" ] || echo "::add-mask::${ORG_ID}"; fi
fi
if [ -n "$ORG_ID" ] || [ -n "${NEON_FIXTURE_DIR:-}" ]; then
  FROM="$(date -u -d "$PSTART" '+%Y-%m-%dT00:00:00Z')"
  TO="$(date -u -d "@$NOW" '+%Y-%m-%dT%H:00:00Z')"
  c="$(neon_get "consumption_history/v2/projects?from=${FROM}&to=${TO}&granularity=daily&org_id=${ORG_ID}&metrics=compute_unit_seconds&project_ids=${PID}" "$WORK/consumption.json")"
  if [ "$c" = "200" ]; then
    # 조회 시작을 기간 시작일 00:00 으로 내렸기 때문에 직전 결제기간(예: 업그레이드 전 Free) 꼬리가 섞일 수 있다
    # → period_start 가 가장 늦은(= 현재) 기간만 합산. period_start 필드가 없으면 배열의 마지막 기간(시간순).
    # 출력: "<CU초>|<period_start>|<period_end>" (탭은 IFS 공백이라 빈 필드가 합쳐져 구분자로 부적합) — 기간말 예상치의 경과일·전체일도 같은 period 로 계산해야 한다
    # (기간 중 플랜 업그레이드로 project 의 consumption_period_* 와 어긋나면 CU 는 짧은 기간인데 경과일은 긴 기간 → 과소 추정)
    CU_ROW="$(jq -r '[(.projects // [])[] | (.periods // [])[]] as $ps
                     | ([$ps[] | (.period_start // "")] | max // "") as $cur
                     | (if $cur != "" then [$ps[] | select((.period_start // "") == $cur)] else ($ps[-1:]) end) as $sel
                     | [$sel[] | (.consumption // [])[] | (.metrics // [])[]
                        | select(.metric_name == "compute_unit_seconds") | (.value // 0)]
                     | if length == 0 then empty
                       else "\(add)|\($sel[0].period_start // "")|\($sel[0].period_end // "")" end' "$WORK/consumption.json" 2>/dev/null || true)"
    if [ -n "$CU_ROW" ]; then
      IFS='|' read -r CU_SEC V2_PSTART V2_PEND <<< "$CU_ROW"
      CU_SRC="v2"
    fi
  else
    echo "consumption_history v2 사용 불가 (HTTP $c) — compute_time_seconds 근사치 사용"
  fi
else
  echo "org_id 미확보 — consumption_history v2 생략, compute_time_seconds 근사치 사용"
fi

# ---- 4) 기본 브랜치 active_time (판정 대상 한정) -----------------------------
BR_ACT=""
c="$(neon_get "projects/${PID}/branches" "$WORK/branches.json")"
if [ "$c" = "200" ]; then
  BR_ACT="$(jq -r '[(.branches // [])[] | select(.default == true or .primary == true)] | .[0].active_time_seconds // empty' \
    "$WORK/branches.json" 2>/dev/null || true)"
fi
[ -n "$BR_ACT" ] || echo "기본 브랜치 active_time_seconds 미확보 (HTTP $c) — 프로젝트 합계로 대체"

# ---- 5) 최근 24시간 시간별 CU초 (v2 hourly) -----------------------------------
HOURLY="null"
if [ -n "$ORG_ID" ] || [ -n "${NEON_FIXTURE_DIR:-}" ]; then
  H_TO="$(date -u -d "@$NOW" '+%Y-%m-%dT%H:00:00Z')"
  H_FROM="$(date -u -d "@$((NOW - 86400))" '+%Y-%m-%dT%H:00:00Z')"
  c="$(neon_get "consumption_history/v2/projects?from=${H_FROM}&to=${H_TO}&granularity=hourly&org_id=${ORG_ID}&metrics=compute_unit_seconds&project_ids=${PID}" "$WORK/consumption_hourly.json")"
  if [ "$c" = "200" ]; then
    HOURLY="$(jq -c --argjson min "$MIN_CU" '
      [(.projects // [])[] | (.periods // [])[] | (.consumption // [])[]
       | {t: (.timeframe_start // ""), v: ([(.metrics // [])[] | select(.metric_name == "compute_unit_seconds") | (.value // 0)] | add // 0)}]
      | group_by(.t) | map({t: .[0].t, v: (map(.v) | add)})
      # 시간 버킷이 하나도 없으면 "0/24 = 정상" 으로 읽지 않는다 (API 형식 변경·빈 응답과 종일 수면을 구분 못 함)
      | if length == 0 then {hours: 24, nodata: true, full_on: 0, max_cu_sec: 0}
        else {hours: 24, nodata: false, buckets: length, full_on: (map(select(.v >= 0.9 * $min * 3600)) | length), max_cu_sec: (map(.v) | max // 0)} end' \
      "$WORK/consumption_hourly.json" 2>/dev/null || echo null)"
    [ -n "$HOURLY" ] || HOURLY="null"
  else
    echo "consumption_history v2 hourly 사용 불가 (HTTP $c) — 시간별 판정 생략"
  fi
fi

PREV="null"
if [ -s "$STATE" ] && jq -e . "$STATE" >/dev/null 2>&1; then PREV="$(cat "$STATE")"; fi

# ---- 4) 계산 (전부 null 안전) -----------------------------------------------
jq -n \
  --slurpfile p "$WORK/project.json" \
  --argjson prev "$PREV" \
  --argjson now "$NOW" \
  --arg pstart "$PSTART" --arg pend "$PEND" \
  --arg cu_sec "$CU_SEC" --arg cu_src "$CU_SRC" \
  --arg vpstart "$V2_PSTART" --arg vpend "$V2_PEND" --argjson min_dt "$DELTA_MIN_SEC" \
  --arg br_act "$BR_ACT" --argjson hourly "$HOURLY" \
  --argjson cu_rate "$CU_RATE" --argjson st_rate "$ST_RATE" --argjson budget "$BUDGET" '
  def ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
  def r(n): (. * pow(10; n) | round) / pow(10; n);
  ($p[0].project) as $pr
  | ($pstart | ts) as $s | ($pend | ts) as $e
  # 예상치의 기간 = CU 를 합산한 기간. v2 면 선택한 period 의 시작/끝(끝이 없으면 project 끝, 그것도 시작 이전이면 +30일)
  | (if $cu_src == "v2" and $vpstart != "" then ($vpstart | ts) else $s end) as $cs
  | (if $cu_src == "v2" and $vpend != "" then ($vpend | ts) elif $e > $cs then $e else $cs + 30 * 86400 end) as $ce
  | (($now - $cs) / 86400) as $elapsed
  | ((($ce - $cs) / 86400) | if . <= 0 then 30 else . end) as $total
  | (if $cu_src == "v2" then ($cu_sec | tonumber) else ($pr.compute_time_seconds // 0) end) as $cus
  | ($cus / 3600) as $cuh
  # 기간 시작 1일 미만이면 외삽이 수천 배로 부풀어(예: 12분치 × 3,700) 매월 1일 예산 오경보 → 예상치 생략
  | (if $elapsed >= 1 then $cuh * $total / $elapsed else null end) as $proj_cuh
  | ((($pr.synthetic_storage_size // 0)) / 1e9) as $st_gb
  | (($pr.data_transfer_bytes // 0) / 1e9) as $tx_gb
  | (($pr.written_data_bytes // 0) / 1e9) as $wr_gb
  | (if $br_act != "" then {v: ($br_act | tonumber), src: "branch"}
     else {v: ($pr.active_time_seconds // null), src: "project"} end) as $actx
  | $actx.v as $act
  | (if $proj_cuh == null then null else $proj_cuh * $cu_rate + $st_gb * $st_rate end) as $cost
  # autosuspend 판정: 직전 실행 대비 active_time 증가분 / 경과 시간
  | (if $act == null then {state: "skip", why: "active_time_seconds 없음"}
     elif $prev == null then {state: "skip", why: "첫 실행 — 직전값 없음, 판정 생략"}
     elif ($prev.act_src // "project") != $actx.src then {state: "skip", why: "판정 대상 변경(\($prev.act_src // "project")→\($actx.src)) — 판정 생략"}
     elif ($prev.period_start // "") != $pstart then
        # 결제기간 전환으로 누적값 리셋 → 기간 시작 대비로 판정
        (($now - $s)) as $dt
        | if $dt < $min_dt then {state: "skip", why: "결제기간 전환 후 \($min_dt / 3600 | floor)시간 미만 — 판정 생략"}
          else {state: "judge", ratio: ($act / $dt), dt: $dt} end
     else
        # 창이 하루보다 짧으면 영업시간 가동만 잡혀 정상도 90%+ 로 보인다(수동 실행 오탐) → 최소 DELTA_MIN_SEC(20h)
        (($now - ($prev.ts // $now))) as $dt
        | if $dt < $min_dt then {state: "skip", keep_prev: true, why: "직전 실행과 간격 \($min_dt / 3600 | floor)시간 미만 — 판정 생략"}
          else {state: "judge", ratio: ((($act - ($prev.active_time_seconds // 0)) | if . < 0 then 0 else . end) / $dt), dt: $dt} end
     end) as $as
  | ($pr.settings.quota.compute_time_seconds // 0) as $q_cts
  | {
      project_id: $pr.id, project_name: $pr.name,
      period_start: $pstart, period_end: $pend,
      elapsed_days: ($elapsed | r(1)), total_days: ($total | r(0)),
      # 브리프의 "결제 기간 N일째" — 반올림 전 경과일로 센다(r(1) 뒤 floor 하면 x.95~x.99일에 하루 많게 셈)
      period_day: ([($elapsed | floor) + 1, ($total | r(0))] | min),
      cu_src: $cu_src, cu_hours: ($cuh | r(2)),
      projected_cu_hours: (if $proj_cuh == null then null else ($proj_cuh | r(1)) end),
      storage_gb: ($st_gb | r(3)), transfer_gb: ($tx_gb | r(3)), written_gb: ($wr_gb | r(3)),
      projected_cost_usd: (if $cost == null then null else ($cost | r(2)) end),
      budget_usd: $budget,
      over_budget: ($cost != null and $cost > $budget),
      active_time_seconds: $act, act_src: $actx.src,
      autosuspend: ($as + (if $as.state == "judge" then {ok: ($as.ratio < 0.9), ratio: ($as.ratio | r(3))} else {} end)),
      hourly: (if $hourly == null then null elif ($hourly.nodata // false) then $hourly
               else $hourly + {ratio: (($hourly.full_on / $hourly.hours) | r(3)), ok: (($hourly.full_on / $hourly.hours) < 0.9)} end),
      period_active_ratio: (if $act != null and ($now - $s) > 0 then (($act / ($now - $s)) | r(3)) else null end),
      quota_compute_pct: (if $q_cts > 0 then ((($pr.compute_time_seconds // 0) / $q_cts * 100) | r(1)) else null end)
    }' > "$WORK/report.json"

cat "$WORK/report.json"

# 다음 실행용 상태 저장 (active_time 없으면 저장 안 함).
# 간격 부족으로 판정을 건너뛴 실행(수동 실행 등)은 기준점을 덮지 않는다 — 덮으면 다음 날 정기 실행도 20h 미만이 돼 연쇄 생략
# preview 는 판정 기준점을 절대 갱신하지 않는다(워크플로도 캐시 저장 스텝을 건너뜀)
BRIEF_MODE="${BRIEF_MODE:-normal}"
case "$BRIEF_MODE" in normal|preview) ;; *) echo "::warning::알 수 없는 BRIEF_MODE '$BRIEF_MODE' — normal 로 진행"; BRIEF_MODE=normal ;; esac
if [ "$BRIEF_MODE" = "preview" ]; then
  echo "preview — 상태(판정 기준점) 저장 생략"
else
  jq -c --argjson now "$NOW" 'select((.autosuspend.keep_prev // false) | not)
    | {ts: $now, active_time_seconds: .active_time_seconds, act_src: .act_src, period_start: .period_start}
    | select(.active_time_seconds != null)' "$WORK/report.json" > "$WORK/state.new"
  if [ -s "$WORK/state.new" ]; then cp "$WORK/state.new" "$STATE"; echo "상태 저장: $(cat "$STATE")"; fi
fi

# ---- 5) 텔레그램 브리프 -------------------------------------------------------
# 여기서는 값과 판정 플래그만 계산해 brief.json 으로 넘기고, 문구·구조는 telegram-format.sh 의 fmt_brief 가 만든다.
# heartbeat — 감시 워크플로 자체가 멈춰도(비활성화·YAML 깨짐·스케줄 누락) 여기서 드러나게.
#   uptime 마지막 성공이 HB_UPTIME_MAX_H(6h) 넘게 전이거나 **확인 불가**(조회 실패·기록 없음)면 첫 줄 🟡.
#     (10분 주기 + GitHub cron 드롭 실측 최대 ~3h → 6h 면 매일 오탐 없이 "반나절 가까이 감시 공백"을 잡는다.
#      12h 였을 때는 22시에 멈춘 감시가 09:17 브리프에선 11h 라 정상으로 보였다 — 2026-10-13 적대 검증 F3)
#   DB 경유(full) 마지막 성공이 HB_FULL_MAX_H(36h) 넘게 전이면 🟡.
#     (full 은 KST 11:04~23:04 에만 돌아 09:17 브리프 시점 정상 간격 ~10h, 여기에 cron 드롭 여유 → 36h = 하루 반 동안 full 0회)
#   ② 사이트 "🟢 정상" 은 열린 장애 이슈가 없고 **uptime 마지막 성공이 SITE_FRESH_H(3h) 이내**일 때만.
#     🟡 로 올리는 기준은 예약 실행 주체(SCHEDULER)에 따라 다르다:
#       cloudflare(정시 실행) → SITE_FRESH_H(3h) 초과면 🟡 "확인 필요" — 정시에 도는데 3h 공백이면 실제 이상
#       github(기본)          → max(SITE_FRESH_H, HB_UPTIME_MAX_H)=6h 초과일 때만 🟡. 3~6h 는 🟢 + "마지막 확인 N시간 전 — GitHub 지연" 글자만
#         (실측 09-27~10-30: 브리프가 도착하는 13~15시의 약 절반이 3h 초과, 6h 초과는 0회 → 3h 로 🟡 를 켜면 거의 매일 🟡 라
#          '주의' 색이 소음이 된다. 2026-10-13 2h 기준이 매일 경보라 희석됐던 전례와 같은 이유 — 2026-10-30 검증 H1)
# 저장소 마지막 커밋 경과일 — 공개 repo 는 60일 무활동이면 GitHub 가 schedule 워크플로(이 브리프 포함)를 자동으로 끈다.
#   자동 빈 커밋(keepalive)은 GitHub 가 약관 위반으로 막은 전례가 있어 쓰지 않는다 → 45일부터 🟡 로 사람에게 알린다.
#   값이 없거나 숫자가 아니면 "확인 불가" 🟡 (조용히 넘어가지 않게 — 2026-10-30 부터 첫 줄에도 반영).
HB_UPTIME_MAX_H="${HB_UPTIME_MAX_H:-6}"; HB_FULL_MAX_H="${HB_FULL_MAX_H:-36}"; SITE_FRESH_H="${SITE_FRESH_H:-3}"
REPO_IDLE_WARN_DAYS="${REPO_IDLE_WARN_DAYS:-45}"
RUNS_WARN_PCT="${RUNS_WARN_PCT:-0}"
for v in HB_UPTIME_MAX_H HB_FULL_MAX_H SITE_FRESH_H REPO_IDLE_WARN_DAYS BUDGET_WARN_PCT RUNS_WARN_PCT; do
  case "${!v}" in
    ''|*[!0-9]*)
      echo "::warning::$v='${!v}' 숫자 아님 — 기본값"
      case "$v" in HB_UPTIME_MAX_H) HB_UPTIME_MAX_H=6 ;; HB_FULL_MAX_H) HB_FULL_MAX_H=36 ;; SITE_FRESH_H) SITE_FRESH_H=3 ;;
                   BUDGET_WARN_PCT) BUDGET_WARN_PCT=80 ;; RUNS_WARN_PCT) RUNS_WARN_PCT=0 ;; *) REPO_IDLE_WARN_DAYS=45 ;; esac ;;
  esac
done
# 예약 실행 주체 — 워크플로가 repo 변수(vars.SCHEDULER)에서 내려 준다. 이 스크립트는 읽기만(문구 선택 + 🟡 판정)
#   해석은 schedule-gate.sh·neon-usage.yml hb 와 같다(대소문자·공백 무시, 모르는 값 = github + 🟡 "SCHEDULER 값 오류").
#   ' Cloudflare ' 를 gate 는 cloudflare 로, 여기서는 github 로 보면 안내 문구·사이트 🟡 기준이 실제 동작과 어긋난다
SCHED="$(printf '%s' "${SCHEDULER:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"; SCHED_BAD=0
case "$SCHED" in
  '') SCHED=github ;;
  github|cloudflare) ;;
  *) echo "::warning::알 수 없는 SCHEDULER '${SCHEDULER}' — github 로 간주"; SCHED=github; SCHED_BAD=1 ;;
esac
[ "${SCHEDULER_BAD:-0}" != "1" ] || SCHED_BAD=1
# 예약 실행기(Worker) 상태 — hb 가 cloudflare 모드에서만 채운다: UPTIME_CF_STALE 1 = 최근 60분 Worker run 없음(대비책으로 도는 중)
CF_STALE=0; [ "$SCHED" = cloudflare ] && [ "${UPTIME_CF_STALE:-}" = "1" ] && CF_STALE=1
iso_epoch() { [ -n "${1:-}" ] || return 0; date -u -d "$1" +%s 2>/dev/null || true; }
num_or_empty() { case "${1:-}" in ''|*[!0-9]*) ;; *) printf '%s' "$1" ;; esac; }
LC_DAYS=""
case "${REPO_LAST_COMMIT_EPOCH:-}" in
  ''|*[!0-9]*) ;;
  *) LC_DAYS=$(( (NOW - REPO_LAST_COMMIT_EPOCH) / 86400 )); [ "$LC_DAYS" -ge 0 ] || LC_DAYS=0 ;;
esac
INCIDENT="${UPTIME_INCIDENT:-}"
if [ -n "$INCIDENT" ] && ! jq -e 'type == "object" and has("open")' <<< "$INCIDENT" >/dev/null 2>&1; then
  echo "::warning::UPTIME_INCIDENT 형식 오류 — 사이트 상태 '확인 불가'"; INCIDENT=""
fi

jq -n --slurpfile r "$WORK/report.json" --argjson now "$NOW" --arg mode "$BRIEF_MODE" --arg note "$PERIOD_NOTE" \
  --arg up_at "$(iso_epoch "${UPTIME_LAST_SUCCESS:-}")" --arg full_at "$(iso_epoch "${UPTIME_LAST_FULL:-}")" \
  --argjson up_max "$HB_UPTIME_MAX_H" --argjson full_max "$HB_FULL_MAX_H" --argjson site_fresh "$SITE_FRESH_H" \
  --arg runs "$(num_or_empty "${UPTIME_RUNS_24H:-}")" --arg full24 "$(num_or_empty "${UPTIME_FULL_24H:-}")" \
  --arg fullx "$(num_or_empty "${UPTIME_FULL_EXEC_24H:-}")" \
  --argjson dr "${UPTIME_DESIGN_RUNS:-144}" --argjson df "${UPTIME_DESIGN_FULL:-13}" \
  --arg inc "$INCIDENT" --arg lcd "$LC_DAYS" --argjson idle_warn "$REPO_IDLE_WARN_DAYS" \
  --argjson bwarn "$BUDGET_WARN_PCT" --argjson rwarn "$RUNS_WARN_PCT" --arg sched "$SCHED" \
  --argjson sched_bad "$SCHED_BAD" --argjson cf_stale "$CF_STALE" --arg cf_at "$(iso_epoch "${UPTIME_CF_LAST:-}")" \
  --arg cf24 "$(num_or_empty "${UPTIME_CF_RUNS_24H:-}")" --arg fb24 "$(num_or_empty "${UPTIME_FALLBACK_RUNS_24H:-}")" '
  def num($s): if $s == "" then null else ($s | tonumber) end;
  # 신호등 단계: ok(🟢) < warn(🟡) < crit(🔴). 섹션별 판정과 첫 줄(가장 나쁜 색)을 여기서 한 번만 정한다 —
  # fmt_brief(HTML)·plain_brief(비상 형식)는 이 값을 표현만 한다(두 곳의 판정이 어긋나지 않게)
  def worst: if any(.[]; . == "crit") then "crit" elif any(.[]; . == "warn") then "warn" else "ok" end;
  $r[0] as $p
  | ($p.autosuspend.state == "judge" and ($p.autosuspend.ok | not)) as $delta_bad
  | ($p.hourly != null and (($p.hourly.nodata // false) | not)) as $hour_judged
  | ($hour_judged and ($p.hourly.ok | not)) as $hour_bad
  | num($up_at) as $ua | num($full_at) as $fa | num($lcd) as $idle
  | num($runs) as $r24 | (num($fullx) // num($full24)) as $f24
  | $p.projected_cost_usd as $cost | $p.budget_usd as $bud
  # 예산 0 이하 = 미설정 — 비교(초과·80%)를 하지 않는다("예산 $0 을 넘을 것 같아요" 방지)
  | ($bud != null and $bud > 0) as $bud_set
  | (($p.over_budget // false) and $bud_set) as $over
  # 판정과 표시에 같은 값(정수 %) — 79.7% 를 "(80%)" 로 보이면서 🟢 로 두지 않게
  | (if $cost != null and $bud_set then ($cost / $bud * 100 | round) else null end) as $cpct
  | ($cpct != null and $bwarn > 0 and ($over | not) and $cpct >= $bwarn) as $near
  | ($ua == null or ($now - $ua) > $up_max * 3600) as $up_bad
  | ($ua != null and ($now - $ua) <= $site_fresh * 3600) as $up_fresh
  # ② 사이트를 🟡 로 올리는 마지막 확인 경과 기준(시간) — 위 주석. github 는 cron 지연이 일상이라 6h(= 감시 멈춤 기준)
  | (if $sched == "cloudflare" then $site_fresh else ([$site_fresh, $up_max] | max) end) as $site_warn_h
  | ($ua == null or ($now - $ua) > $site_warn_h * 3600) as $site_stale
  | ($fa != null and ($now - $fa) > $full_max * 3600) as $full_bad
  | ($rwarn > 0 and $r24 != null and $dr > 0 and $r24 * 100 < $rwarn * $dr) as $runs_low
  | ($rwarn > 0 and $f24 != null and $df > 0 and $f24 * 100 < $rwarn * $df) as $full_low
  | ($idle != null and $idle >= $idle_warn) as $idle_bad
  | (if $inc == "" then null else ($inc | fromjson) end) as $site
  | ($delta_bad or $hour_bad) as $as_bad
  | {site: (if ($site.open // false) then "crit" elif $site == null or $site_stale then "warn" else "ok" end),
     cost: (if $over or $near then "warn" else "ok" end),
     as: (if $as_bad then "crit" elif $hour_judged or ($p.autosuspend.state == "judge") then "ok" else "warn" end),
     watch: (if $up_bad or $full_bad or $fa == null or $idle == null or $idle_bad or $runs_low or $full_low
                or $cf_stale == 1 or $sched_bad == 1 then "warn" else "ok" end)
    } as $lv
  | {
      now: $now, preview: ($mode == "preview"), project: ($p.project_name // "?"),
      period: {elapsed: $p.elapsed_days, total: $p.total_days, day: $p.period_day, note: $note},
      cu: {approx: ($p.cu_src != "v2"), hours: $p.cu_hours, projected: $p.projected_cu_hours, quota_pct: $p.quota_compute_pct},
      cost: {projected: $cost, budget: $bud, budget_set: $bud_set, over: $over, pct: $cpct, near: $near, warn_pct: $bwarn},
      transfer_gb: $p.transfer_gb, storage_gb: $p.storage_gb,
      as: {bad: $as_bad, hour_judged: $hour_judged,
           hour_nodata: ($p.hourly != null and ($p.hourly.nodata // false)),
           full_on: $p.hourly.full_on, hours: $p.hourly.hours,
           delta_judged: ($p.autosuspend.state == "judge"), delta_ratio: $p.autosuspend.ratio, delta_why: $p.autosuspend.why,
           act_src: $p.act_src, period_ratio: $p.period_active_ratio},
      site: $site,
      hb: {uptime_at: $ua, full_at: $fa, uptime_max_h: $up_max, full_max_h: $full_max, site_fresh_h: $site_fresh,
           # 확인 불가(null)도 bad — 감시가 멈췄는지 모르는 상태를 🟢 로 보이지 않게 (첫 줄 🟡)
           uptime_unknown: ($ua == null),
           uptime_bad: $up_bad,
           # ② 사이트 "정상" 은 마지막 확인이 SITE_FRESH_H 안일 때만 / site_stale = 🟡 로 올릴 만큼 오래됨(site_warn_h 초과)
           uptime_fresh: $up_fresh, site_stale: $site_stale, site_warn_h: $site_warn_h,
           full_bad: $full_bad, full_unknown: ($fa == null),
           runs24: $r24, full24: num($full24), full_exec24: num($fullx), design_runs: $dr, design_full: $df,
           runs_warn_pct: $rwarn, runs_low: $runs_low, full_low: $full_low},
      repo: {idle_days: $idle, warn_days: $idle_warn, bad: $idle_bad, unknown: ($idle == null)},
      sched: $sched,
      # 예약 실행기 — cf_stale: cloudflare 인데 최근 60분 Worker run 없음(🟡) / sched_bad: SCHEDULER 값 오류(🟡, github 으로 동작)
      #   cf_at: 마지막 Worker run(epoch) · cf24/fb24: 최근 24h 정기 실행 중 Worker / GitHub 대비책 수(표시만)
      scheduler: {stale: ($cf_stale == 1), bad: ($sched_bad == 1), cf_at: num($cf_at), cf24: num($cf24), fb24: num($fb24)},
      level: ($lv + {overall: ([$lv[]] | worst)})
    }' > "$WORK/brief.json"

# 렌더 가드(monitor-lib.sh tg_render): fmt_brief 가 실패(미정의 변수 등)하거나 빈 출력이면 plain_brief(옛 형식)로 대체 +
# note_fail + TG_DEGRADED=1. 템플릿 실수로 브리프가 통째로 빠지는 일은 없다
tg_render fmt_brief json="$WORK/brief.json"
MSG="$TG_MSG"

echo "----"; echo "$MSG"; echo "----"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # step summary 는 add-mask 대상이 아닐 수 있고 공개 repo 에서 누구나 본다 → 프로젝트·조직 id 는 빼고 기록
  { echo "### Neon 사용량"; echo '```'
    if [ -n "$TG_MSG_PM" ]; then printf '%s' "$MSG"; else html_to_plain "$MSG"; fi
    echo; echo '```'; echo '```json'; jq 'del(.project_id, .org_id)' "$WORK/report.json"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi

degraded_exit() {  # 템플릿 오류로 기본 형식을 썼으면 job 을 실패로 표시(브리프는 이미 보냄 → GitHub 메일 + 감시 실패 알림)
  if [ "$TG_DEGRADED" = "1" ]; then echo "::error::텔레그램 템플릿 오류 — 기본 형식으로 대체함. job 을 실패로 표시"; exit 1; fi
}
if [ "${DRY_RUN:-0}" = "1" ]; then echo "DRY_RUN — 텔레그램 생략"; degraded_exit; exit 0; fi
# 실패 사유 파일은 비우지 않는다 — tg_send 가 남긴 HTTP 코드·migrate_to_chat_id 안내가 '감시 자체 실패' 알림에 실려야 함
# (RUNNER_TEMP 는 job 마다 새로 만들어져 이전 실행 잔여물이 없다)
# 실행 로그 링크는 브리프에 넣지 않는다(매일 오는 메시지라 군더더기) — 필요하면 step summary·Actions 탭
tg_send "$MSG" "$TG_MSG_PM" || true
if [ "$TG_FAILED" = "1" ]; then note_fail "텔레그램 전송 실패"; echo "::error::텔레그램 전송 실패"; exit 1; fi
# 전송 성공 표식 — degraded_exit(템플릿 고장 → exit 1)보다 먼저. neon-usage.yml '브리프 전송 표식' 스텝이 이 값을 보고
# success 가 되고, schedule-gate.sh 는 그 스텝으로 "오늘 정기 브리프 보냄" 을 판정한다(템플릿 고장 날 대비책이 2통째를 보내지 않게)
echo "sent=1" >> "${GITHUB_OUTPUT:-/dev/null}"
degraded_exit
exit 0
