#!/bin/bash
# Explicit local proof, not an unattended launch or remote upload.
set -euo pipefail
[[ $# -eq 4 ]] || { echo "Usage: bash Tools/agent-autonomy-proof.sh chrome.lumen truth.json 40s-project.lumen new-proof-dir" >&2; exit 2; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "Requires Apple Silicon macOS." >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || { echo "Clean checkout required." >&2; exit 2; }
[[ ! -e "$4" ]] || { echo "Output must not exist." >&2; exit 2; }
OUT="$(cd "$(dirname "$4")" && pwd -P)/$(basename "$4")"
case "$OUT/" in "$ROOT/"*) echo "Output must be outside repository." >&2; exit 2;; esac
COMMIT="$(git rev-parse HEAD)"
mkdir "$OUT"
bash Tools/director-replay-proof.sh "$1" "$2" "$OUT/director"
bash Tools/part5-proof.sh "$3" "$OUT/hardware"
[[ "$(git rev-parse HEAD)" == "$COMMIT" && -z "$(git status --porcelain)" ]] || exit 1
echo "Recorded and encoded media evidence generated; Studio presentation still requires a live playback run."
printf 'LUMEN_CADENCE_REPORT=%q LUMEN_CADENCE_COMMIT=%q /Applications/Lumen.app/Contents/MacOS/Lumen\n' "$OUT/cadence.json" "$COMMIT"
echo "Build/install this exact commit, run the printed command, open the approved real project, play continuously for at least 12 seconds."
printf 'python3 Tools/verify-agent-autonomy.py %q %q\n' "$OUT" "$COMMIT"
