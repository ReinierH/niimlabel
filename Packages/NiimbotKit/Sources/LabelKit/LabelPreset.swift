import Foundation
import NiimbotKit

/// Common Niimbot label roll sizes. `widthMM` × `heightMM` is the design orientation.
public struct LabelPreset: Identifiable, Hashable, Sendable {
    public let widthMM: Double
    public let heightMM: Double
    public let printRotation: Int
    public let labelType: LabelType
    public let note: String?

    public var id: String { "\(widthMM)x\(heightMM)-\(printRotation)-\(labelType.rawValue)" }

    public var name: String {
        let base = "\(widthMM.formattedMM) × \(heightMM.formattedMM) mm"
        return note.map { "\(base) – \($0)" } ?? base
    }

    /// Width of the label across the print head after rotation.
    public var acrossHeadMM: Double { printRotation % 180 == 0 ? widthMM : heightMM }

    public init(_ width: Double, _ height: Double, rotation: Int = 0, type: LabelType = .withGaps, note: String? = nil) {
        widthMM = width
        heightMM = height
        printRotation = rotation
        labelType = type
        self.note = note
    }

    /// Presets for wide printers (B1, B21, B3S, B203).
    public static let wide: [LabelPreset] = [
        LabelPreset(50, 30), LabelPreset(50, 20), LabelPreset(50, 15), LabelPreset(50, 40), LabelPreset(50, 50),
        LabelPreset(50, 70), LabelPreset(50, 80), LabelPreset(40, 30), LabelPreset(40, 20), LabelPreset(40, 40),
        LabelPreset(40, 60), LabelPreset(40, 70), LabelPreset(30, 20), LabelPreset(30, 15), LabelPreset(30, 30),
        LabelPreset(25, 25), LabelPreset(25, 15), LabelPreset(20, 10), LabelPreset(30, 40, note: "staand"),
        LabelPreset(50, 30, type: .transparent, note: "transparant"),
        LabelPreset(50, 30, type: .continuous, note: "doorlopend"),
    ]

    /// Presets for narrow printers (D11, D110, D101, B18); designed landscape, printed rotated.
    public static let narrow: [LabelPreset] = [
        LabelPreset(30, 12, rotation: 90), LabelPreset(40, 12, rotation: 90), LabelPreset(22, 12, rotation: 90),
        LabelPreset(30, 14, rotation: 90), LabelPreset(40, 14, rotation: 90), LabelPreset(50, 14, rotation: 90),
        LabelPreset(30, 15, rotation: 90), LabelPreset(26, 15, rotation: 90), LabelPreset(75, 12, rotation: 90),
        LabelPreset(109, 12.5, rotation: 90, note: "kabellabel"),
    ]

    public static func presets(for model: PrinterModel) -> [LabelPreset] {
        let head = model.printheadWidthMM * 1.05
        return (model.isWideFormat ? wide : narrow).filter { $0.acrossHeadMM <= max(head, 12) }
    }
}
