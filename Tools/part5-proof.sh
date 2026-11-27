#!/bin/bash
# Real local release proof; no uploads or edits to the supplied project.
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "Usage: bash Tools/part5-proof.sh /path/to/40s-project.lumen /new/output-directory" >&2
  exit 2
fi
[[ "$(uname -s)" == Darwin ]] || { echo "Requires macOS with Metal." >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(cd "$1" && pwd -P)"
[[ -f "$PROJECT/project.json" && -f "$PROJECT/screen.mov" ]] || { echo "Invalid Lumen project." >&2; exit 2; }
[[ ! -e "$2" ]] || { echo "Output directory must not already exist." >&2; exit 2; }
OUT_PARENT="$(cd "$(dirname "$2")" && pwd -P)"
OUT="$OUT_PARENT/$(basename "$2")"
case "$OUT/" in "$ROOT/"*) echo "Keep proof outside the checkout." >&2; exit 2;; esac
case "$OUT/" in "$PROJECT/"*) echo "Keep proof outside the original project." >&2; exit 2;; esac
cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || { echo "Use a clean checkout for reproducible proof." >&2; exit 2; }
COMMIT="$(git rev-parse HEAD)"
mkdir "$OUT"
{
  echo "commit=$COMMIT"
  echo "architecture=$(uname -m)"
  echo "chip=$(sysctl -n machdep.cpu.brand_string)"
  echo "physical_memory_bytes=$(sysctl -n hw.memsize)"
  sw_vers
  xcrun swift --version
} > "$OUT/machine.txt"
LUMEN_PART5_PROJECT="$PROJECT" LUMEN_PART5_OUT="$OUT" LUMEN_PART5_COMMIT="$COMMIT" \
  LUMEN_BENCHMARK=1 LUMEN_REQUIRE_GPU=1 xcrun swift test -c release \
  --filter targetHardwareRealProjectProof 2>&1 | tee "$OUT/test.log"
[[ -s "$OUT/report.json" ]] || { echo "No report: proof did not execute." >&2; exit 1; }
[[ "$(git rev-parse HEAD)" == "$COMMIT" && -z "$(git status --porcelain)" ]] || {
  echo "Source changed during proof; report is stale." >&2; exit 1;
}
cat "$OUT/report.json"
echo "Real export media checks completed. Stretch metrics and remaining release gates are in the report."
