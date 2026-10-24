// Generates Packaging/mate-sprite.png (the notch's mate, left of the notch) from Art/mate/noto-anim-512.gif, Google's
// Noto animated 🧉 (CC BY 4.0): every 2nd frame (44 cells) in one horizontal strip, each cell 48x48 px (24 pt @2x).
// The whole 512 px frame is scaled into the cell: the gourd fills most of it and the thermos that pours from the top
// is already cut by the frame's top edge, so nothing is cropped further. Also prints the strip's play time (the GIF's
// own delays, without the first frame's hold), which `MateIconView.duration` uses.
// Usage: swift scripts/make-mate-sprite.swift   (from the package root)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let input = URL(fileURLWithPath: "Art/mate/noto-anim-512.gif")
let output = URL(fileURLWithPath: "Packaging/mate-sprite.png")
let cell = 48
let step = 2

guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else { fatalError("cannot read \(input.path)") }
let count = CGImageSourceGetCount(src)
let picks = Array(stride(from: 0, to: count, by: step))

func delay(_ i: Int) -> Double {
    let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]
    let gif = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
    return gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
        ?? gif?[kCGImagePropertyGIFDelayTime as String] as? Double ?? 0.03
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: cell * picks.count, height: cell, bitsPerComponent: 8, bytesPerRow: 0,
                    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
for (n, i) in picks.enumerated() {
    guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil) else { fatalError("frame \(i)") }
    ctx.draw(frame, in: CGRect(x: n * cell, y: 0, width: cell, height: cell))
}
let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(output.path)") }
let playTime = (1..<count).map(delay).reduce(0, +)
print("\(output.relativePath): \(picks.count) frames of \(cell) px, play time \(String(format: "%.2f", playTime)) s")
