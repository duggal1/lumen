#!/bin/bash
# Pinned verification: run LUMEN_REQUIRE_GPU=1 make verify at <sha> in a detached worktree.
# Usage: Tools/verify-pinned.sh <sha>
set -euo pipefail
SHA="${1:?usage: Tools/verify-pinned.sh <sha>}"
SHORT="$(echo "$SHA" | cut -c1-7)"
DIR="$(mktemp -d)"
cleanup() { git worktree remove --force "$DIR" 2>/dev/null || true; }
trap cleanup EXIT
git worktree add --detach "$DIR" "$SHA" >/dev/null 2>&1
cd "$DIR"
START=$(python3 -c "import time; print(int(time.time()))")
set +e
LUMEN_REQUIRE_GPU=1 make verify >"make-verify-$SHORT.log" 2>&1
EXIT=$?
set -e
END=$(python3 -c "import time; print(int(time.time()))")
# Count from Swift Testing summary where available; fall back to suite lines.
if grep -q "Test run with" "make-verify-$SHORT.log" 2>/dev/null; then
  PASSED=$(grep -o "passed after" "make-verify-$SHORT.log" | wc -l | tr -d ' ')
  RUN=$(grep -oE "Test run with [0-9]+ tests" "make-verify-$SHORT.log" | tail -n 1 | grep -oE "[0-9]+")
  FAILED=$(grep -oE "failed.*[0-9]+ issue" "make-verify-$SHORT.log" | tail -n 1 | grep -oE "[0-9]+" || echo 0)
  SKIPPED=0
else
  PASSED=0; RUN=0; FAILED=$EXIT; SKIPPED=0
fi
SEMICOLON_FAIL=0
if [ "$EXIT" -eq 0 ]; then STATUS="pass"; else STATUS="fail"; fi
mkdir -p out
cat > "out/verify-$SHORT.json" <<JSON
{"sha": "$SHA", "run": ${RUN:-0}, "passed": ${PASSED:-0}, "failed": ${FAILED:-0}, "skipped": 0, "seconds": $((END-START)), "exit": $EXIT, "status": "$STATUS"}
JSON
cat "out/verify-$SHORT.json"
exit $EXIT
