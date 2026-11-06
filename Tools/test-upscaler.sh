#!/bin/bash
# Upscaler test harness (Agent 1, item 1).
# Proves, with measurements not claims:
#  1. Factor selection per user setting (cap 5 / 8 / 10, ladder {2,3,4,5,6,8,10})
#  2. Measured output resolution = input region x factor (5x and 6x cases)
#  3. Real-time: upscale executes within a 60fps frame budget (16.7ms)
#  4. Stage decomposition for every factor
# Usage: Tools/test-upscaler.sh   (requires Metal GPU, e.g. Apple Silicon Mac)
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== Upscaler factor matrix + measured resolution + real-time budget =="
swift test --filter 'upscalerFactorLadderAndBlend|upscalerProducesMeasuredResolution|upscalerFactorMatrixPerUserSetting|upscalerRunsInsideFrameBudget'
echo "OK: upscaler factors are user-set (5/8/10), measured, and real-time."
