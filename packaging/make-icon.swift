// Draws the app icon and writes a 1024x1024 PNG.
// Usage: swift packaging/make-icon.swift out.png   (see packaging/make-icon.sh)
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// Background: macOS-style rounded square with a soft shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35).cgColor)
color(0x0b3a53).setFill()
tilePath.fill()
ctx.restoreGState()
NSGradient(starting: color(0x1fa2a6), ending: color(0x0b3a53))!.draw(in: tilePath, angle: -90)

// External drive: light body, darker base strip, activity light.
let body = NSRect(x: 232, y: 300, width: 560, height: 330)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 64, yRadius: 64)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.30).cgColor)
color(0xf4f7f8).setFill()
bodyPath.fill()
ctx.restoreGState()
NSGradient(starting: color(0xffffff), ending: color(0xdfe7ea))!.draw(in: bodyPath, angle: -90)

ctx.saveGState()
bodyPath.addClip()
color(0xc3cfd4).setFill()
NSRect(x: body.minX, y: body.minY, width: body.width, height: 96).fill()
ctx.restoreGState()

color(0x2fd27a).setFill()
NSBezierPath(ovalIn: NSRect(x: body.maxX - 110, y: body.minY + 30, width: 36, height: 36)).fill()
color(0x9aa9af).setFill()
NSBezierPath(roundedRect: NSRect(x: body.minX + 56, y: body.minY + 40, width: 190, height: 16),
             xRadius: 8, yRadius: 8).fill()

// Label
let text = NSAttributedString(string: "ext4", attributes: [
    .font: NSFont.systemFont(ofSize: 150, weight: .heavy),
    .foregroundColor: color(0x0b3a53),
    .kern: -2,
])
let t = text.size()
text.draw(at: NSPoint(x: body.midX - t.width / 2, y: body.minY + 96 + (body.height - 96 - t.height) / 2))

// "Plugged in" arrow above the drive.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 512, y: 668))
arrow.line(to: NSPoint(x: 432, y: 752))
arrow.line(to: NSPoint(x: 484, y: 752))
arrow.line(to: NSPoint(x: 484, y: 836))
arrow.line(to: NSPoint(x: 540, y: 836))
arrow.line(to: NSPoint(x: 540, y: 752))
arrow.line(to: NSPoint(x: 592, y: 752))
arrow.close()
arrow.lineJoinStyle = .round
color(0xffffff, 0.95).setFill()
arrow.fill()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
