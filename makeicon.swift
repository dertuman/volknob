// Generates VolKnob.icns — a hi-fi volume knob on a dark squircle.
// Run: swift makeicon.swift   (writes VolKnob.icns next to itself)
import AppKit

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(deviceRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let c = NSPoint(x: S/2, y: S/2)
func polar(_ r: CGFloat, _ deg: CGFloat) -> NSPoint {
    NSPoint(x: c.x + r * cos(deg * .pi/180), y: c.y + r * sin(deg * .pi/180))
}

// squircle background (Apple icon grid: ~824pt content, radius ~185)
let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: rgb(0x2e2e33), ending: rgb(0x141417))!.draw(in: bg, angle: -90)

// dial ticks: 270° sweep, min at 225° (7 o'clock) clockwise through 12 up to -45° (5 o'clock)
for i in 0...20 {
    let t = CGFloat(i) / 20
    let deg = 225 - t * 270
    let major = i % 5 == 0
    let tick = NSBezierPath()
    tick.move(to: polar(346, deg))
    tick.line(to: polar(major ? 390 : 372, deg))
    tick.lineWidth = major ? 10 : 6
    tick.lineCapStyle = .round
    rgb(0x5a5a62).setStroke()
    tick.stroke()
}

// knob: drop shadow, brushed body, bevel rim
let knobR: CGFloat = 300
let knobRect = NSRect(x: c.x - knobR, y: c.y - knobR, width: knobR*2, height: knobR*2)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 34
NSGraphicsContext.current?.saveGraphicsState()
shadow.set()
rgb(0x232328).setFill()
NSBezierPath(ovalIn: knobRect).fill()
NSGraphicsContext.current?.restoreGraphicsState()
NSGradient(colors: [rgb(0x4a4a52), rgb(0x2a2a2f), rgb(0x1e1e23)], atLocations: [0, 0.55, 1],
           colorSpace: .deviceRGB)!.draw(in: NSBezierPath(ovalIn: knobRect), angle: -90)
let rim = NSBezierPath(ovalIn: knobRect.insetBy(dx: 5, dy: 5))
rim.lineWidth = 10
rgb(0x606068).setStroke()
rim.stroke()
let innerEdge = NSBezierPath(ovalIn: knobRect.insetBy(dx: 24, dy: 24))
innerEdge.lineWidth = 3
rgb(0x111114).setStroke()
innerEdge.stroke()

// pointer at 2 o'clock (45°) — "turned up", warm orange with a soft glow
let glow = NSShadow()
glow.shadowColor = rgb(0xff9f0a, 0.85)
glow.shadowOffset = .zero
glow.shadowBlurRadius = 26
NSGraphicsContext.current?.saveGraphicsState()
glow.set()
let pointer = NSBezierPath()
pointer.move(to: polar(130, 45))
pointer.line(to: polar(252, 45))
pointer.lineWidth = 40
pointer.lineCapStyle = .round
rgb(0xffa317).setStroke()
pointer.stroke()
NSGraphicsContext.current?.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let png = dir.appendingPathComponent("icon_1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: png)
print("wrote \(png.path)")
