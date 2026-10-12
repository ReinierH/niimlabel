// Generates the 1024×1024 app icon. Usage: swift scripts/make-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let s = CGFloat(size)

// Background: rounded square with a teal → blue gradient.
let inset: CGFloat = 100
let bg = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
let colors = [CGColor(red: 0.05, green: 0.65, blue: 0.62, alpha: 1), CGColor(red: 0.10, green: 0.36, blue: 0.80, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
ctx.resetClip()

// Label: white tag, slightly rotated.
ctx.saveGState()
ctx.translateBy(x: s / 2, y: s / 2)
ctx.rotate(by: -0.18)
let label = CGRect(x: -300, y: -190, width: 600, height: 380)
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.35))
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.addPath(CGPath(roundedRect: label, cornerWidth: 44, cornerHeight: 44, transform: nil))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Barcode.
ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
let widths: [CGFloat] = [3, 1, 2, 1, 1, 3, 1, 2, 2, 1, 3, 1, 1, 2, 1, 3, 2, 1, 1, 2, 3, 1, 2, 1, 1, 3]
var x: CGFloat = -230
for (i, w) in widths.enumerated() {
    let width = w * 12
    if i % 2 == 0 { ctx.fill(CGRect(x: x, y: -120, width: width, height: 170)) }
    x += width + 0
}
// Text line.
ctx.fill(CGRect(x: -230, y: 90, width: 300, height: 44))
ctx.setFillColor(CGColor(red: 0.10, green: 0.36, blue: 0.80, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 160, y: 70, width: 80, height: 80))
ctx.restoreGState()

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
