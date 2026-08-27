#!/usr/bin/env bash
# Generates placeholder app icons from one (or two) source PNG(s) for:
#   - Android: legacy launcher + round, adaptive foreground/monochrome/quick-tile, TV banner
#   - macOS:   AppIcon.appiconset PNG set + ShareExtension icns
#
# Usage:
#   support/scripts/generate_app_icons.sh [COLOR_SRC] [WHITE_SRC]
#
#   COLOR_SRC  square source PNG, defaults to app/assets/img/logo-512.png
#   WHITE_SRC  single-color (white) source PNG for monochrome icons,
#              defaults to app/assets/img/logo-512-white.png
#
# After replacing the sources, re-run this script to regenerate every size.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COLOR="${1:-$ROOT/app/assets/img/logo-512.png}"
WHITE="${2:-$ROOT/app/assets/img/logo-512-white.png}"
ANDROID_RES="$ROOT/app/android/app/src/main/res"
MAC_APPICONSET="$ROOT/app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
MAC_SHARE_ICON="$ROOT/app/macos/ShareExtension/icon.icns"

[ -f "$COLOR" ] || { echo "missing color source: $COLOR" >&2; exit 1; }
[ -f "$WHITE" ] || { echo "missing white source: $WHITE" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# compose <src> <dst> <canvas_w> <canvas_h> <content_w> <content_h> [--bg #RRGGBB]
# Renders the source scaled to (content_w x content_h), centered on a
# (canvas_w x canvas_h) transparent (or --bg colored) canvas.
cat > "$TMP/composer.swift" <<'SWIFT'
import AppKit

let args = CommandLine.arguments
guard args.count >= 7 else {
    FileHandle.standardError.write("usage: composer <src> <dst> <w> <h> <cw> <ch> [--bg #RRGGBB]\n".data(using: .utf8)!)
    exit(2)
}
let src = args[1], dst = args[2]
let cw = Int(args[3])!, ch = Int(args[4])!
let contentW = Int(args[5])!, contentH = Int(args[6])!
var bg: NSColor? = nil
if args.count >= 9 && args[7] == "--bg" {
    let hex = args[8].dropFirst() // strip '#'
    var value: UInt64 = 0
    Scanner(string: String(hex)).scanHexInt64(&value)
    bg = NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                 green: CGFloat((value >> 8) & 0xFF) / 255,
                 blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}
guard let image = NSImage(contentsOfFile: src) else {
    FileHandle.standardError.write("cannot read \(src)\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: cw, pixelsHigh: ch,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: cw, height: ch)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
if let bg = bg {
    bg.setFill()
    NSRect(x: 0, y: 0, width: cw, height: ch).fill()
}
let w = CGFloat(contentW), h = CGFloat(contentH)
let rect = NSRect(x: (CGFloat(cw) - w) / 2, y: (CGFloat(ch) - h) / 2, width: w, height: h)
image.size = NSSize(width: w, height: h)
image.draw(in: rect)
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: dst))
SWIFT

swiftc -O -o "$TMP/composer" "$TMP/composer.swift" 2>/dev/null

compose() { "$TMP/composer" "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}"; }
# compose_color <dst> <canvas> <content>: full-bleed color icon on transparent canvas
compose_color() { compose "$COLOR" "$1" "$2" "$2" "$3" "$3" ""; }

echo "== Android icons =="
# Legacy launcher icons: density -> edge pixels (full-bleed, transparent bg).
LEGACY=(48 72 96 144 192)
DENSITY=(mdpi hdpi xhdpi xxhdpi xxxhdpi)
for i in "${!DENSITY[@]}"; do
    d="${DENSITY[$i]}"; s="${LEGACY[$i]}"
    for name in ic_launcher ic_launcher_round; do
        compose_color "$ANDROID_RES/mipmap-$d/$name.png" "$s" "$s"
    done
done
# Adaptive foreground/monochrome/quick-tile: 108dp canvas, content inside the
# 66dp safe zone (61.1% of the canvas), per Android adaptive icon guidance.
ADAPTIVE=(108 162 216 324 432)
for i in "${!DENSITY[@]}"; do
    d="${DENSITY[$i]}"
    s="${ADAPTIVE[$i]}"
    content=$(( s * 66 / 108 ))
    compose "$COLOR" "$ANDROID_RES/mipmap-$d/ic_launcher_foreground.png" "$s" "$s" "$content" "$content"
    compose "$WHITE" "$ANDROID_RES/mipmap-$d/ic_launcher_monochrome.png" "$s" "$s" "$content" "$content"
    compose "$COLOR" "$ANDROID_RES/mipmap-$d/ic_launcher_quicktile_foreground.png" "$s" "$s" "$content" "$content"
done
# Android TV banner (320x180): white background with the logo centered.
compose "$COLOR" "$ANDROID_RES/drawable/banner.png" 320 180 96 96 --bg "#FFFFFF"

echo "== macOS AppIcon =="
# AppIcon.appiconset sizes (Contents.json already maps these filenames).
for spec in "16:logo-1024-mac-16" "32:logo-1024-mac-32" "64:logo-1024-mac-64" \
            "128:logo-1024-mac-128" "256:logo-1024-mac-256" "512:logo-1024-mac-512" \
            "1024:logo-1024-mac-1024"; do
    size="${spec%%:*}"
    name="${spec##*:}"
    compose "$COLOR" "$MAC_APPICONSET/$name.png" "$size" "$size" "$size" "$size"
done

echo "== macOS ShareExtension icns =="
ICONSET="$TMP/icon.iconset"
mkdir -p "$ICONSET"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
    size="${spec%%:*}"
    name="${spec##*:}"
    compose "$COLOR" "$ICONSET/$name.png" "$size" "$size" "$size" "$size"
done
iconutil -c icns "$ICONSET" -o "$MAC_SHARE_ICON"

echo "Done."