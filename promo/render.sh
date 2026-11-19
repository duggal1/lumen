#!/usr/bin/env bash
# Render one Lumen promo from an exported demo.
# Usage: render.sh <exported-demo.mp4> <duration-sec> [props.json]
set -euo pipefail

DEMO="${1:?usage: render.sh <exported-demo.mp4> <duration-sec> [props.json]}"
DURATION="${2:?usage: render.sh <exported-demo.mp4> <duration-sec> [props.json]}"
PROPS="${3:-props.json}"

# Resolve input paths against the caller's cwd before moving into the promo dir.
DEMO="$(cd "$(dirname "$DEMO")" && pwd)/$(basename "$DEMO")"
PROPS="$(cd "$(dirname "$PROPS")" && pwd)/$(basename "$PROPS")"

cd "$(dirname "$0")"
mkdir -p public out
cp "$DEMO" public/demo.mp4

# Patch only demoDurationSec, in a temp file. The composition is selected from
# the props' demoAspect (<1 means portrait) so the same script serves both sizes.
TMP="$(mktemp "${TMPDIR:-/tmp}/lumen-promo-props.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
COMP="$(node -e '
  const fs = require("fs");
  const [inFile, outFile, duration] = process.argv.slice(1);
  const p = JSON.parse(fs.readFileSync(inFile, "utf8"));
  p.demoDurationSec = Number(duration);
  if (!Number.isFinite(p.demoDurationSec) || p.demoDurationSec <= 0) {
    throw new Error("duration-sec must be a positive number");
  }
  fs.writeFileSync(outFile, JSON.stringify(p, null, 2));
  process.stdout.write(Number(p.demoAspect) < 1 ? "Promo-9x16" : "Promo-16x9");
' "$PROPS" "$TMP" "$DURATION")"

npx remotion render src/index.ts "$COMP" "out/promo-${COMP#Promo-}.mp4" \
  --props="$TMP" --codec=h264 --crf=12 --pixel-format=yuv420p --x264-preset=slow
