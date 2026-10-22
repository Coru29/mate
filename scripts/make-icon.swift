// Generates Packaging/AppIcon.icns: a mate gourd silhouette with a ring gauge (green arc) on a dark rounded square.
// Usage: swift scripts/make-icon.swift   (from the package root)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// CoreGraphics coordinates: origin bottom-left, 1024x1024, transparent outside the rounded square.
func draw(_ ctx: CGContext) {
    let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
    let square = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x000000, 0.4))
    ctx.addPath(square)
    ctx.setFillColor(color(0x1B1F24))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(square)
    ctx.clip()
    let grad = CGGradient(colorsSpace: sRGB, colors: [color(0x2A3038), color(0x14171B)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Ring gauge: faint track plus a green arc (about 70 %), starting at the top, clockwise.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 300
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(color(0x34D27B))
    ctx.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * 0.7, clockwise: true)
    ctx.strokePath()

    // Mate gourd: a rounded body with a narrower rim, plus the bombilla (straw) leaning out of it.
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 432, y: 600))
    body.addCurve(to: CGPoint(x: 392, y: 470), control1: CGPoint(x: 400, y: 570), control2: CGPoint(x: 384, y: 520))
    body.addCurve(to: CGPoint(x: 512, y: 340), control1: CGPoint(x: 400, y: 400), control2: CGPoint(x: 450, y: 340))
    body.addCurve(to: CGPoint(x: 632, y: 470), control1: CGPoint(x: 574, y: 340), control2: CGPoint(x: 624, y: 400))
    body.addCurve(to: CGPoint(x: 592, y: 600), control1: CGPoint(x: 640, y: 520), control2: CGPoint(x: 624, y: 570))
    body.closeSubpath()
    ctx.setFillColor(color(0xF2EDE2))
    ctx.addPath(body)
    ctx.fillPath()
    // Rim (the mouth of the gourd).
    ctx.setFillColor(color(0x7A5C3E))
    ctx.fillEllipse(in: CGRect(x: 424, y: 584, width: 176, height: 38))
    // Bombilla.
    ctx.setStrokeColor(color(0xD9D4C7))
    ctx.setLineWidth(18)
    ctx.move(to: CGPoint(x: 538, y: 600))
    ctx.addLine(to: CGPoint(x: 610, y: 740))
    ctx.strokePath()
    ctx.setFillColor(color(0xD9D4C7))
    ctx.fillEllipse(in: CGRect(x: 594, y: 730, width: 40, height: 30))
}

func png(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx)
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try fm.createDirectory(atPath: "Packaging", withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", "Packaging/AppIcon.icns", iconset.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Packaging/AppIcon.icns")
