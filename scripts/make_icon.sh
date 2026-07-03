#!/bin/zsh
# Generates scripts/AppIcon.icns — a cosmos scene: deep-space gradient,
# starfield, ringed planet and a glowing nebula. Idempotent, no network.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f AppIcon.icns && "${1:-}" != "--force" ]]; then
    echo "AppIcon.icns already exists (use --force to regenerate)"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/render.swift" <<'SWIFT'
import AppKit

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset = size * 0.09
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.2237
let card = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// Deep space gradient
NSGradient(colors: [
    NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.08, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.05, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.16, green: 0.07, blue: 0.32, alpha: 1),
])!.draw(in: card, angle: 105)

card.setClip()

// Nebula glows (radial gradients)
func glow(x: CGFloat, y: CGFloat, r: CGFloat, color: NSColor) {
    let g = NSGradient(starting: color, ending: color.withAlphaComponent(0))!
    g.draw(fromCenter: NSPoint(x: x, y: y), radius: 0,
           toCenter: NSPoint(x: x, y: y), radius: r, options: [])
}
glow(x: size * 0.30, y: size * 0.70, r: size * 0.34,
     color: NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.85, alpha: 0.35))
glow(x: size * 0.72, y: size * 0.36, r: size * 0.30,
     color: NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.95, alpha: 0.30))

// Deterministic starfield (LCG so builds are reproducible)
var seed: UInt64 = 20260703
func rnd() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat((seed >> 33) % 10_000) / 10_000
}
for _ in 0..<170 {
    let x = rect.minX + rnd() * rect.width
    let y = rect.minY + rnd() * rect.height
    let r = 0.6 + rnd() * 2.6
    NSColor.white.withAlphaComponent(0.25 + rnd() * 0.75).setFill()
    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r, height: r)).fill()
}
// A few bigger twinkles
for _ in 0..<8 {
    let x = rect.minX + rnd() * rect.width
    let y = rect.minY + rnd() * rect.height
    let r = 3.5 + rnd() * 3.5
    glow(x: x, y: y, r: r * 4, color: NSColor.white.withAlphaComponent(0.5))
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: x - r/2, y: y - r/2, width: r, height: r)).fill()
}

// Ringed planet, lower right
let planetCenter = NSPoint(x: size * 0.60, y: size * 0.42)
let planetR = size * 0.185

// Ring (behind the planet's top half): rotated ellipse stroke
func ringPath(scale: CGFloat) -> NSBezierPath {
    let ring = NSBezierPath(ovalIn: NSRect(
        x: -planetR * 1.85 * scale, y: -planetR * 0.55 * scale,
        width: planetR * 3.7 * scale, height: planetR * 1.1 * scale))
    let transform = AffineTransform(rotationByDegrees: -18)
    ring.transform(using: transform)
    ring.transform(using: AffineTransform(
        translationByX: planetCenter.x, byY: planetCenter.y))
    return ring
}
NSColor(calibratedRed: 0.85, green: 0.75, blue: 0.55, alpha: 0.55).setStroke()
let backRing = ringPath(scale: 1.0)
backRing.lineWidth = size * 0.016
backRing.stroke()

// Planet body
let planetRect = NSRect(x: planetCenter.x - planetR, y: planetCenter.y - planetR,
                        width: planetR * 2, height: planetR * 2)
let planet = NSBezierPath(ovalIn: planetRect)
NSGradient(colors: [
    NSColor(calibratedRed: 0.35, green: 0.75, blue: 0.85, alpha: 1),
    NSColor(calibratedRed: 0.12, green: 0.30, blue: 0.65, alpha: 1),
])!.draw(in: planet, angle: 120)

// Planet terminator shadow
NSGraphicsContext.current?.saveGraphicsState()
planet.setClip()
let shadow = NSBezierPath(ovalIn: planetRect.offsetBy(dx: planetR * 0.45, dy: -planetR * 0.30))
NSColor.black.withAlphaComponent(0.35).setFill()
shadow.fill()
NSGraphicsContext.current?.restoreGraphicsState()

// Front half of the ring (over the planet's lower half)
NSGraphicsContext.current?.saveGraphicsState()
let lowerHalf = NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: planetCenter.y - planetR * 0.12))
lowerHalf.setClip()
NSColor(calibratedRed: 0.95, green: 0.86, blue: 0.65, alpha: 0.85).setStroke()
let frontRing = ringPath(scale: 1.0)
frontRing.lineWidth = size * 0.018
frontRing.stroke()
NSGraphicsContext.current?.restoreGraphicsState()

// Small moon, upper left
let moonR = size * 0.045
let moonRect = NSRect(x: size * 0.255, y: size * 0.685, width: moonR * 2, height: moonR * 2)
NSGradient(colors: [
    NSColor(calibratedWhite: 0.95, alpha: 1),
    NSColor(calibratedWhite: 0.55, alpha: 1),
])!.draw(in: NSBezierPath(ovalIn: moonRect), angle: 130)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("rendered \(CommandLine.arguments[1])")
SWIFT

swift "$WORK/render.swift" "$WORK/icon_1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for entry in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
    px="${entry%%:*}"
    name="${entry#*:}"
    sips -z "$px" "$px" "$WORK/icon_1024.png" --out "$ICONSET/icon_$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
echo "wrote scripts/AppIcon.icns"
