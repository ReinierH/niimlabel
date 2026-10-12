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

    /// Presets for wide printers (B1, B21, B3S, B203). The rolls feed with the short side across the
    /// print head, so labels are designed landscape and printed rotated 90°.
    public static let wide: [LabelPreset] = [
        (50, 30), (50, 20), (50, 15), (50, 40), (50, 50), (60, 40), (60, 30), (70, 40), (70, 50), (80, 50),
        (40, 30), (40, 20), (40, 40), (30, 20), (30, 15), (30, 30), (25, 25), (25, 15), (20, 10),
    ].map { LabelPreset($0.0, $0.1, rotation: 90) } + [
        LabelPreset(50, 30, rotation: 90, type: .transparent, note: "transparant"),
        LabelPreset(50, 30, rotation: 90, type: .continuous, note: "doorlopend"),
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
