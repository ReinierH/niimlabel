import Foundation

/// A 1-bit image, packed MSB-first per row. A set bit is a black (burned) dot.
public struct MonoBitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public private(set) var data: [UInt8]

    public var bytesPerRow: Int { (width + 7) / 8 }

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        data = [UInt8](repeating: 0, count: ((self.width + 7) / 8) * self.height)
    }

    /// Builds a bitmap from 8-bit luminance (0 = black, 255 = white).
    public init(luminance: [UInt8], width: Int, height: Int, threshold: UInt8 = 128) {
        self.init(width: width, height: height)
        let bpr = bytesPerRow
        for y in 0 ..< height {
            let rowStart = y * width
            for x in 0 ..< width where luminance[rowStart + x] < threshold {
                data[y * bpr + (x >> 3)] |= 0x80 >> UInt8(x & 7)
            }
        }
    }

    public subscript(x: Int, y: Int) -> Bool {
        get {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return data[y * bytesPerRow + (x >> 3)] & (0x80 >> UInt8(x & 7)) != 0
        }
        set {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let index = y * bytesPerRow + (x >> 3)
            let mask: UInt8 = 0x80 >> UInt8(x & 7)
            if newValue { data[index] |= mask } else { data[index] &= ~mask }
        }
    }

    public func row(_ y: Int) -> ArraySlice<UInt8> {
        data[(y * bytesPerRow) ..< ((y + 1) * bytesPerRow)]
    }

    public var blackPixelCount: Int {
        data.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// Rotates clockwise by a multiple of 90 degrees.
    public func rotated(degrees: Int) -> MonoBitmap {
        let turns = ((degrees / 90) % 4 + 4) % 4
        guard turns != 0 else { return self }
        let newWidth = turns == 2 ? width : height
        let newHeight = turns == 2 ? height : width
        var out = MonoBitmap(width: newWidth, height: newHeight)
        for y in 0 ..< height {
            for x in 0 ..< width where self[x, y] {
                switch turns {
                case 1: out[height - 1 - y, x] = true
                case 2: out[width - 1 - x, height - 1 - y] = true
                default: out[y, width - 1 - x] = true
                }
            }
        }
        return out
    }

    /// Returns a bitmap of `newWidth` × `newHeight` with this image centred and then moved by (dx, dy).
    /// Anything that falls outside is clipped.
    public func placed(inWidth newWidth: Int, height newHeight: Int, dx: Int = 0, dy: Int = 0) -> MonoBitmap {
        var out = MonoBitmap(width: newWidth, height: newHeight)
        let ox = (newWidth - width) / 2 + dx
        let oy = (newHeight - height) / 2 + dy
        for y in 0 ..< height {
            let ty = y + oy
            guard ty >= 0, ty < newHeight else { continue }
            for x in 0 ..< width where self[x, y] {
                out[x + ox, ty] = true
            }
        }
        return out
    }

    /// 8-bit luminance (0 black / 255 white), handy for previews.
    public func luminance() -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width where self[x, y] {
                out[y * width + x] = 0
            }
        }
        return out
    }
}
