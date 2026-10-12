import Foundation

/// Converts 8-bit luminance (0 black … 255 white) to pure black/white (0 or 255).
public enum Dithering {
    public static func apply(_ mode: DitherMode, to pixels: inout [UInt8], width: Int, height: Int, threshold: Double) {
        switch mode {
        case .threshold:
            let t = UInt8(clamping: Int(threshold))
            for i in pixels.indices { pixels[i] = pixels[i] < t ? 0 : 255 }
        case .ordered:
            ordered(&pixels, width: width, height: height, threshold: threshold)
        case .floydSteinberg:
            errorDiffusion(&pixels, width: width, height: height, threshold: threshold,
                           kernel: [(1, 0, 7.0 / 16), (-1, 1, 3.0 / 16), (0, 1, 5.0 / 16), (1, 1, 1.0 / 16)])
        case .atkinson:
            let w = 1.0 / 8
            errorDiffusion(&pixels, width: width, height: height, threshold: threshold,
                           kernel: [(1, 0, w), (2, 0, w), (-1, 1, w), (0, 1, w), (1, 1, w), (0, 2, w)])
        }
    }

    private static func errorDiffusion(_ pixels: inout [UInt8], width: Int, height: Int, threshold: Double,
                                       kernel: [(Int, Int, Double)]) {
        var buffer = pixels.map(Double.init)
        // Shift so that `threshold` maps to the midpoint, letting the slider act as brightness.
        let bias = 128 - threshold
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = y * width + x
                let old = buffer[i] + bias
                let new: Double = old < 128 ? 0 : 255
                pixels[i] = UInt8(new)
                let error = old - new
                for (dx, dy, weight) in kernel {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny < height else { continue }
                    buffer[ny * width + nx] += error * weight
                }
            }
        }
    }

    private static let bayer4: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

    private static func ordered(_ pixels: inout [UInt8], width: Int, height: Int, threshold: Double) {
        let bias = 128 - threshold
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = y * width + x
                let limit = (bayer4[(y % 4) * 4 + x % 4] + 0.5) * 16
                pixels[i] = Double(pixels[i]) + bias < limit ? 0 : 255
            }
        }
    }
}
