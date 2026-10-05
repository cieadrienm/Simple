// Draws the Simple Recorder app icon and writes Resources/icon.icns.  Usage: swift Scripts/make-icon.swift
//
// In the spirit of OSCScore's: the same dark tile, the same two colours. Where OSCScore shows a curve and its
// playhead, this shows what Simple Recorder does: several pictures assembled into one, and the record light.
import AppKit

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func drawIcon(size: Int) -> Data {
    let s = CGFloat(size) / 1024 // everything below is laid out on a 1024 grid, origin bottom-left
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824 pt rounded square centred in 1024, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: color(0x000000, 0.45))
    ctx.addPath(shape); ctx.setFillColor(color(0x15181D)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x232833), color(0x0F1115)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

    // The assembled picture, in the "focus" layout: one source large, two beside it.
    let cyan = 0x5CE1E6
    let gap: CGFloat = 34, stroke: CGFloat = 30, radius: CGFloat = 46
    let left: CGFloat = 196, right: CGFloat = 828, top: CGFloat = 736, bottom: CGFloat = 364
    let split = left + (right - left - gap) * 0.64
    let middle = (top + bottom) / 2
    let tiles = [
        CGRect(x: left, y: bottom, width: split - left, height: top - bottom),
        CGRect(x: split + gap, y: middle + gap / 2, width: right - split - gap, height: top - middle - gap / 2),
        CGRect(x: split + gap, y: bottom, width: right - split - gap, height: middle - gap / 2 - bottom),
    ]
    for tile in tiles {
        let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let glow = CGGradient(colorsSpace: space, colors: [color(cyan, 0.34), color(cyan, 0.04)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(glow, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY - 80), options: [])
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: stroke / 2, dy: stroke / 2), cornerWidth: radius - stroke / 2,
                           cornerHeight: radius - stroke / 2, transform: nil))
        ctx.setStrokeColor(color(cyan)); ctx.setLineWidth(stroke); ctx.strokePath()
    }

    // The record light, set on the picture's corner as OSCScore's keyframe is set on its curve.
    let centre = CGPoint(x: 744, y: 306), r: CGFloat = 98
    let light = CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)
    ctx.setFillColor(color(0x12151A)); ctx.fillEllipse(in: light.insetBy(dx: -36, dy: -36))
    ctx.setFillColor(color(0xFF5C57)); ctx.fillEllipse(in: light)
    ctx.setStrokeColor(color(0xFFFFFF)); ctx.setLineWidth(20); ctx.strokeEllipse(in: light.insetBy(dx: -10, dy: -10))
    ctx.restoreGState()

    // Hairline rim so the dark tile reads on a dark Dock.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.10)); ctx.setLineWidth(4); ctx.strokePath()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--preview" {
    // A look at the drawing without touching Resources
    let folder = URL(fileURLWithPath: arguments[2])
    for size in [1024, 64, 32, 16] { try drawIcon(size: size).write(to: folder.appendingPathComponent("icon-\(size).png")) }
    exit(0)
}
let root = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleRecorder-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try drawIcon(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try drawIcon(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try drawIcon(size: 1024).write(to: root.appendingPathComponent("Resources/icon.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/icon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Resources/icon.icns written" : "iconutil failed")
