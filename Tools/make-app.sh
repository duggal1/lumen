#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
config="${CONFIGURATION:-release}"
mkdir -p .build
lock="$PWD/.build/lumen-package.lock"
if ! mkdir "$lock" 2>/dev/null; then
    echo 'Another Lumen packaging job is running.' >&2
    exit 1
fi
staging="$(mktemp -d "$PWD/.build/lumen-package.XXXXXX")"
trap 'rm -rf "$staging"; rmdir "$lock"' EXIT
swift build -c "$config"
bin_dir="$(swift build -c "$config" --show-bin-path)"
metal_src="$PWD/Sources/LumenRender/Shaders/Shaders.metal"
# Xcode 16's SwiftPM copies Shaders.metal instead of compiling it, while newer
# Xcodes compile it into default.metallib. Compile from source whenever a bundle
# is missing its metallib so packaging never depends on SwiftPM's behaviour.
for bundle in "$bin_dir/"*.bundle; do
    [ -d "$bundle" ] || continue
    resources="$bundle/Contents/Resources"
    mkdir -p "$resources"
    if [ ! -f "$resources/default.metallib" ] && [ -f "$metal_src" ]; then
        scratch="$(mktemp -d)"
        if xcrun -sdk macosx metal -c "$metal_src" -o "$scratch/Shaders.air" 2>/dev/null; then
            xcrun -sdk macosx metallib "$scratch/Shaders.air" -o "$resources/default.metallib"
        fi
        rm -rf "$scratch"
    fi
done
destination="$PWD/.build/Lumen.app"
app="$staging/Lumen.app"
if pgrep -x Lumen >/dev/null; then
    echo 'Quit Lumen before packaging. Replacing a running app invalidates macOS permission requests.' >&2
    exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Lumen" "$app/Contents/MacOS/Lumen"
cp App/Info.plist "$app/Contents/Info.plist"
# The native app must ship the MP3 assets it actually plays. They are not
# synthesized and are resolved from Contents/Resources/Audio at runtime.
mkdir -p "$app/Contents/Resources/Audio"
for sound in App/public/assets/*.mp3; do
    [ -f "$sound" ] || continue
    ditto "$sound" "$app/Contents/Resources/Audio/$(basename "$sound")"
done
ditto App/public/assets/music "$app/Contents/Resources/Audio/music"
for bundle in "$bin_dir/"*.bundle; do
    [ -d "$bundle" ] || continue
    ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done
if ! find "$app/Contents/Resources" -name default.metallib -print -quit | /usr/bin/grep -q .; then
    echo 'Missing default.metallib after packaging.' >&2
    exit 1
fi
icon_dir="$staging/Lumen.iconset"
mkdir -p "$icon_dir"
swift - App/public/assets/brand/logo/lumen-icon.png "$icon_dir" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
guard let source = NSImage(contentsOfFile: args[1]) else { fatalError("Cannot read Lumen logo") }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Icon allocation failed") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let side = CGFloat(pixels), width = side, height = width * source.size.height / source.size.width
        source.draw(in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let output = URL(fileURLWithPath: args[2]).appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon encoding failed") }
        try data.write(to: output)
    }
}
SWIFT
iconutil -c icns "$icon_dir" -o "$app/Contents/Resources/Lumen.icns"
signing_identity="${CODE_SIGN_IDENTITY:-}"
if [ -z "$signing_identity" ]; then
    identities="$(security find-identity -v -p codesigning | sed -nE 's/^[[:space:]]*[0-9]+\) ([A-F0-9]{40}) .*/\1/p')"
    if [ "$(printf '%s\n' "$identities" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ]; then
        signing_identity="$identities"
    else
        signing_identity=-
        echo 'Using ad hoc signing. Set CODE_SIGN_IDENTITY for stable macOS permissions across builds.' >&2
    fi
fi
codesign --force --sign "$signing_identity" --identifier com.lumen.studio "$app"
codesign --verify --strict "$app"
plutil -lint "$app/Contents/Info.plist"
if pgrep -x Lumen >/dev/null; then
    echo 'Lumen was opened during packaging. Quit it before installing the new build.' >&2
    exit 1
fi
swift - "$app" "$destination" <<'SWIFT'
import Foundation
import Darwin
let source = CommandLine.arguments[1], destination = CommandLine.arguments[2]
let result = FileManager.default.fileExists(atPath: destination)
    ? renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_SWAP))
    : rename(source, destination)
guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
SWIFT
codesign --verify --strict "$destination"
echo "Built $destination"
