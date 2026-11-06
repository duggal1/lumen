#!/bin/bash
# usage: Tools/vendor-moonshine.sh <moonshine-c-api.h> <libmoonshine.dylib> [<dir containing libonnxruntime*.dylib>]
set -euo pipefail
H="$1"; L="$2"; O="${3:-}"
mkdir -p Sources/CMoonshine/include Vendor/moonshine/lib
cp "$H" Sources/CMoonshine/include/moonshine-c-api.h
cp "$L" Vendor/moonshine/lib/
if [ -n "$O" ]; then cp "$O"/libonnxruntime*.dylib Vendor/moonshine/lib/; fi
printf '#include "moonshine-c-api.h"\n' > Sources/CMoonshine/include/CMoonshine.h
printf '#include "CMoonshine.h"\n' > Sources/CMoonshine/shim.c
for f in Vendor/moonshine/lib/*.dylib; do install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null || true; done
echo "vendored. Models go in ~/Library/Application Support/Lumen/Models/moonshine-streaming-{tiny,small,medium}/ (or use Import… in the app)."
