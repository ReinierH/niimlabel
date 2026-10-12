import Foundation

/// Turns a `MonoBitmap` into row packets.
///
/// * Blank rows are sent as `PrintEmptyRow (0x84)`: `[y_hi, y_lo, repeat]`.
/// * Other rows as `PrintBitmapRow (0x85)`: `[y_hi, y_lo, count0, count1, count2, repeat] + row bytes`.
///   Identical consecutive rows are merged using the repeat byte.
public enum BitmapEncoder {
    public static func packets(for bitmap: MonoBitmap, printheadPixels: Int) -> [NiimbotPacket] {
        var packets: [NiimbotPacket] = []
        var y = 0
        while y < bitmap.height {
            let row = bitmap.row(y)
            var repeatCount = 1
            while y + repeatCount < bitmap.height, repeatCount < 255, bitmap.row(y + repeatCount) == row {
                repeatCount += 1
            }

            if row.allSatisfy({ $0 == 0 }) {
                packets.append(NiimbotPacket(.printEmptyRow, y.u16Bytes + [UInt8(repeatCount)]))
            } else {
                let counts = pixelCounts(row: row, printheadPixels: printheadPixels)
                let header = y.u16Bytes + [counts.0, counts.1, counts.2, UInt8(repeatCount)]
                packets.append(NiimbotPacket(.printBitmapRow, header + Array(row)))
            }
            y += repeatCount
        }
        return packets
    }

    /// Number of black dots per third of the print head, as the firmware uses this to budget heating power.
    /// When the row is wider than the head the total is sent as a little-endian u16 in bytes 1–2.
    public static func pixelCounts(row: ArraySlice<UInt8>, printheadPixels: Int) -> (UInt8, UInt8, UInt8) {
        let chunkBytes = max(1, printheadPixels / 8 / 3)
        let split = row.count <= chunkBytes * 3
        var parts = [0, 0, 0]
        var total = 0
        for (offset, byte) in row.enumerated() {
            let bits = byte.nonzeroBitCount
            total += bits
            if split { parts[min(2, offset / chunkBytes)] += bits }
        }
        if split {
            return (UInt8(clamping: parts[0]), UInt8(clamping: parts[1]), UInt8(clamping: parts[2]))
        }
        return (0, UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF))
    }
}
