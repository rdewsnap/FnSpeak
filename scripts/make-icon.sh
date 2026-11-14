#!/usr/bin/env bash
# Render apps/mac/Support/Icon/fnspeak-icon.svg into AppIcon.icns, keeping
# the background transparent. The 16 and 32 px slots come from
# fnspeak-icon-small.svg, which drops the quotes for a plain, larger fn.
# Needs only what ships with macOS and Xcode.
#
#   scripts/make-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/apps/mac/Support/Icon/fnspeak-icon.svg"
SMALL_SVG="$ROOT/apps/mac/Support/Icon/fnspeak-icon-small.svg"
OUT="$ROOT/apps/mac/Support/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"

cat > "$WORK/render.swift" <<'SWIFT'
import AppKit

let args = CommandLine.arguments
guard let image = NSImage(contentsOfFile: args[1]) else { fatalError("can't read \(args[1])") }
for spec in args.dropFirst(3) {
    let parts = spec.split(separator: ":")
    let pixels = Int(parts[0])!
    // An explicit RGBA bitmap: anything else can come out with a white background.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(args[2])/\(parts[1]).png"))
}
SWIFT

swift "$WORK/render.swift" "$SMALL_SVG" "$SET" \
    16:icon_16x16 32:icon_16x16@2x 32:icon_32x32
swift "$WORK/render.swift" "$SVG" "$SET" \
    64:icon_32x32@2x \
    128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
    512:icon_512x512 1024:icon_512x512@2x
iconutil -c icns "$SET" -o "$OUT"
echo "wrote $OUT"
