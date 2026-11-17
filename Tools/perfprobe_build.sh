#!/bin/zsh
# Build the perf probe against a given SwiftPM scratch product dir.
# Usage: perfprobe_build.sh <products-dir> <output-binary>
set -e
P="$1"
OUT="$2"
swiftc -O -I "$P" \
  tools/perfprobe.swift \
  "$P/LumenCore.o" "$P/LumenProject.o" "$P/LumenDirector.o" \
  -o "$OUT"
echo "built $OUT"
