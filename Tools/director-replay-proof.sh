#!/bin/bash
set -euo pipefail
[[ $# -eq 3 ]] || { echo "Usage: bash Tools/director-replay-proof.sh project.lumen truth.json new-output-dir" >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo "Requires macOS Metal." >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(cd "$1" && pwd -P)"
TRUTH="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
[[ -f "$PROJECT/project.json" && -f "$PROJECT/screen.mov" && -f "$TRUTH" ]] || exit 2
[[ ! -e "$3" ]] || { echo "Output directory already exists." >&2; exit 2; }
OUT="$(cd "$(dirname "$3")" && pwd -P)/$(basename "$3")"
case "$OUT/" in "$ROOT/"*|"$PROJECT/"*) echo "Use an output directory outside repository and source project." >&2; exit 2;; esac
cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || { echo "Use a clean checkout." >&2; exit 2; }
COMMIT="$(git rev-parse HEAD)"
mkdir "$OUT"
LUMEN_DIRECTOR_REPLAY_PROJECT="$PROJECT" LUMEN_DIRECTOR_REPLAY_TRUTH="$TRUTH" \
LUMEN_DIRECTOR_REPLAY_OUT="$OUT" LUMEN_DIRECTOR_REPLAY_COMMIT="$COMMIT" \
LUMEN_REQUIRE_GPU=1 xcrun swift test -c release --filter actualDirectorReplayProof 2>&1 | tee "$OUT/test.log"
[[ -s "$OUT/report.json" && "$(git rev-parse HEAD)" == "$COMMIT" && -z "$(git status --porcelain)" ]] || exit 1
cat "$OUT/report.json"
