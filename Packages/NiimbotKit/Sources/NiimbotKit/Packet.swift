import Foundation

/// A single Niimbot protocol frame:
/// `55 55 | cmd | len | data… | checksum | AA AA`, where checksum = cmd ^ len ^ data[0] ^ … ^ data[n].
public struct NiimbotPacket: Equatable, Sendable, CustomStringConvertible {
    public static let head: [UInt8] = [0x55, 0x55]
    public static let tail: [UInt8] = [0xAA, 0xAA]

    public var command: UInt8
    public var data: [UInt8]

    public init(_ command: UInt8, _ data: [UInt8] = []) {
        precondition(data.count <= 255, "Niimbot packet payload is limited to 255 bytes")
        self.command = command
        self.data = data
    }

    public init(_ command: RequestCommand, _ data: [UInt8] = []) {
        self.init(command.rawValue, data)
    }

    public var checksum: UInt8 {
        var value = command ^ UInt8(truncatingIfNeeded: data.count)
        for byte in data { value ^= byte }
        return value
    }

    public func encoded() -> [UInt8] {
        var bytes = Self.head
        bytes.reserveCapacity(data.count + 7)
        bytes.append(command)
        bytes.append(UInt8(data.count))
        bytes.append(contentsOf: data)
        bytes.append(checksum)
        bytes.append(contentsOf: Self.tail)
        return bytes
    }

    public var description: String {
        String(format: "0x%02X", command) + " [" + data.hexString + "]"
    }
}

/// Reassembles packets from an arbitrary chunked byte stream (BLE notifications may split or merge frames).
public struct PacketParser: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [NiimbotPacket] {
        buffer.append(contentsOf: bytes)
        var packets: [NiimbotPacket] = []

        while true {
            guard let start = headerIndex() else {
                // Keep a trailing 0x55: it may be the first half of the next header.
                if buffer.last == 0x55 { buffer = [0x55] } else { buffer.removeAll() }
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 4 else { break }

            let length = Int(buffer[3])
            let total = length + 7
            guard buffer.count >= total else { break }

            let packet = NiimbotPacket(buffer[2], Array(buffer[4 ..< 4 + length]))
            if packet.checksum == buffer[4 + length], buffer[5 + length] == 0xAA, buffer[6 + length] == 0xAA {
                packets.append(packet)
                buffer.removeFirst(total)
            } else {
                // Corrupt or false header: skip one byte and resynchronise.
                buffer.removeFirst(1)
            }
        }
        return packets
    }

    private func headerIndex() -> Int? {
        guard buffer.count >= 2 else { return nil }
        for i in 0 ..< buffer.count - 1 where buffer[i] == 0x55 && buffer[i + 1] == 0x55 {
            return i
        }
        return nil
    }
}

extension Array where Element == UInt8 {
    public var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Interprets the bytes as an unsigned big-endian integer.
    public var bigEndianValue: Int {
        reduce(0) { ($0 << 8) | Int($1) }
    }
}

extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
}

extension Int {
    var u16Bytes: [UInt8] { UInt16(clamping: self).bigEndianBytes }
}
