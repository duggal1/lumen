#!/bin/bash
# Fetch the pretrained RNNoise model that CRNNoise compiles in.
#
# Sources/CRNNoise/src/rnnoise_data.c is generated from the upstream xiph
# model archive: ~78 MB of float literals for the LPCNet weights. It is not
# tracked in git (see .gitattributes and .gitignore), so a fresh checkout has
# to restore it before the package can build.
#
# usage: Tools/vendor-rnnoise.sh
set -euo pipefail

ARCHIVE_URL="https://media.xiph.org/rnnoise/models/rnnoise_data-0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37.tar.gz"
ARCHIVE_SHA256="0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37"
DATA_SHA256="d6021b7697677c4d2274c912975e143765552b0e6f25500aa660fdb4a9849be5"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/Sources/CRNNoise/src/rnnoise_data.c"

if [ -f "$TARGET" ]; then
  echo "rnnoise weights already present: $TARGET"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading $ARCHIVE_URL"
curl -fsSL --retry 3 -o "$TMP/model.tar.gz" "$ARCHIVE_URL"
echo "$ARCHIVE_SHA256  $TMP/model.tar.gz" | shasum -a 256 -c -

tar -xzf "$TMP/model.tar.gz" -C "$TMP" src/rnnoise_data.c
echo "$DATA_SHA256  $TMP/src/rnnoise_data.c" | shasum -a 256 -c -

mkdir -p "$(dirname "$TARGET")"
cp "$TMP/src/rnnoise_data.c" "$TARGET"
echo "vendored $TARGET"
