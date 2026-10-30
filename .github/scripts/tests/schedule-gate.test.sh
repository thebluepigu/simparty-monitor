#!/usr/bin/env bash
# Cloudflare 예약 실행기 대비책 테스트 — schedule-gate.sh(정기 실행 중복 확인) + neon-usage.yml heartbeat(hb) 스텝.
# 네트워크·GitHub 호출 없음: gh 는 전부 가짜(fixture JSON), 가짜가 PATH 맨 앞에서 잡히는지 먼저 확인하고 아니면 중단한다.
#
#   bash .github/scripts/tests/schedule-gate.test.sh [--quiet]
#
# 검사: SCHEDULER 없음/github = 예전과 똑같음(gh 호출 0·hb 출력이 HEAD 의 옛 hb 스텝과 같음) / cloudflare 에서 Worker 가 살아
#       있으면 schedule run 건너뜀·죽었으면 대신 실행 / 브리프 하루 1통(KST 날짜 경계) / 수동 실행은 세지도 막지도 않음 /
#       조회 실패 = 진행(fail-open) / hb 가 Worker run 을 정기 실행으로 세고 건너뛴 대비책 run 은 빼는지 / 설계 DB체크 수.
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
assert_eq "uptime: SCHEDULER=github → 진행·gh 0회"    "1|0" "$(gate uptime EVENT=schedule SCHEDULER=github)"
assert_eq "uptime: cloudflare + Worker 5분 전 → 건너뜀" "0|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare)"
assert_eq "uptime: 대소문자·공백 허용"                 "0|1" "$(gate uptime EVENT=schedule SCHEDULER=' Cloudflare ')"
assert_eq "uptime: Worker run 은 항상 진행"            "1|0" "$(gate uptime EVENT=workflow_dispatch SOURCE=cf SCHEDULER=cloudflare)"
assert_eq "uptime: 수동 run 은 항상 진행"              "1|0" "$(gate uptime EVENT=workflow_dispatch SOURCE=manual SCHEDULER=cloudflare)"
runs_file uptime.yml "$(run_obj 11 workflow_dispatch 'uptime · cf · full' $((NOW - 1500)) success)"
assert_eq "uptime: Worker 마지막 25분 전 → 대비책 실행" "1|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare)"
assert_eq "uptime: 창 30분이면 건너뜀"                 "0|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare CF_ALIVE_WINDOW_SEC=1800)"
runs_file uptime.yml "$(run_obj 12 workflow_dispatch 'uptime · full' $((NOW - 60)) success)" "$(run_obj 13 workflow_dispatch 'uptime · test-alert' $((NOW - 60)) success)"
assert_eq "uptime: 수동 실행은 Worker 로 안 셈 → 실행"  "1|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare)"
runs_file uptime.yml "$(run_obj 999 workflow_dispatch 'uptime · cf · quick' $((NOW - 60)) success)"
assert_eq "uptime: 자기 자신은 제외"                    "1|1" "$(gate uptime EVENT=schedule SCHEDULER=cloudflare)"
assert_eq "uptime: gh 실패 → 진행(fail-open)"          "1|1" "$(GH_FAIL=1 gate uptime EVENT=schedule SCHEDULER=cloudflare)"
grep -q '대비책' "$T/gate.log" && ok || bad "uptime: fail-open 경고 로그"

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
assert_eq "brief: 오늘 cf 가 실패했으면 대비책이 보냄"        "1|2" "$(bgate EVENT=schedule SCHEDULER=cloudflare)"
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
  # 비교 기준: 이 브랜치가 갈라진 main 의 옛 hb 스텝 (없으면 그 비교만 SKIP)
  OLD_OK=0
  if base="$(cd "$ROOT" && git merge-base HEAD origin/main 2>/dev/null)" \
      && (cd "$ROOT" && MSYS_NO_PATHCONV=1 git show "$base:.github/workflows/neon-usage.yml") 2>/dev/null | step_run hb > "$T/hb-old.sh" \
      && [ -s "$T/hb-old.sh" ]; then OLD_OK=1; fi
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
    "$(run_obj 105 workflow_dispatch 'uptime · test-alert' $((NOW - 600)) success)" \
    "$(run_obj 104 schedule 'uptime · quick' $((NOW - 3600)) success)" \
    "$(run_obj 103 schedule 'uptime · full' $((NOW - 7200)) success)" \
    "$(run_obj 102 workflow_dispatch 'uptime · full' $((NOW - 9000)) success)" \
    "$(run_obj 101 schedule 'uptime · quick' $((NOW - 100000)) failure)"
  view_file 103 "$MARK=success" "$CHECK=success@$C2"
  view_file 102 "$MARK=skipped" "$CHECK=success@$C1"
  NEW="$(hb "$T/hb-new.sh")"
  assert_eq "hb(github): 마지막 정기 성공 = schedule 1h 전 (test-alert 제외)" "$(iso $((NOW - 3600)))" "$(key last "$NEW")"
  assert_eq "hb(github): 24h 정기 실행 2 · full 의도 1"  "2/1" "$(key runs24 "$NEW")/$(key full24 "$NEW")"
  assert_eq "hb(github): DB체크 실제 = run 103"         "$C2/1" "$(key full "$NEW")/$(key fullx24 "$NEW")"
  assert_eq "hb(github): cf 0 · schedule 2"            "0/2" "$(key cf24 "$NEW")/$(key fb24 "$NEW")"
  assert_eq "hb(github): 설계 DB체크 기본 13"           "13" "$(key design_full "$NEW")"
  if [ "$OLD_OK" = "1" ]; then
    OLD="$(hb "$T/hb-old.sh")"
    for k in last runs24 full24 full fullx24 incident last_commit; do
      assert_eq "hb: SCHEDULER 없음 = 옛 스텝과 같은 출력 ($k)" "$(key "$k" "$OLD")" "$(key "$k" "$NEW")"
    done
    OLDNONE="$(SCHEDULER= hb "$T/hb-old.sh")"; NEWNONE="$(hb "$T/hb-new.sh" SCHEDULER=)"
    assert_eq "hb: SCHEDULER 빈 값도 같음 (runs24)" "$(key runs24 "$OLDNONE")" "$(key runs24 "$NEWNONE")"
  else
    echo "SKIP: 옛 hb 스텝 비교 — origin/main merge-base 없음"; SKIP=$((SKIP + 1))
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
  # (f) 설계 DB체크 수 — Worker 의 FULL_EVERY_HOURS
  reset
  for pair in 1:13 2:7 3:5 0:0 04:4 13:1; do
    assert_eq "hb: full_every_hours=${pair%%:*} → 설계 ${pair#*:}" "${pair#*:}" "$(key design_full "$(hb "$T/hb-new.sh" FULL_EVERY_HOURS_IN="${pair%%:*}")")"
  done
  assert_eq "hb: 입력 없음 + vars.UPTIME_DESIGN_FULL=7" 7 "$(key design_full "$(hb "$T/hb-new.sh" DESIGN_FULL_VAR=7)")"
  assert_eq "hb: 잘못된 입력 → 13" 13 "$(key design_full "$(hb "$T/hb-new.sh" FULL_EVERY_HOURS_IN=abc)")"
  # (g) gh 전부 실패 → 빈 값(브리프가 '확인 불가'), 스텝은 성공
  reset
  assert_eq "hb: gh 실패 → last·runs24 빈 값" "|" "$(X="$(GH_FAIL=1 hb "$T/hb-new.sh" SCHEDULER=cloudflare)"; printf '%s|%s' "$(key last "$X")" "$(key runs24 "$X")")"
fi

[ "$QUIET" = "1" ] || { echo "--- 마지막 gate 로그"; cat "$T/gate.log"; }
echo "schedule-gate tests: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" = "0" ]
