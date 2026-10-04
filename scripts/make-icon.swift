// Renders the app icon: a lens over stacked context bars.
// Regenerate: swift scripts/make-icon.swift /tmp/icon.png, then resize into App/Assets.xcassets/AppIcon.appiconset.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Squircle tile with a soft vertical gradient.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, 0.25))
ctx.addPath(tilePath); ctx.setFillColor(color(0xF4F1EA)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFBF9F4), color(0xE9E3D6)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Context bars: one per kind, widths like a budget.
let bars: [(UInt32, CGFloat)] = [(0x6E7682, 0.62), (0xA9774F, 0.80), (0x4F8A84, 0.48), (0xB8952F, 0.70), (0x627E9F, 0.36)]
let barX = tile.minX + 120
let barH: CGFloat = 46
var y = tile.maxY - 175
for (hex, frac) in bars {
    let r = CGRect(x: barX, y: y - barH, width: (tile.width - 240) * frac, height: barH)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
    ctx.setFillColor(color(hex)); ctx.fillPath()
    y -= barH + 34
}
ctx.restoreGState()

// Lens: a glass disc that magnifies, with a clay rim and an ink handle.
let center = CGPoint(x: tile.midX + 105, y: tile.midY - 40)
let radius: CGFloat = 190
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setStrokeColor(color(0x1F1D1A)); ctx.setLineWidth(70)
let angle = -CGFloat.pi / 4
ctx.move(to: CGPoint(x: center.x + cos(angle) * (radius + 20), y: center.y + sin(angle) * (radius + 20)))
ctx.addLine(to: CGPoint(x: center.x + cos(angle) * (radius + 150), y: center.y + sin(angle) * (radius + 150)))
ctx.strokePath()
ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
ctx.setFillColor(color(0xFFFFFF, 0.55)); ctx.fillPath()
ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
ctx.setStrokeColor(color(0xB85C38)); ctx.setLineWidth(46); ctx.strokePath()
// A highlighted "stale" line inside the lens.
let hl = CGRect(x: center.x - 110, y: center.y - 22, width: 220, height: 44)
ctx.addPath(CGPath(roundedRect: hl, cornerWidth: 22, cornerHeight: 22, transform: nil))
ctx.setFillColor(color(0xE2AA4E)); ctx.fillPath()
ctx.restoreGState()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
