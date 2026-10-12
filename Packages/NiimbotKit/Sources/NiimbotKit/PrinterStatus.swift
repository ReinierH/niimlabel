import Foundation

/// Static information read once after connecting.
public struct PrinterInfo: Equatable, Sendable {
    public var modelId: Int?
    public var serialNumber: String?
    public var softwareVersion: String?
    public var hardwareVersion: String?
    public var batteryLevel: Int?
    public var density: Int?
    public var labelType: Int?
    public var autoShutdownTime: Int?
    public var bluetoothAddress: String?

    public init() {}

    public var model: PrinterModel? { PrinterModel.detect(modelId: modelId) }

    static func parseVersion(_ data: [UInt8]) -> String? {
        guard !data.isEmpty else { return nil }
        let value = data.bigEndianValue
        return String(format: "%.2f", Double(value) / 100)
    }

    static func parseText(_ data: [UInt8]) -> String? {
        guard !data.isEmpty else { return nil }
        if data.allSatisfy({ (0x20 ... 0x7E).contains($0) }) {
            return String(decoding: data, as: UTF8.self)
        }
        return data.map { String(format: "%02X", $0) }.joined()
    }

    static func parseAddress(_ data: [UInt8]) -> String? {
        guard !data.isEmpty else { return nil }
        return data.reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// Live status from the heartbeat command.
public struct HeartbeatStatus: Equatable, Sendable {
    /// 0 = closed, 1 = open (when reported).
    public var lidState: Int?
    /// Battery level, usually 1…4 bars.
    public var powerLevel: Int?
    /// 0 = paper present, 1 = no paper (when reported).
    public var paperState: Int?
    /// 0 = no RFID tag read, 1 = tag read.
    public var rfidReadState: Int?

    public init(lidState: Int? = nil, powerLevel: Int? = nil, paperState: Int? = nil, rfidReadState: Int? = nil) {
        self.lidState = lidState
        self.powerLevel = powerLevel
        self.paperState = paperState
        self.rfidReadState = rfidReadState
    }

    public var isLidOpen: Bool? { lidState.map { $0 != 0 } }
    public var hasPaper: Bool? { paperState.map { $0 == 0 } }

    /// The heartbeat layout depends on the firmware; it is identified by payload length.
    public static func parse(_ data: [UInt8]) -> HeartbeatStatus {
        func at(_ i: Int) -> Int? { i < data.count ? Int(data[i]) : nil }
        switch data.count {
        case 20: return HeartbeatStatus(paperState: at(18), rfidReadState: at(19))
        case 19: return HeartbeatStatus(lidState: at(15), powerLevel: at(16), paperState: at(17), rfidReadState: at(18))
        case 13: return HeartbeatStatus(lidState: at(9), powerLevel: at(10), paperState: at(11), rfidReadState: at(12))
        case 10: return HeartbeatStatus(lidState: at(8), powerLevel: at(9), rfidReadState: at(8))
        case 9: return HeartbeatStatus(lidState: at(8))
        default: return HeartbeatStatus()
        }
    }
}

/// Information stored on the RFID tag in an original Niimbot label roll.
public struct RFIDInfo: Equatable, Sendable {
    public var uuid: String
    public var barcode: String
    public var serial: String
    public var totalLabels: Int
    public var usedLabels: Int
    public var labelType: LabelType?
    public var rawLabelType: Int

    public var remainingLabels: Int { max(0, totalLabels - usedLabels) }

    /// Returns nil when no tag is present (`data[0] == 0`).
    public static func parse(_ data: [UInt8]) -> RFIDInfo? {
        guard let first = data.first, first != 0, data.count >= 9 else { return nil }
        var index = 8
        let uuid = data[0 ..< 8].map { String(format: "%02X", $0) }.joined()

        func readString() -> String? {
            guard index < data.count else { return nil }
            let length = Int(data[index])
            index += 1
            guard index + length <= data.count else { return nil }
            defer { index += length }
            return String(decoding: data[index ..< index + length], as: UTF8.self)
        }

        guard let barcode = readString(), let serial = readString(), index + 5 <= data.count else { return nil }
        let total = Array(data[index ..< index + 2]).bigEndianValue
        let used = Array(data[index + 2 ..< index + 4]).bigEndianValue
        let type = Int(data[index + 4])
        return RFIDInfo(uuid: uuid, barcode: barcode, serial: serial, totalLabels: total, usedLabels: used,
                        labelType: LabelType(rawValue: UInt8(type)), rawLabelType: type)
    }
}

public struct PrintStatus: Equatable, Sendable {
    /// Number of labels printed so far in the current job.
    public var page: Int
    public var progress1: Int
    public var progress2: Int

    public static func parse(_ data: [UInt8]) -> PrintStatus? {
        guard data.count >= 4 else { return nil }
        return PrintStatus(page: Array(data[0 ..< 2]).bigEndianValue, progress1: Int(data[2]), progress2: Int(data[3]))
    }
}
