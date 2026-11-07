#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xcrun -sdk macosx swiftc -O -o Tools/Verify/lumen-shot Tools/Verify/lumen-shot.swift -framework ScreenCaptureKit -framework AppKit -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers
echo "built Tools/Verify/lumen-shot"
