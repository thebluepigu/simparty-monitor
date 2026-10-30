#!/usr/bin/env bash
# CI 검사 묶음 (.github/workflows/ci.yml 이 부른다 — 로컬에서도 같은 명령으로 돌린다). 네트워크 호출 없음.
#
#   bash .github/scripts/tests/ci-check.sh
#
#   1) .github 아래 모든 *.sh 에 bash -n (문법)
#   2) 워크플로 YAML 파싱 + 각 스텝의 run: 블록에 bash -n (${{ … }} 식은 자리표시로 바꿔 검사)
#   3) tests/telegram-format.test.sh --quiet (템플릿 렌더·이스케이프·전송 재시도·고장 주입)
#   4) tests/schedule-gate.test.sh --quiet (Cloudflare 대비책 중복 확인·heartbeat 집계, 가짜 gh)
#   5) scheduler/worker.js·lib.js node --check + worker.test.mjs (크론→dispatch 매핑, 가짜 fetch) — node 필요
# 템플릿 문구만 바꾸는 미세 조정도 이 검사를 통과해야 main 에 올린다 — 깨진 템플릿은 감시 알림 서식을 망가뜨린다
# (monitor-lib.sh 의 plain 대체가 알림 자체는 지켜 주지만, 서식이 옛 형식으로 떨어지고 job 이 실패로 표시된다).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"
FAILS=0

echo "== 1) bash -n (*.sh)"
while IFS= read -r f; do
  if bash -n "$f"; then echo "  ok  $f"; else echo "  FAIL $f"; FAILS=$((FAILS + 1)); fi
done < <(find .github -name '*.sh' -type f | sort)

echo "== 2) 워크플로 YAML 파싱 + run: 블록 bash -n"
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  echo "  FAIL python + PyYAML 없음 (pip install pyyaml)"; FAILS=$((FAILS + 1))
else
  TMP="$(mktemp -d)"
  for wf in .github/workflows/*.yml; do
    # YAML 은 stdin 으로 넘긴다(Windows python 이 Cygwin 경로를 못 읽는 로컬 환경 대비). 출력: run 블록을 NUL 로 구분
    if ! PYTHONUTF8=1 "$PY" -c '
import sys, yaml, re
d = yaml.safe_load(sys.stdin.buffer.read().decode("utf-8"))
assert isinstance(d, dict) and "jobs" in d, "jobs 없음"
for jn, j in d["jobs"].items():
    for i, st in enumerate(j.get("steps", [])):
        if "run" in st:
            name = st.get("name", st.get("id", str(i)))
            body = re.sub(r"\$\{\{.*?\}\}", "X", st["run"])
            sys.stdout.buffer.write((jn + " / " + name + "\x1f" + body + "\x00").encode("utf-8"))
' < "$wf" > "$TMP/runs"; then
      echo "  FAIL $wf — YAML 파싱 실패"; FAILS=$((FAILS + 1)); continue
    fi
    echo "  ok  $wf (YAML)"
    while IFS= read -r -d '' rec; do
      printf '%s' "${rec#*$'\x1f'}" > "$TMP/step.sh"
      if bash -n "$TMP/step.sh" 2>"$TMP/err"; then echo "  ok    run: ${rec%%$'\x1f'*}"
      else echo "  FAIL  run: ${rec%%$'\x1f'*}"; sed 's/^/        /' "$TMP/err"; FAILS=$((FAILS + 1)); fi
    done < "$TMP/runs"
  done
  rm -rf "$TMP"
fi

echo "== 3) 템플릿 테스트"
if bash "$HERE/telegram-format.test.sh" --quiet; then :; else FAILS=$((FAILS + 1)); fi

echo "== 4) 정기 실행 중복 확인·heartbeat 테스트 (schedule-gate.sh · neon-usage hb 스텝)"
if bash "$HERE/schedule-gate.test.sh" --quiet; then :; else FAILS=$((FAILS + 1)); fi

echo "== 5) Cloudflare 예약 실행기 (scheduler/worker.js·lib.js — node --check + 단위 테스트, 가짜 fetch)"
if [ ! -f scheduler/worker.js ]; then
  echo "  SKIP scheduler/ 없음"
elif ! command -v node >/dev/null 2>&1; then
  # CI(ubuntu 러너)엔 node 가 있다 — 거기서 없으면 실패, 로컬에서 없으면 건너뜀
  if [ -n "${CI:-}" ]; then echo "  FAIL node 없음"; FAILS=$((FAILS + 1)); else echo "  SKIP node 없음 (로컬)"; fi
else
  for js in scheduler/worker.js scheduler/lib.js; do
    if node --check "$js"; then echo "  ok  node --check $js"; else echo "  FAIL node --check $js"; FAILS=$((FAILS + 1)); fi
  done
  if node --test scheduler/worker.test.mjs > "${TMPDIR:-/tmp}/worker-test.log" 2>&1; then
    echo "  ok  worker.test.mjs ($(grep -E '^ℹ (pass|fail) ' "${TMPDIR:-/tmp}/worker-test.log" | tr '\n' ' '))"
  else
    echo "  FAIL worker.test.mjs"; sed 's/^/        /' "${TMPDIR:-/tmp}/worker-test.log" | tail -40; FAILS=$((FAILS + 1))
  fi
fi

echo "ci-check: 실패 ${FAILS}건"
[ "$FAILS" = "0" ]
