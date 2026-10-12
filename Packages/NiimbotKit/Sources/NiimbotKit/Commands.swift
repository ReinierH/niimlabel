import Foundation

/// Request command identifiers (host → printer).
public enum RequestCommand: UInt8, Sendable {
    case printStart = 0x01
    case pageStart = 0x03
    case printerLog = 0x05
    case antiFake = 0x0B
    case setPageSize = 0x13
    case setQuantity = 0x15
    case rfidInfo = 0x1A
    case rfidInfo2 = 0x1C
    case printClear = 0x20
    case setDensity = 0x21
    case setLabelType = 0x23
    case setAutoShutdownTime = 0x27
    case printerReset = 0x28
    case printerInfo = 0x40
    case soundSettings = 0x58
    case calibrateHeight = 0x59
    case printTestPage = 0x5A
    case printBitmapRowIndexed = 0x83
    case printEmptyRow = 0x84
    case printBitmapRow = 0x85
    case labelPositioningCalibration = 0x8E
    case printStatus = 0xA3
    case printerStatusData = 0xA5
    case printerConfig = 0xAF
    case connect = 0xC1
    case cancelPrint = 0xDA
    case heartbeat = 0xDC
    case pageEnd = 0xE3
    case printEnd = 0xF3

    /// Response command(s) the printer answers this request with.
    /// Most commands answer with a fixed offset from the request id.
    public var responses: Set<UInt8> {
        switch self {
        case .printStart: [0x02]
        case .pageStart: [0x04]
        case .setPageSize: [0x14]
        case .setQuantity: [0x16]
        case .rfidInfo: [0x1B]
        case .rfidInfo2: [0x1D]
        case .printClear: [0x30]
        case .setDensity: [0x31]
        case .setLabelType: [0x33]
        case .setAutoShutdownTime: [0x37]
        case .printerReset: [0x38]
        case .soundSettings: [0x68]
        case .printTestPage: [0x6A]
        case .labelPositioningCalibration: [0x8F]
        case .printStatus: [0xB3]
        case .printerStatusData: [0xB5]
        case .printerConfig: [0xBF]
        case .connect: [0xC2]
        case .heartbeat: [0xDD, 0xDE, 0xDF, 0xD9]
        case .pageEnd: [0xE4]
        case .printEnd: [0xF4]
        case .printerInfo: Set(0x40 ... 0x4F)
        case .antiFake: [0x0C]
        case .calibrateHeight: [0x69]
        case .printerLog: [0x06]
        case .cancelPrint: [0xD0]
        case .printEmptyRow, .printBitmapRow, .printBitmapRowIndexed: []
        }
    }
}

public enum ResponseCommand {
    /// Generic error frame, `data[0]` holds the error code.
    public static let error: UInt8 = 0xDB
    /// Sent by some firmwares when a request is not supported.
    public static let notSupported: UInt8 = 0x00
}

/// Keys for `RequestCommand.printerInfo`; the response id is `0x40 + key`.
public enum PrinterInfoKey: UInt8, CaseIterable, Sendable {
    case density = 1
    case printSpeed = 2
    case labelType = 3
    case language = 6
    case autoShutdownTime = 7
    case modelId = 8
    case softwareVersion = 9
    case batteryLevel = 10
    case serialNumber = 11
    case hardwareVersion = 12
    case bluetoothAddress = 13
    case printMode = 14
    case area = 15
}

/// Media type sent with `setLabelType`.
public enum LabelType: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case withGaps = 1
    case blackMark = 2
    case continuous = 3
    case perforated = 4
    case transparent = 5
    case pvcTag = 6
    case blackMarkGap = 10
    case heatShrinkTube = 11

    public var id: UInt8 { rawValue }

    public var displayName: String {
        switch self {
        case .withGaps: "Labels met tussenruimte"
        case .blackMark: "Zwarte markering"
        case .continuous: "Doorlopende rol"
        case .perforated: "Geperforeerd"
        case .transparent: "Transparant"
        case .pvcTag: "PVC-tag"
        case .blackMarkGap: "Zwarte markering met tussenruimte"
        case .heatShrinkTube: "Krimpkous"
        }
    }
}

public enum AutoShutdownTime: UInt8, CaseIterable, Sendable, Identifiable {
    case minutes15 = 1
    case minutes30 = 2
    case minutes45 = 3
    case minutes60 = 4

    public var id: UInt8 { rawValue }
    public var displayName: String { "\(Int(rawValue) * 15) minuten" }
}

/// Known `0xDB` error codes.
public enum PrinterErrorCode {
    public static func describe(_ code: UInt8) -> String {
        switch code {
        case 0x01: "Deksel open"
        case 0x02: "Geen papier / labels op"
        case 0x03: "Batterij bijna leeg"
        case 0x04: "Batterijfout"
        case 0x05: "Afdrukken door gebruiker gestopt"
        case 0x06: "Gegevensfout"
        case 0x07: "Printkop te warm"
        case 0x08: "Papierfout (positie kwijt)"
        case 0x09: "Printer bezig"
        case 0x0A: "Printkop niet gevonden"
        case 0x0B: "Labelrol niet herkend"
        case 0x0C: "RFID-fout / niet-originele labels"
        default: String(format: "Printerfout 0x%02X", code)
        }
    }
}
