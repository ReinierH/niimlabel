import Foundation
import NiimbotKit

/// A label design. All geometry is in millimetres, origin top-left.
public struct LabelDocument: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Design canvas size as shown in the editor.
    public var widthMM: Double
    public var heightMM: Double
    /// Clockwise rotation applied before sending, so the label's across-head side matches the print head.
    public var printRotation: Int
    public var labelType: LabelType
    /// nil = model default.
    public var density: Int?
    /// Fine-tuning in print orientation: X across the head, Y along the feed direction.
    public var offsetXMM: Double
    public var offsetYMM: Double
    public var elements: [LabelElement]
    public var modified: Date

    public init(id: UUID = UUID(), name: String, widthMM: Double, heightMM: Double, printRotation: Int = 0,
                labelType: LabelType = .withGaps, density: Int? = nil, offsetXMM: Double = 0, offsetYMM: Double = 0,
                elements: [LabelElement] = [], modified: Date = .now) {
        self.id = id
        self.name = name
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.printRotation = printRotation
        self.labelType = labelType
        self.density = density
        self.offsetXMM = offsetXMM
        self.offsetYMM = offsetYMM
        self.elements = elements
        self.modified = modified
    }

    public var sizeDescription: String {
        "\(widthMM.formattedMM) × \(heightMM.formattedMM) mm"
    }

    /// Placeholder names used anywhere in the document (e.g. `{Naam}`, `{counter}`).
    public var usedVariables: Set<String> {
        var names = Set<String>()
        for element in elements {
            for value in element.content.textValues {
                names.formUnion(VariableResolver.placeholders(in: value))
            }
        }
        return names
    }

    public func element(_ id: UUID) -> LabelElement? {
        elements.first { $0.id == id }
    }

    /// Default rotation for a new label. Niimbot rolls feed with the short side across the head, so a
    /// landscape design is rotated 90° whenever its height fits the head; otherwise it is sent unrotated.
    public static func suggestedRotation(widthMM: Double, heightMM: Double, printheadMM: Double) -> Int {
        heightMM <= printheadMM * 1.05 ? 90 : 0
    }
}

public struct LabelElement: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Clockwise rotation of the content inside its box: 0, 90, 180 or 270.
    public var rotation: Int
    public var content: ElementContent

    public init(id: UUID = UUID(), x: Double, y: Double, width: Double, height: Double, rotation: Int = 0, content: ElementContent) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.content = content
    }

    public var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public enum ElementContent: Codable, Equatable, Sendable {
    case text(TextContent)
    case barcode(BarcodeContent)
    case qrCode(QRContent)
    case image(ImageContent)
    case shape(ShapeContent)

    public var kindName: String {
        switch self {
        case .text: "Tekst"
        case .barcode: "Barcode"
        case .qrCode: "QR-code"
        case .image: "Afbeelding"
        case let .shape(shape): shape.kind.displayName
        }
    }

    public var systemImage: String {
        switch self {
        case .text: "textformat"
        case .barcode: "barcode"
        case .qrCode: "qrcode"
        case .image: "photo"
        case let .shape(shape): shape.kind.systemImage
        }
    }

    public var summary: String {
        switch self {
        case let .text(text): text.text.replacingOccurrences(of: "\n", with: " ")
        case let .barcode(barcode): barcode.value
        case let .qrCode(qr): qr.value
        case .image: "Afbeelding"
        case let .shape(shape): shape.kind.displayName
        }
    }

    var textValues: [String] {
        switch self {
        case let .text(text): [text.text]
        case let .barcode(barcode): [barcode.value]
        case let .qrCode(qr): [qr.value]
        case .image, .shape: []
        }
    }

    public var text: TextContent? {
        get { if case let .text(value) = self { value } else { nil } }
        set { if let newValue { self = .text(newValue) } }
    }

    public var barcode: BarcodeContent? {
        get { if case let .barcode(value) = self { value } else { nil } }
        set { if let newValue { self = .barcode(newValue) } }
    }

    public var qrCode: QRContent? {
        get { if case let .qrCode(value) = self { value } else { nil } }
        set { if let newValue { self = .qrCode(newValue) } }
    }

    public var image: ImageContent? {
        get { if case let .image(value) = self { value } else { nil } }
        set { if let newValue { self = .image(newValue) } }
    }

    public var shape: ShapeContent? {
        get { if case let .shape(value) = self { value } else { nil } }
        set { if let newValue { self = .shape(newValue) } }
    }
}

public enum HorizontalAlignment: String, Codable, CaseIterable, Sendable { case left, center, right }
public enum VerticalAlignment: String, Codable, CaseIterable, Sendable { case top, center, bottom }

public struct TextContent: Codable, Equatable, Sendable {
    public var text: String
    public var fontFamily: String
    /// Font size in points.
    public var fontSize: Double
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var alignment: HorizontalAlignment
    public var verticalAlignment: VerticalAlignment
    /// Shrink or grow the font so the text fills its box.
    public var autoFit: Bool
    /// White text on a black box.
    public var inverted: Bool
    /// Extra line spacing in points.
    public var lineSpacing: Double

    public init(text: String = "Tekst", fontFamily: String = "Helvetica", fontSize: Double = 14, bold: Bool = false,
                italic: Bool = false, underline: Bool = false, alignment: HorizontalAlignment = .left,
                verticalAlignment: VerticalAlignment = .center, autoFit: Bool = false, inverted: Bool = false,
                lineSpacing: Double = 0) {
        self.text = text
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.alignment = alignment
        self.verticalAlignment = verticalAlignment
        self.autoFit = autoFit
        self.inverted = inverted
        self.lineSpacing = lineSpacing
    }
}

public enum BarcodeSymbology: String, Codable, CaseIterable, Sendable, Identifiable {
    case code128, ean13, ean8, upca, code39, itf

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .code128: "Code 128"
        case .ean13: "EAN-13"
        case .ean8: "EAN-8"
        case .upca: "UPC-A"
        case .code39: "Code 39"
        case .itf: "ITF (Interleaved 2 of 5)"
        }
    }
}

public struct BarcodeContent: Codable, Equatable, Sendable {
    public var value: String
    public var symbology: BarcodeSymbology
    public var showText: Bool
    /// Human readable text size in points.
    public var textSize: Double

    public init(value: String = "123456789012", symbology: BarcodeSymbology = .code128, showText: Bool = true, textSize: Double = 8) {
        self.value = value
        self.symbology = symbology
        self.showText = showText
        self.textSize = textSize
    }
}

public enum QRCorrectionLevel: String, Codable, CaseIterable, Sendable {
    case low = "L", medium = "M", quartile = "Q", high = "H"

    public var displayName: String {
        switch self {
        case .low: "Laag (7%)"
        case .medium: "Gemiddeld (15%)"
        case .quartile: "Hoog (25%)"
        case .high: "Maximaal (30%)"
        }
    }
}

public struct QRContent: Codable, Equatable, Sendable {
    public var value: String
    public var correction: QRCorrectionLevel

    public init(value: String = "https://example.com", correction: QRCorrectionLevel = .medium) {
        self.value = value
        self.correction = correction
    }
}

public enum DitherMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case threshold, floydSteinberg, atkinson, ordered

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .threshold: "Drempel (zwart/wit)"
        case .floydSteinberg: "Floyd–Steinberg"
        case .atkinson: "Atkinson"
        case .ordered: "Geordend (Bayer)"
        }
    }
}

public struct ImageContent: Codable, Equatable, Sendable {
    /// Original image file data (PNG/JPEG/…).
    public var data: Data
    public var dither: DitherMode
    /// 0…255, pixels darker than this become black (threshold mode) — also acts as brightness for dithering.
    public var threshold: Double
    public var invert: Bool
    public var keepAspectRatio: Bool

    public init(data: Data, dither: DitherMode = .floydSteinberg, threshold: Double = 128, invert: Bool = false, keepAspectRatio: Bool = true) {
        self.data = data
        self.dither = dither
        self.threshold = threshold
        self.invert = invert
        self.keepAspectRatio = keepAspectRatio
    }
}

public enum ShapeKind: String, Codable, CaseIterable, Sendable {
    case rectangle, ellipse, line

    public var displayName: String {
        switch self {
        case .rectangle: "Rechthoek"
        case .ellipse: "Ellips"
        case .line: "Lijn"
        }
    }

    public var systemImage: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        }
    }
}

public struct ShapeContent: Codable, Equatable, Sendable {
    public var kind: ShapeKind
    public var strokeMM: Double
    public var filled: Bool
    public var cornerRadiusMM: Double

    public init(kind: ShapeKind = .rectangle, strokeMM: Double = 0.4, filled: Bool = false, cornerRadiusMM: Double = 0) {
        self.kind = kind
        self.strokeMM = strokeMM
        self.filled = filled
        self.cornerRadiusMM = cornerRadiusMM
    }
}

extension Double {
    public var formattedMM: String {
        let rounded = (self * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
