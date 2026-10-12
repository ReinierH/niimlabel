import Foundation

/// Which command sequence a printer expects for a print job.
public enum PrintProtocol: String, Codable, CaseIterable, Sendable, Identifiable {
    /// B1-style: 7-byte PrintStart (total labels), 6-byte SetPageSize (rows, cols, copies).
    /// Used by B1, B21 (recent firmware), B3S, B203, D110 (recent firmware) and most newer models.
    case modern
    /// Original protocol: 1-byte PrintStart, 4-byte SetPageSize + SetQuantity.
    /// Used by D11, older B21/D110 firmware, B18.
    case legacy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .modern: "Modern (B1, B21, D110 nieuw)"
        case .legacy: "Klassiek (D11, B18, oude firmware)"
        }
    }
}

public struct PrinterModel: Identifiable, Hashable, Sendable {
    public let name: String
    /// Values reported by `PrinterInfo(modelId)`.
    public let modelIds: [Int]
    public let dpi: Int
    /// Width of the print head in dots.
    public let printheadPixels: Int
    public let densityRange: ClosedRange<Int>
    public let defaultDensity: Int
    public let printProtocol: PrintProtocol
    public let labelTypes: [LabelType]

    public var id: String { name }

    /// Dots per millimetre. 203 dpi heads are effectively 8 dots/mm.
    public var dotsPerMM: Double { dpi == 203 ? 8 : Double(dpi) / 25.4 }

    public var printheadWidthMM: Double { Double(printheadPixels) / dotsPerMM }

    public var isWideFormat: Bool { printheadPixels >= 300 }

    private static let standardTypes: [LabelType] = [.withGaps, .blackMark, .continuous, .transparent]

    public static let b1 = PrinterModel(name: "B1", modelIds: [4096, 4097, 4098], dpi: 203, printheadPixels: 384,
                                        densityRange: 1 ... 5, defaultDensity: 3, printProtocol: .modern,
                                        labelTypes: standardTypes)

    public static let all: [PrinterModel] = [
        b1,
        PrinterModel(name: "B1 Pro", modelIds: [4099], dpi: 300, printheadPixels: 591,
                     densityRange: 1 ... 5, defaultDensity: 3, printProtocol: .modern, labelTypes: standardTypes),
        PrinterModel(name: "B21", modelIds: [768, 769, 770, 771, 772, 773, 774, 775], dpi: 203, printheadPixels: 384,
                     densityRange: 1 ... 5, defaultDensity: 3, printProtocol: .modern, labelTypes: standardTypes),
        PrinterModel(name: "B21 Pro", modelIds: [785, 786], dpi: 300, printheadPixels: 591,
                     densityRange: 1 ... 5, defaultDensity: 3, printProtocol: .modern, labelTypes: standardTypes),
        PrinterModel(name: "B3S", modelIds: [256, 257, 258, 259, 260, 261], dpi: 203, printheadPixels: 576,
                     densityRange: 1 ... 5, defaultDensity: 3, printProtocol: .modern, labelTypes: standardTypes),
        PrinterModel(name: "B203", modelIds: [2816, 2817], dpi: 203, printheadPixels: 384,
                     densityRange: 1 ... 5, defaultDensity: 3, printProtocol: .modern, labelTypes: standardTypes),
        PrinterModel(name: "B18", modelIds: [1792], dpi: 203, printheadPixels: 120,
                     densityRange: 1 ... 3, defaultDensity: 2, printProtocol: .legacy, labelTypes: [.withGaps, .heatShrinkTube]),
        PrinterModel(name: "D11", modelIds: [512, 513, 514], dpi: 203, printheadPixels: 96,
                     densityRange: 1 ... 3, defaultDensity: 2, printProtocol: .legacy, labelTypes: [.withGaps, .transparent]),
        PrinterModel(name: "D11-H", modelIds: [528], dpi: 300, printheadPixels: 142,
                     densityRange: 1 ... 5, defaultDensity: 3, printProtocol: .modern, labelTypes: [.withGaps, .transparent]),
        PrinterModel(name: "D101", modelIds: [2560], dpi: 203, printheadPixels: 192,
                     densityRange: 1 ... 3, defaultDensity: 2, printProtocol: .legacy, labelTypes: [.withGaps, .transparent]),
        PrinterModel(name: "D110", modelIds: [2304, 2305, 2306, 2307], dpi: 203, printheadPixels: 96,
                     densityRange: 1 ... 3, defaultDensity: 2, printProtocol: .modern, labelTypes: [.withGaps, .transparent]),
        PrinterModel(name: "D110-M", modelIds: [2320], dpi: 300, printheadPixels: 142,
                     densityRange: 1 ... 5, defaultDensity: 3, printProtocol: .modern, labelTypes: [.withGaps, .transparent]),
    ]

    public static func named(_ name: String) -> PrinterModel? {
        all.first { $0.name == name }
    }

    public static func detect(modelId: Int?) -> PrinterModel? {
        guard let modelId else { return nil }
        return all.first { $0.modelIds.contains(modelId) }
    }

    /// Detects the model from a BLE advertisement name such as `B1-H811040144` or `D110-F5021411`.
    public static func detect(advertisedName name: String) -> PrinterModel? {
        let prefix = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).first.map(String.init)?.uppercased() ?? ""
        let candidates = all.sorted { $0.name.count > $1.name.count }
        if let exact = candidates.first(where: { $0.name.replacingOccurrences(of: " ", with: "").uppercased() == prefix }) {
            return exact
        }
        return candidates.first { prefix.hasPrefix($0.name.replacingOccurrences(of: " ", with: "").uppercased()) }
    }

    /// Whether a BLE device name looks like a Niimbot printer.
    public static func looksLikePrinter(_ name: String) -> Bool {
        detect(advertisedName: name) != nil
    }
}
