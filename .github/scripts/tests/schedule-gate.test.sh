#!/usr/bin/env bash
# Cloudflare 예약 실행기 대비책 테스트 — schedule-gate.sh(정기 실행 중복 확인) + neon-usage.yml heartbeat(hb) 스텝.
# 네트워크·GitHub 호출 없음: gh 는 전부 가짜(fixture JSON), 가짜가 PATH 맨 앞에서 잡히는지 먼저 확인하고 아니면 중단한다.
#
#   bash .github/scripts/tests/schedule-gate.test.sh [--quiet]
#
# 검사: SCHEDULER 없음/github = 예전과 똑같음(gh 호출 0·hb 출력이 도입 전 hb 스텝(fixtures/hb-before-cf.sh)과 같음) /
#       cloudflare 에서 Worker 가 살아 있으면 schedule run 건너뜀·죽었으면 대신 실행(취소된 Worker run 은 안 셈) / SCHEDULER 오타 경고 /
#       브리프 하루 1통(KST 날짜 경계, 템플릿 고장으로 job 이 실패해도 '전송 표식' 이 있으면 보낸 것) / 수동 실행은 세지도 막지도 않음 /
#       조회 실패 = 진행(fail-open) / hb 가 Worker run 을 정기 실행으로 세고 건너뛴 대비책 run 은 빼는지 / Worker 멈춤(cf_stale) /
#       설계 DB체크 수(FULL_EVERY_HOURS) / uptime-mode.sh 의 FULL_EVERY_HOURS 강등 / 스텝 이름·run-name 문자열 동기.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$SCRIPTS/../.." && pwd)"
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
GATE="$SCRIPTS/schedule-gate.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fx"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
assert_eq() { if [ "$2" = "$3" ]; then ok; else bad "$1 — 기대 [$2] 실제 [$3]"; fi; }

# ---- 가짜 gh ----------------------------------------------------------------------------------------------------
#   run list --workflow W [--event E] [--status S] [--limit N] [--json ...] [-q EXPR] → $FX/runs-W.json 을 필터
#   run view ID --json jobs [-q EXPR] → $FX/view-ID.json (없으면 {"jobs":[]}), $FX/view-ID.fail 이 있으면 실패
#   api … → [] ,  GH_FAIL=1 이면 모든 호출 실패.  호출은 전부 $GH_LOG 에 한 줄씩
cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[ "${GH_FAIL:-0}" != "1" ] || { echo "gh: fake failure" >&2; exit 1; }
sub="$1 $2"; shift 2
wf=""; ev=""; st=""; lim=1000; q="."; id=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workflow) wf="$2"; shift ;; --event) ev="$2"; shift ;; --status) st="$2"; shift ;;
    --limit) lim="$2"; shift ;; --json) shift ;; -q|--jq) q="$2"; shift ;;
    *) [ -n "$id" ] || id="$1" ;;
  esac
  shift
done
case "$sub" in
  "run list")
    f="$FX/runs-$wf.json"; [ -f "$f" ] || f=/dev/null
    { cat "$f" 2>/dev/null || true; } | jq -c --arg ev "$ev" --arg st "$st" --argjson lim "$lim" \
      '[ (. // [])[] | select($ev == "" or .event == $ev) | select($st == "" or .conclusion == $st) ] | .[:$lim]' \
      | jq -r "$q" ;;
  "run view")
    [ ! -f "$FX/view-$id.fail" ] || exit 1
    if [ -f "$FX/view-$id.json" ]; then jq -r "$q" "$FX/view-$id.json"; else echo '{"jobs":[]}' | jq -r "$q"; fi ;;
  api*) echo '[]' ;;
  *) echo "fake gh: 모르는 명령 $sub" >&2; exit 1 ;;
esac
FAKE
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" FX="$T/fx" GH_LOG="$T/gh.log"
# 🔴 가드: 가짜가 먼저 잡히지 않으면(경로에 ':' 가 섞여 PATH 가 갈라지는 등) 진짜 gh 가 GitHub 를 부른다 → 중단
if [ "$(command -v gh)" != "$T/bin/gh" ]; then echo "중단: 가짜 gh 가 PATH 에서 먼저 잡히지 않음 ($(command -v gh)) — 실제 호출 방지"; exit 1; fi
case "$T" in *:*) echo "중단: 임시 경로에 ':' ($T) — PATH 가 갈라질 수 있음"; exit 1 ;; esac

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
gh_calls() { if [ -s "$GH_LOG" ]; then wc -l < "$GH_LOG" | tr -d ' '; else echo 0; fi; }
reset() { rm -f "$FX"/*; : > "$GH_LOG"; unset GH_FAIL; }
# $1 kind, 나머지 env 할당 → "run=값|gh 호출 수"
gate() {
  local kind="$1"; shift
  local out="$T/out"; : > "$out"; : > "$GH_LOG"
  env GITHUB_OUTPUT="$out" GH_REPO=o/r RUN_ID=999 "$@" bash "$GATE" "$kind" > "$T/gate.log" 2>&1
  printf '%s|%s' "$(sed -n 's/^run=//p' "$out" | tail -n 1)" "$(gh_calls)"
}
run_obj() {  # id event title createdAt(epoch) conclusion
  jq -nc --argjson id "$1" --arg ev "$2" --arg t "$3" --arg c "$(iso "$4")" --arg k "$5" \
    '{databaseId: $id, event: $ev, displayTitle: $t, createdAt: $c, conclusion: $k, attempt: 1}'
}
runs_file() { local f="$FX/runs-$1.json"; shift; printf '%s\n' "$@" | jq -sc . > "$f"; }
view_file() {  # id → steps "name=conclusion[@completedAt]" ...
  local id="$1"; shift
  local steps="[]" s n c at
  for s in "$@"; do n="${s%%=*}"; c="${s#*=}"; at=""; case "$c" in *@*) at="${c#*@}"; c="${c%%@*}" ;; esac
    steps="$(jq -c --arg n "$n" --arg c "$c" --arg a "$at" '. + [{name: $n, conclusion: $c, completedAt: (if $a == "" then null else $a end)}]' <<< "$steps")"; done
  jq -nc --argjson s "$steps" '{jobs: [{steps: $s}]}' > "$FX/view-$id.json"
}
NOW="$(date -u +%s)"
CHECK='업타임 체크 + 장애 이슈/텔레그램'; MARK='DB 경유(full) 실행 표식'; BRIEF='Neon 사용량 조회 + 텔레그램 브리프'

# ---- 1) gate uptime ---------------------------------------------------------------------------------------------
reset
runs_file uptime.yml "$(run_obj 11 workflow_dispatch 'uptime · cf · quick' $((NOW - 300)) success)"
assert_eq "uptime: SCHEDULER 없음 → 진행·gh 0회"      "1|0" "$(gate uptime EVENT=schedule)"
assert_eq "uptime: SCHEDULER 없음 → 대비책 표식 없음"   "" "$(sed -n 's/^fallback=//p' "$T/out")"
assert_eq "uptime: SCHEDULER=github → 진행·gh 0회"    "1|0" "$(gate uptime EVENT=schedule SCHEDULER=github)"
assert_eq "uptime: cloudflare + Worker 5분 전 → 건너뜀" "0|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare)"
assert_eq "uptime: 건너뜀 → 대비책 표식 없음"           "" "$(sed -n 's/^fallback=//p' "$T/out")"
assert_eq "uptime: 대소문자·공백 허용"                 "0|1" "$(gate uptime EVENT=schedule SCHEDULER=' Cloudflare ')"
assert_eq "uptime: Worker run 은 항상 진행"            "1|0" "$(gate uptime EVENT=workflow_dispatch SOURCE=cf SCHEDULER=cloudflare)"
assert_eq "uptime: Worker run → 대비책 표식 없음"        "" "$(sed -n 's/^fallback=//p' "$T/out")"
assert_eq "uptime: 수동 run 은 항상 진행"              "1|0" "$(gate uptime EVENT=workflow_dispatch SOURCE=manual SCHEDULER=cloudflare)"
runs_file uptime.yml "$(run_obj 11 workflow_dispatch 'uptime · cf · full' $((NOW - 1500)) success)"
assert_eq "uptime: Worker 마지막 25분 전 → 대비책 실행" "1|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare)"
assert_eq "uptime: 대비책 실행 → fallback=1 (알림이 GitHub 지연 문구)" "1" "$(sed -n 's/^fallback=//p' "$T/out")"
assert_eq "uptime: 창 30분이면 건너뜀"                 "0|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare CF_ALIVE_WINDOW_SEC=1800)"
runs_file uptime.yml "$(run_obj 12 workflow_dispatch 'uptime · full' $((NOW - 60)) success)" "$(run_obj 13 workflow_dispatch 'uptime · test-alert' $((NOW - 60)) success)"
assert_eq "uptime: 수동 실행은 Worker 로 안 셈 → 실행"  "1|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare)"
runs_file uptime.yml "$(run_obj 999 workflow_dispatch 'uptime · cf · quick' $((NOW - 60)) success)"
assert_eq "uptime: 자기 자신은 제외"                    "1|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare)"
assert_eq "uptime: gh 실패 → 진행(fail-open)"          "1|1" "$(GH_FAIL=1 gate uptime EVENT=schedule SCHEDULER=cloudflare)"
assert_eq "uptime: gh 실패로 진행 → fallback=1"         "1" "$(sed -n 's/^fallback=//p' "$T/out")"
grep -q '대비책' "$T/gate.log" && ok || bad "uptime: fail-open 경고 로그"
# L2: 취소·기동 실패·skipped 로 끝난 Worker run 은 살아 있다는 근거가 아니다(진행 중 run 은 셈)
runs_file uptime.yml "$(run_obj 14 workflow_dispatch 'uptime · cf · quick' $((NOW - 120)) cancelled)" \
  "$(run_obj 15 workflow_dispatch 'uptime · cf · quick' $((NOW - 400)) startup_failure)"
assert_eq "uptime: 취소·기동 실패한 Worker run 만 → 대비책 실행" "1|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare)"
runs_file uptime.yml "$(run_obj 16 workflow_dispatch 'uptime · cf · quick' $((NOW - 30)) '')"
assert_eq "uptime: 진행 중(결론 없음) Worker run → 건너뜀"      "0|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare)"
runs_file uptime.yml "$(run_obj 17 workflow_dispatch 'uptime · cf · quick' $((NOW - 30)) failure)"
assert_eq "uptime: 체크가 실패한 Worker run 도 Worker 는 살아 있음" "0|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare)"
# M5: SCHEDULER 오타 → github 취급 + 경고(gh 0회 = 지금 동작)
assert_eq "uptime: SCHEDULER 오타 → github 취급·gh 0회" "1|0" "$(gate uptime EVENT=schedule SCHEDULER=cloudfare)"
grep -q '::warning::repo 변수 SCHEDULER=' "$T/gate.log" && ok || bad "uptime: SCHEDULER 오타 경고 로그"
gate uptime EVENT=schedule SCHEDULER=github > /dev/null
if grep -q '::warning::' "$T/gate.log"; then bad "uptime: SCHEDULER=github 에 경고가 붙음"; else ok; fi
gate uptime EVENT=schedule > /dev/null
if grep -q '::warning::' "$T/gate.log"; then bad "uptime: SCHEDULER 없음에 경고가 붙음"; else ok; fi

# ---- 2) gate brief (KST 날짜 경계) ---------------------------------------------------------------------------------
reset
B_NOW="$(date -u -d '2026-11-02T05:00:00Z' +%s)"          # KST 11-02 14:00
Y_LAST="$(date -u -d '2026-11-01T14:59:00Z' +%s)"         # KST 11-01 23:59 = 어제
T_FIRST="$(date -u -d '2026-11-01T15:01:00Z' +%s)"        # KST 11-02 00:01 = 오늘
CF_AM="$(date -u -d '2026-11-02T00:17:05Z' +%s)"          # KST 11-02 09:17 Worker 브리프
bgate() { gate brief NOW_EPOCH="$B_NOW" "$@"; }
runs_file neon-usage.yml "$(run_obj 21 workflow_dispatch 'Neon 사용량 일일 브리프 · cf' "$CF_AM" success)"
view_file 21 "$BRIEF=success"
assert_eq "brief: SCHEDULER 없음 schedule → 진행·gh 0회"   "1|0" "$(bgate EVENT=schedule)"
assert_eq "brief: cloudflare schedule + 오늘 cf 보냄 → 건너뜀" "0|2" "$(bgate EVENT=schedule SCHEDULER=cloudflare)"
assert_eq "brief: 수동 preview 는 항상 진행·gh 0회"         "1|0" "$(bgate EVENT=workflow_dispatch SOURCE=manual SCHEDULER=cloudflare)"
view_file 21 "$BRIEF=failure"
assert_eq "brief: 오늘 cf 가 실패했으면(전송 표식 없음) 대비책이 보냄" "1|2" "$(bgate EVENT=schedule SCHEDULER=cloudflare)"
# M3: 템플릿 고장 → plain 폴백을 보낸 뒤 job 실패 — 전송 표식이 success 면 보낸 것(2통째 방지)
view_file 21 "$BRIEF=failure" "브리프 전송 표식=success"
assert_eq "brief: 브리프 스텝 failure 라도 전송 표식 success → 건너뜀" "0|2" "$(bgate EVENT=schedule SCHEDULER=cloudflare)"
view_file 21 "$BRIEF=failure" "브리프 전송 표식=skipped"
assert_eq "brief: 전송 표식 skipped(전송 실패) → 대비책이 보냄"      "1|2" "$(bgate EVENT=schedule SCHEDULER=cloudflare)"
assert_eq "brief: SCHEDULER 오타 schedule → github 취급·gh 0회"       "1|0" "$(bgate EVENT=schedule SCHEDULER=cloudfare)"
runs_file neon-usage.yml "$(run_obj 22 workflow_dispatch 'Neon 사용량 일일 브리프 · cf' "$Y_LAST" success)"
view_file 22 "$BRIEF=success"
assert_eq "brief: 어제(KST 23:59) 보낸 건 안 셈"             "1|1" "$(bgate EVENT=schedule SCHEDULER=cloudflare)"
runs_file neon-usage.yml "$(run_obj 23 schedule 'Neon 사용량 일일 브리프' "$T_FIRST" success)"
view_file 23 "$BRIEF=success"
assert_eq "brief: Worker run + 오늘(KST 00:01) schedule 이 이미 보냄 → 건너뜀 (SCHEDULER 무관)" "0|2" "$(bgate EVENT=workflow_dispatch SOURCE=cf)"
view_file 23 "$BRIEF=skipped"
assert_eq "brief: 건너뛴 schedule run 은 보낸 게 아님"      "1|2" "$(bgate EVENT=workflow_dispatch SOURCE=cf)"
runs_file neon-usage.yml "$(run_obj 24 workflow_dispatch 'Neon 사용량 일일 브리프' "$CF_AM" success)"
view_file 24 "$BRIEF=success"
assert_eq "brief: 수동 normal 은 정기로 안 셈 → 진행"        "1|1" "$(bgate EVENT=schedule SCHEDULER=cloudflare)"
runs_file neon-usage.yml "$(run_obj 999 schedule 'Neon 사용량 일일 브리프' "$CF_AM" success)"
view_file 999 "$BRIEF=success"
assert_eq "brief: 자기 자신은 제외"                         "1|1" "$(bgate EVENT=schedule SCHEDULER=cloudflare)"
runs_file neon-usage.yml "$(run_obj 25 workflow_dispatch 'Neon 사용량 일일 브리프 · cf' "$CF_AM" success)"
touch "$FX/view-25.fail"
assert_eq "brief: run 조회 실패는 무시하고 진행"             "1|2" "$(bgate EVENT=schedule SCHEDULER=cloudflare)"
assert_eq "brief: gh 실패 → 진행(fail-open)"                "1|1" "$(GH_FAIL=1 bgate EVENT=schedule SCHEDULER=cloudflare)"
assert_eq "알 수 없는 kind → 진행"                          "1|0" "$(gate whatever EVENT=schedule SCHEDULER=cloudflare)"

# ---- 3) neon-usage.yml heartbeat(hb) 스텝 --------------------------------------------------------------------------
PY=""; for c in python3 python; do if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi; done
SKIP=0
if [ -z "$PY" ]; then
  echo "SKIP: hb 스텝 테스트 — python+PyYAML 없음"; SKIP=1
else
  step_run() {  # stdin = workflow YAML, $1 step id → run 블록
    PYTHONUTF8=1 "$PY" -c '
import sys, yaml
d = yaml.safe_load(sys.stdin.buffer.read().decode("utf-8"))
for j in d["jobs"].values():
    for st in j.get("steps", []):
        if st.get("id") == sys.argv[1]:
            sys.stdout.buffer.write(st["run"].encode("utf-8"))
' "$1"
  }
  step_run hb < "$ROOT/.github/workflows/neon-usage.yml" > "$T/hb-new.sh"
  # 비교 기준: 도입 전 main(6591464)의 hb 스텝을 파일로 고정한 것 — git merge-base 로 꺼내면 머지 뒤 자기 자신과 비교하게 된다(L4)
  OLD_OK=0
  if [ -s "$HERE/fixtures/hb-before-cf.sh" ]; then cp "$HERE/fixtures/hb-before-cf.sh" "$T/hb-old.sh"; OLD_OK=1; fi
  # $1 스크립트, 나머지 env → GITHUB_OUTPUT 내용 (key=value 정렬)
  hb() {
    local s="$1"; shift; local out="$T/hb.out"; : > "$out"; : > "$GH_LOG"
    ( cd "$ROOT" && env GITHUB_OUTPUT="$out" GH_REPO=o/r "$@" bash -e "$s" ) > "$T/hb.log" 2>&1 || { bad "hb 스텝 실패: $(tail -3 "$T/hb.log")"; }
    sort "$out"
  }
  key() { sed -n "s/^$1=//p" <<< "$2"; }

  # (a) 오늘 운영(SCHEDULER 없음 · Worker run 없음): 옛 스텝과 출력이 같다 + 수동 test-alert 는 안 셈
  reset
  C1="$(iso $((NOW - 3600 + 40)))"; C2="$(iso $((NOW - 7200 + 50)))"
  runs_file uptime.yml \
    "$(run_obj 106 schedule 'uptime · quick' $((NOW - 60)) '')" \
    "$(run_obj 105 workflow_dispatch 'uptime · test-alert' $((NOW - 600)) success)" \
    "$(run_obj 104 schedule 'uptime · quick' $((NOW - 3600)) success)" \
    "$(run_obj 103 schedule 'uptime · full' $((NOW - 7200)) success)" \
    "$(run_obj 102 workflow_dispatch 'uptime · full' $((NOW - 9000)) success)" \
    "$(run_obj 101 schedule 'uptime · quick' $((NOW - 100000)) failure)"
  view_file 103 "$MARK=success" "$CHECK=success@$C2"
  view_file 102 "$MARK=skipped" "$CHECK=success@$C1"
  NEW="$(hb "$T/hb-new.sh")"
  assert_eq "hb(github): 마지막 정기 성공 = schedule 1h 전 (test-alert 제외)" "$(iso $((NOW - 3600)))" "$(key last "$NEW")"
  assert_eq "hb(github): 24h 정기 실행 3(진행 중 1 포함) · full 의도 1"  "3/1" "$(key runs24 "$NEW")/$(key full24 "$NEW")"
  assert_eq "hb(github): DB체크 실제 = run 103"         "$C2/1" "$(key full "$NEW")/$(key fullx24 "$NEW")"
  assert_eq "hb(github): cf 0 · schedule 3"            "0/3" "$(key cf24 "$NEW")/$(key fb24 "$NEW")"
  assert_eq "hb(github): 설계 DB체크 기본 13"           "13" "$(key design_full "$NEW")"
  assert_eq "hb(github): Worker 멈춤 판정 해당 없음(빈 값)" "|github|0" "$(key cf_stale "$NEW")|$(key scheduler "$NEW")|$(key scheduler_bad "$NEW")"
  if [ "$OLD_OK" = "1" ]; then
    OLD="$(hb "$T/hb-old.sh")"
    for k in last runs24 full24 full fullx24 incident last_commit; do
      assert_eq "hb: SCHEDULER 없음 = 옛 스텝과 같은 출력 ($k)" "$(key "$k" "$OLD")" "$(key "$k" "$NEW")"
    done
    OLDNONE="$(SCHEDULER= hb "$T/hb-old.sh")"; NEWNONE="$(hb "$T/hb-new.sh" SCHEDULER=)"
    assert_eq "hb: SCHEDULER 빈 값도 같음 (runs24)" "$(key runs24 "$OLDNONE")" "$(key runs24 "$NEWNONE")"
  else
    bad "옛 hb 스텝 fixture(tests/fixtures/hb-before-cf.sh) 없음"
  fi

  # (b) cloudflare · Worker 정상: Worker run 을 정기로 세고, 건너뛴 대비책 schedule run 은 뺀다
  reset
  C3="$(iso $((NOW - 3600 + 30)))"; C4="$(iso $((NOW - 10800 + 45)))"
  runs_file uptime.yml \
    "$(run_obj 206 workflow_dispatch 'uptime · cf · quick' $((NOW - 300)) success)" \
    "$(run_obj 205 schedule 'uptime · quick' $((NOW - 1200)) success)" \
    "$(run_obj 204 workflow_dispatch 'uptime · test-alert' $((NOW - 1300)) success)" \
    "$(run_obj 203 workflow_dispatch 'uptime · cf · full' $((NOW - 3600)) success)" \
    "$(run_obj 202 schedule 'uptime · full' $((NOW - 3700)) success)" \
    "$(run_obj 201 schedule 'uptime · full' $((NOW - 10800)) failure)"
  view_file 205 "$CHECK=skipped"
  view_file 203 "$MARK=success" "$CHECK=success@$C3"
  view_file 202 "$MARK=skipped" "$CHECK=skipped"
  view_file 201 "$MARK=success" "$CHECK=failure"
  CF="$(hb "$T/hb-new.sh" SCHEDULER=cloudflare)"
  assert_eq "hb(cf): 마지막 정기 성공 = Worker 5분 전"   "$(iso $((NOW - 300)))" "$(key last "$CF")"
  assert_eq "hb(cf): 24h 정기 = cf 2 + 실제 돈 schedule 1" "3/2/1" "$(key runs24 "$CF")/$(key cf24 "$CF")/$(key fb24 "$CF")"
  assert_eq "hb(cf): full 의도 = cf full + 돈 schedule full" "2" "$(key full24 "$CF")"
  assert_eq "hb(cf): DB체크 실제 = Worker full"          "$C3/1" "$(key full "$CF")/$(key fullx24 "$CF")"
  assert_eq "hb(cf): 옛 schedule heartbeat 조회 안 함"   0 "$(grep -c -- '--status success' "$GH_LOG" || true)"
  assert_eq "hb(cf): Worker 마지막 5분 전 · 멈춤 아님"    "$(iso $((NOW - 300)))|0" "$(key cf_last "$CF")|$(key cf_stale "$CF")"
  CFN="$(hb "$T/hb-new.sh" SCHEDULER=' Cloudflare ')"
  assert_eq "hb: SCHEDULER 대소문자·공백 = gate 와 같은 해석" "cloudflare|3" "$(key scheduler "$CFN")|$(key runs24 "$CFN")"
  BADS="$(hb "$T/hb-new.sh" SCHEDULER=cloudfare)"
  assert_eq "hb: SCHEDULER 오타 → github 취급 + scheduler_bad=1" "github|1|" "$(key scheduler "$BADS")|$(key scheduler_bad "$BADS")|$(key cf_stale "$BADS")"
  grep -q '::warning::repo 변수 SCHEDULER=' "$T/hb.log" && ok || bad "hb: SCHEDULER 오타 경고 로그"

  # (c) cloudflare · Worker 중단: 대비책 schedule run 이 heartbeat 가 된다
  reset
  runs_file uptime.yml \
    "$(run_obj 303 schedule 'uptime · quick' $((NOW - 900)) success)" \
    "$(run_obj 302 schedule 'uptime · quick' $((NOW - 1800)) success)" \
    "$(run_obj 301 workflow_dispatch 'uptime · cf · quick' $((NOW - 20000)) success)"
  view_file 303 "$CHECK=success"; view_file 302 "$CHECK=skipped"
  DEAD="$(hb "$T/hb-new.sh" SCHEDULER=cloudflare)"
  assert_eq "hb(cf 중단): 마지막 정기 성공 = 대비책 15분 전" "$(iso $((NOW - 900)))" "$(key last "$DEAD")"
  assert_eq "hb(cf 중단): 24h = 대비책 1 + 옛 cf 1"        "2/1/1" "$(key runs24 "$DEAD")/$(key cf24 "$DEAD")/$(key fb24 "$DEAD")"
  assert_eq "hb(cf 중단): Worker 멈춤 = 1 (마지막 5.5시간 전)" "$(iso $((NOW - 20000)))|1" "$(key cf_last "$DEAD")|$(key cf_stale "$DEAD")"
  grep -q '::warning::SCHEDULER=cloudflare 인데 최근 60분' "$T/hb.log" && ok || bad "hb(cf 중단): 멈춤 경고 로그"
  # 취소된 Worker run 은 살아 있다는 근거·실행 수가 아니다
  reset
  runs_file uptime.yml "$(run_obj 351 workflow_dispatch 'uptime · cf · quick' $((NOW - 300)) cancelled)" \
    "$(run_obj 350 workflow_dispatch 'uptime · cf · quick' $((NOW - 7200)) success)"
  CAN="$(hb "$T/hb-new.sh" SCHEDULER=cloudflare)"
  assert_eq "hb(cf): 취소된 Worker run 제외 → 마지막 2시간 전·멈춤·24h 1회" "$(iso $((NOW - 7200)))|1|1" "$(key cf_last "$CAN")|$(key cf_stale "$CAN")|$(key cf24 "$CAN")"
  # Worker run 이 하나도 없으면 멈춤 = 1, 마지막 = 빈 값
  reset
  runs_file uptime.yml "$(run_obj 360 schedule 'uptime · quick' $((NOW - 600)) success)"
  view_file 360 "$CHECK=success"
  NOCF="$(hb "$T/hb-new.sh" SCHEDULER=cloudflare)"
  assert_eq "hb(cf): Worker run 0건 → 멈춤 1" "|1" "$(key cf_last "$NOCF")|$(key cf_stale "$NOCF")"
  # (d) cloudflare: 건너뛴 run 만 있으면 heartbeat 없음(확인 불가) — 건너뛴 run 이 멈춘 감시를 가리면 안 된다
  reset
  runs_file uptime.yml "$(run_obj 401 schedule 'uptime · quick' $((NOW - 600)) success)"
  view_file 401 "$CHECK=skipped"
  assert_eq "hb(cf): 건너뛴 run 은 heartbeat 아님" "" "$(key last "$(hb "$T/hb-new.sh" SCHEDULER=cloudflare)")"
  # (e) 조회 한도: schedule run 50건이어도 체크 스텝 조회는 40건까지
  reset
  objs=(); for i in $(seq 1 50); do objs+=("$(run_obj $((500 + i)) schedule 'uptime · quick' $((NOW - i * 600)) success)"); done
  runs_file uptime.yml "${objs[@]}"
  hb "$T/hb-new.sh" SCHEDULER=cloudflare > /dev/null
  assert_eq "hb(cf): run view 조회 상한 40" 40 "$(grep -c '^run view' "$GH_LOG" || true)"
  # (f) 설계 DB체크 수 — repo 변수 FULL_EVERY_HOURS (uptime-mode.sh 와 같은 해석)
  reset
  for pair in 1:13 2:7 3:5 0:0 04:4 13:1 99:1; do
    assert_eq "hb: FULL_EVERY_HOURS=${pair%%:*} → 설계 ${pair#*:}" "${pair#*:}" "$(key design_full "$(hb "$T/hb-new.sh" FULL_EVERY_HOURS="${pair%%:*}")")"
  done
  assert_eq "hb: FULL_EVERY_HOURS 없음 → 13" 13 "$(key design_full "$(hb "$T/hb-new.sh" FULL_EVERY_HOURS=)")"
  assert_eq "hb: 잘못된 값 → 1 로 보고 13" 13 "$(key design_full "$(hb "$T/hb-new.sh" FULL_EVERY_HOURS=abc)")"
  # 1~3자리만 정수 — 큰 값이 10# 산술에서 음수로 감겨 설계 0 이 되는 것 방지(템플릿·uptime-mode 와 같은 규칙)
  assert_eq "hb: 20자리 값 → 1 로 보고 13" 13 "$(key design_full "$(hb "$T/hb-new.sh" FULL_EVERY_HOURS=18446744073709551615)")"
  assert_eq "hb: 4자리 값 → 1 로 보고 13" 13 "$(key design_full "$(hb "$T/hb-new.sh" FULL_EVERY_HOURS=1000)")"
  # (g) gh 전부 실패 → 빈 값(브리프가 '확인 불가'), 스텝은 성공
  reset
  assert_eq "hb: gh 실패 → last·runs24 빈 값" "|" "$(X="$(GH_FAIL=1 hb "$T/hb-new.sh" SCHEDULER=cloudflare)"; printf '%s|%s' "$(key last "$X")" "$(key runs24 "$X")")"
fi

# ---- 4) uptime-mode.sh — FULL_EVERY_HOURS 주기 강등 (M6) -----------------------------------------------------------
MODE_SH="$SCRIPTS/uptime-mode.sh"
mode_of() {  # $1 UTC "YYYY-MM-DDTHH:MM", 나머지 env → mode
  local at; at="$(date -u -d "$1:00Z" +%s)"; shift
  local out="$T/mode.out"; : > "$out"
  env GITHUB_OUTPUT="$out" GH_REPO=o/r RUN_ID=999 RUN_ATTEMPT=1 NOW_EPOCH="$at" EVENT=workflow_dispatch INPUT_MODE=full "$@" \
    bash "$MODE_SH" > "$T/mode.log" 2>&1 || echo "mode-exit=$?" >> "$out"
  sed -n 's/^mode=//p' "$out" | tail -n 1
}
reset
runs_file uptime.yml "$(run_obj 1 schedule 'uptime · quick' $((NOW - 100000)) success)"
D=2026-11-02
hours_full() {  # 나머지 env → full 이 된 UTC 시 목록 (00~23시 04분)
  local h r=""; for h in $(seq -w 0 23); do [ "$(mode_of "${D}T${h}:04" "$@")" = "full" ] && r="$r ${h#0}"; done; printf '%s' "${r# }"
}
assert_eq "mode: FULL_EVERY_HOURS 없음 → 매시(UTC 2~14)" "2 3 4 5 6 7 8 9 10 11 12 13 14" "$(hours_full)"
assert_eq "mode: FULL_EVERY_HOURS=1 = 지금과 같음"       "2 3 4 5 6 7 8 9 10 11 12 13 14" "$(hours_full FULL_EVERY_HOURS=1)"
assert_eq "mode: FULL_EVERY_HOURS=2 → 7회"              "2 4 6 8 10 12 14" "$(hours_full FULL_EVERY_HOURS=2)"
assert_eq "mode: FULL_EVERY_HOURS=3 → KST 11·14·17·20·23시" "2 5 8 11 14" "$(hours_full FULL_EVERY_HOURS=3)"
assert_eq "mode: FULL_EVERY_HOURS=0 → full 없음"         "" "$(hours_full FULL_EVERY_HOURS=0)"
assert_eq "mode: FULL_EVERY_HOURS=abc → 1 로 보고 매시"  "full" "$(mode_of "${D}T03:04" FULL_EVERY_HOURS=abc)"
grep -q '::warning::FULL_EVERY_HOURS' "$T/mode.log" && ok || bad "mode: 해석 불가 경고 로그"
assert_eq "mode: 20자리 값 → 1 로 보고 매시(음수로 감겨 매 슬롯 full 이 되지 않게)" "2 3 4 5 6 7 8 9 10 11 12 13 14" "$(hours_full FULL_EVERY_HOURS=18446744073709551615)"
assert_eq "mode: 수동 full 도 FULL_EVERY_HOURS=0 이면 quick (알림 안내 문구의 근거)" "quick" "$(mode_of "${D}T03:04" FULL_EVERY_HOURS=0 EVENT=workflow_dispatch INPUT_MODE=full)"
assert_eq "mode: schedule full cron 도 같은 주기(3 → UTC 3시 강등)" "quick" "$(mode_of "${D}T03:04" FULL_EVERY_HOURS=3 EVENT=schedule SCHED='4 2-14 * * *')"
assert_eq "mode: schedule full cron · UTC 5시 · 3 → full"          "full"  "$(mode_of "${D}T05:04" FULL_EVERY_HOURS=3 EVENT=schedule SCHED='4 2-14 * * *')"
assert_eq "mode: quick 요청은 주기와 무관하게 quick" "quick" "$(mode_of "${D}T05:04" FULL_EVERY_HOURS=3 INPUT_MODE=quick)"
assert_eq "mode: test-alert 는 그대로"            "test-alert" "$(mode_of "${D}T05:04" FULL_EVERY_HOURS=3 INPUT_MODE=test-alert)"
# 45분 가드는 그대로 — 주기 시간이어도 30분 전 DB 체크한 run 이 있으면 강등
AT5="$(date -u -d "${D}T05:04:00Z" +%s)"
runs_file uptime.yml "$(run_obj 41 workflow_dispatch 'uptime · cf · full' $((AT5 - 1800)) success)"
view_file 41 "$MARK=success" "$CHECK=success"
assert_eq "mode: 45분 가드 유지" "quick" "$(mode_of "${D}T05:04" FULL_EVERY_HOURS=3)"
grep -q -- '--limit 40' "$GH_LOG" && ok || bad "mode: 최근 run 조회 --limit 40 (L5)"
view_file 41 "$MARK=skipped" "$CHECK=success"
assert_eq "mode: 강등된 run 은 가드에 안 걸림" "full" "$(mode_of "${D}T05:04" FULL_EVERY_HOURS=3)"

# ---- 5) 문자열 동기 — 스텝 이름·run-name (바뀌면 하루 1통·중복 확인이 조용히 고장) -----------------------------------
if [ -n "$PY" ]; then
  names() { PYTHONUTF8=1 "$PY" -c '
import sys, yaml
d = yaml.safe_load(sys.stdin.buffer.read().decode("utf-8"))
print(d.get("run-name", ""))
for j in d["jobs"].values():
    for st in j.get("steps", []):
        print("STEP " + str(st.get("name", "")))
' < "$1"; }
  NN="$(names "$ROOT/.github/workflows/neon-usage.yml")"; UN="$(names "$ROOT/.github/workflows/uptime.yml")"
  for v in BRIEF_STEP SENT_STEP; do
    val="$(sed -n "s/^$v='\(.*\)'\$/\1/p" "$GATE")"
    if [ -n "$val" ] && grep -qxF "STEP $val" <<< "$NN"; then ok; else bad "동기: schedule-gate.sh $v='$val' 가 neon-usage.yml 스텝 이름에 없음"; fi
  done
  grep -qF "' · cf'" <<< "$(head -n 1 <<< "$NN")" && ok || bad "동기: neon-usage run-name 에 ' · cf' 없음"
  # '· cf' 는 Worker 정기 브리프(mode=normal)에만 — source=cf 로 손으로 돌린 preview 가 '오늘 정기 브리프' 로 세지 않게
  grep -qF "inputs.source == 'cf' && inputs.mode == 'normal' && ' · cf'" <<< "$(head -n 1 <<< "$NN")" && ok || bad "동기: neon-usage run-name 의 '· cf' 가 mode=normal 조건 없이 붙음"
  assert_eq "동기: uptime.yml 체크·감시 실패 스텝이 대비책이면 github 문구" 2 "$(grep -cF "SCHEDULER: \${{ steps.gate.outputs.fallback == '1' && 'github' || vars.SCHEDULER || 'github' }}" "$ROOT/.github/workflows/uptime.yml")"
  grep -qF "'cf · '" <<< "$(head -n 1 <<< "$UN")" && ok || bad "동기: uptime run-name 에 'cf · ' 없음"
  grep -qxF "STEP $CHECK" <<< "$UN" && grep -qxF "STEP $MARK" <<< "$UN" && ok || bad "동기: uptime.yml 체크·표식 스텝 이름"
fi

[ "$QUIET" = "1" ] || { echo "--- 마지막 gate 로그"; cat "$T/gate.log"; }
echo "schedule-gate tests: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" = "0" ]
