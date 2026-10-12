import CoreGraphics
import CoreText
import Foundation
import ImageIO
import NiimbotKit

public struct RenderedLabel {
    /// 1-bit result in design orientation.
    public let bitmap: MonoBitmap
    /// Problems per element (invalid barcode data, overflowing text, …).
    public let issues: [UUID: String]
}

/// Renders label documents to 1-bit bitmaps. The same output drives the editor preview and the printer,
/// so what you see is exactly what is printed.
public final class LabelRenderer: @unchecked Sendable {
    public static let shared = LabelRenderer()

    private let imageCache = NSCache<NSString, CGImage>()

    public init() {
        imageCache.countLimit = 64
    }

    public func render(_ document: LabelDocument, dotsPerMM dpmm: Double, context: VariableContext = VariableContext()) -> RenderedLabel {
        let width = max(1, Int((document.widthMM * dpmm).rounded()))
        let height = max(1, Int((document.heightMM * dpmm).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return RenderedLabel(bitmap: MonoBitmap(width: width, height: height), issues: [:])
        }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var issues: [UUID: String] = [:]
        for element in document.elements {
            let frame = CGRect(x: (element.x * dpmm).rounded(), y: (element.y * dpmm).rounded(),
                               width: max(1, (element.width * dpmm).rounded()), height: max(1, (element.height * dpmm).rounded()))
            let quarter = ((element.rotation / 90) % 4 + 4) % 4
            let size = quarter % 2 == 0 ? frame.size : CGSize(width: frame.height, height: frame.width)

            ctx.saveGState()
            // Work in y-up coordinates centred on the element so rotation is a simple transform.
            ctx.translateBy(x: frame.midX, y: CGFloat(height) - frame.midY)
            ctx.rotate(by: -CGFloat(quarter) * .pi / 2)
            let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)

            let issue: String? = switch element.content {
            case let .text(text): drawText(text, in: rect, ctx: ctx, dpmm: dpmm, context: context)
            case let .barcode(barcode): drawBarcode(barcode, in: rect, ctx: ctx, dpmm: dpmm, context: context)
            case let .qrCode(qr): drawQR(qr, in: rect, ctx: ctx, context: context)
            case let .image(image): drawImage(image, in: rect, ctx: ctx, cacheKey: element.id.uuidString)
            case let .shape(shape): drawShape(shape, in: rect, ctx: ctx, dpmm: dpmm)
            }
            if let issue { issues[element.id] = issue }
            ctx.restoreGState()
        }

        return RenderedLabel(bitmap: MonoBitmap(luminance: Self.pixels(of: ctx), width: width, height: height), issues: issues)
    }

    /// Bitmap ready to send: rotated to print orientation, offset applied and fitted to the print head.
    public func printBitmap(for document: LabelDocument, model: PrinterModel, context: VariableContext = VariableContext()) -> MonoBitmap {
        let dpmm = model.dotsPerMM
        let rotated = render(document, dotsPerMM: dpmm, context: context).bitmap.rotated(degrees: document.printRotation)
        let width = min(model.printheadPixels, (rotated.width + 7) / 8 * 8)
        return rotated.placed(inWidth: width, height: rotated.height,
                              dx: Int((document.offsetXMM * dpmm).rounded()), dy: Int((document.offsetYMM * dpmm).rounded()))
    }

    // MARK: - Elements

    private func drawText(_ text: TextContent, in rect: CGRect, ctx: CGContext, dpmm: Double, context: VariableContext) -> String? {
        let string = VariableResolver.resolve(text.text, with: context)
        if text.inverted {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(rect)
        }
        guard !string.isEmpty else { return nil }

        let pointToPixel = dpmm * 25.4 / 72
        var fontSize = CGFloat(text.fontSize * pointToPixel)
        let unconstrained = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)

        if text.autoFit {
            var low: CGFloat = 2, high = max(4, rect.height * 1.5)
            for _ in 0 ..< 14 {
                let mid = (low + high) / 2
                let measured = Self.measure(Self.attributed(string, text, size: mid, pointToPixel: pointToPixel), constraint: unconstrained)
                if measured.width <= rect.width, measured.height <= rect.height { low = mid } else { high = mid }
            }
            fontSize = low
        }

        let attributed = Self.attributed(string, text, size: fontSize, pointToPixel: pointToPixel)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let layoutWidth = text.autoFit ? rect.width + 1 : rect.width
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                      CGSize(width: layoutWidth, height: .greatestFiniteMagnitude), nil)
        let textHeight = ceil(suggested.height)
        let originY: CGFloat = switch text.verticalAlignment {
        case .top: rect.maxY - textHeight
        case .center: rect.midY - textHeight / 2
        case .bottom: rect.minY
        }

        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.textMatrix = .identity
        let path = CGPath(rect: CGRect(x: rect.minX, y: originY, width: layoutWidth, height: textHeight + 1), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), ctx)
        ctx.restoreGState()

        return textHeight > rect.height + 1 ? "Tekst past niet in het vak" : nil
    }

    private static func measure(_ attributed: CFAttributedString, constraint: CGSize) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        return CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
    }

    static func font(family: String, size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let base = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    private static func attributed(_ string: String, _ text: TextContent, size: CGFloat, pointToPixel: Double) -> CFAttributedString {
        let font = font(family: text.fontFamily, size: size, bold: text.bold, italic: text.italic)
        var alignment: CTTextAlignment = switch text.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        var spacing = CGFloat(text.lineSpacing * pointToPixel)
        let style = withUnsafeBytes(of: &alignment) { alignmentBytes in
            withUnsafeBytes(of: &spacing) { spacingBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: alignmentBytes.count, value: alignmentBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: spacingBytes.count, value: spacingBytes.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: text.inverted ? 1 : 0, alpha: 1),
            kCTParagraphStyleAttributeName: style,
        ]
        if text.underline { attributes[kCTUnderlineStyleAttributeName] = CTUnderlineStyle.single.rawValue }
        return CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)
    }

    private func drawBarcode(_ barcode: BarcodeContent, in rect: CGRect, ctx: CGContext, dpmm: Double, context: VariableContext) -> String? {
        let value = VariableResolver.resolve(barcode.value, with: context)
        let encoded: LinearBarcode
        do {
            encoded = try BarcodeEncoder.encode(value, as: barcode.symbology)
        } catch {
            Self.drawPlaceholder(in: rect, ctx: ctx)
            return error.localizedDescription
        }

        let textHeight: CGFloat = barcode.showText ? ceil(CGFloat(barcode.textSize * dpmm * 25.4 / 72) * 1.15) : 0
        let count = CGFloat(encoded.modules.count)
        let module = max(1, floor(rect.width / count))
        let total = module * count
        let startX = rect.minX + floor((rect.width - total) / 2)
        let barBottom = rect.minY + textHeight
        let barHeight = max(1, rect.maxY - barBottom)

        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setFillColor(gray: 0, alpha: 1)
        var index = 0
        while index < encoded.modules.count {
            guard encoded.modules[index] else { index += 1; continue }
            var run = 1
            while index + run < encoded.modules.count, encoded.modules[index + run] { run += 1 }
            ctx.fill(CGRect(x: startX + CGFloat(index) * module, y: barBottom, width: CGFloat(run) * module, height: barHeight))
            index += run
        }
        ctx.restoreGState()

        if barcode.showText {
            let style = TextContent(text: encoded.text, fontFamily: "Helvetica", fontSize: barcode.textSize, alignment: .center)
            let attributed = Self.attributed(encoded.text, style, size: CGFloat(barcode.textSize * dpmm * 25.4 / 72), pointToPixel: dpmm * 25.4 / 72)
            let line = CTLineCreateWithAttributedString(attributed)
            let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: rect.midX - lineWidth / 2, y: rect.minY + textHeight * 0.18)
            CTLineDraw(line, ctx)
        }

        return total > rect.width ? "Barcode is te breed voor het vak (vergroot de breedte)" : nil
    }

    private func drawQR(_ qr: QRContent, in rect: CGRect, ctx: CGContext, context: VariableContext) -> String? {
        let value = VariableResolver.resolve(qr.value, with: context)
        guard let matrix = QRCodeEncoder.matrix(for: value, correction: qr.correction) else {
            Self.drawPlaceholder(in: rect, ctx: ctx)
            return value.isEmpty ? "Geen inhoud" : "Te veel gegevens voor een QR-code"
        }
        let n = CGFloat(matrix.count)
        let module = max(1, floor(min(rect.width, rect.height) / n))
        let side = module * n
        let originX = rect.minX + floor((rect.width - side) / 2)
        let topY = rect.maxY - floor((rect.height - side) / 2)

        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setFillColor(gray: 0, alpha: 1)
        for (row, modules) in matrix.enumerated() {
            for (column, dark) in modules.enumerated() where dark {
                ctx.fill(CGRect(x: originX + CGFloat(column) * module, y: topY - CGFloat(row + 1) * module, width: module, height: module))
            }
        }
        ctx.restoreGState()
        return side > min(rect.width, rect.height) ? "QR-code is te groot voor het vak" : nil
    }

    private func drawImage(_ image: ImageContent, in rect: CGRect, ctx: CGContext, cacheKey: String) -> String? {
        let width = Int(rect.width), height = Int(rect.height)
        let key = "\(cacheKey)-\(image.data.count)-\(image.data.hashValue)-\(width)x\(height)-\(image.dither.rawValue)-\(Int(image.threshold))-\(image.invert)-\(image.keepAspectRatio)" as NSString

        let processed: CGImage
        if let cached = imageCache.object(forKey: key) {
            processed = cached
        } else {
            guard let made = Self.processImage(image, width: width, height: height) else {
                Self.drawPlaceholder(in: rect, ctx: ctx)
                return "Afbeelding kan niet worden gelezen"
            }
            imageCache.setObject(made, forKey: key)
            processed = made
        }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        ctx.draw(processed, in: CGRect(x: rect.minX, y: rect.minY, width: CGFloat(width), height: CGFloat(height)))
        ctx.restoreGState()
        return nil
    }

    /// Loads, scales (respecting EXIF orientation), flattens on white and dithers an image to the given pixel size.
    static func processImage(_ image: ImageContent, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let source = CGImageSourceCreateWithData(image.data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height) * 2,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var target = CGRect(x: 0, y: 0, width: width, height: height)
        if image.keepAspectRatio {
            let scale = min(CGFloat(width) / CGFloat(decoded.width), CGFloat(height) / CGFloat(decoded.height))
            let size = CGSize(width: CGFloat(decoded.width) * scale, height: CGFloat(decoded.height) * scale)
            target = CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2, width: size.width, height: size.height)
        }
        ctx.interpolationQuality = .high
        ctx.draw(decoded, in: target)

        var pixels = pixels(of: ctx)
        if image.invert { for i in pixels.indices { pixels[i] = 255 - pixels[i] } }
        Dithering.apply(image.dither, to: &pixels, width: width, height: height, threshold: image.threshold)
        return makeGrayImage(pixels, width: width, height: height)
    }

    private func drawShape(_ shape: ShapeContent, in rect: CGRect, ctx: CGContext, dpmm: Double) -> String? {
        let stroke = max(1, (shape.strokeMM * dpmm).rounded())
        ctx.saveGState()
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(stroke)
        switch shape.kind {
        case .line:
            ctx.setShouldAntialias(false)
            ctx.fill(CGRect(x: rect.minX, y: (rect.midY - stroke / 2).rounded(), width: rect.width, height: stroke))
        case .rectangle:
            let radius = min(CGFloat(shape.cornerRadiusMM * dpmm), min(rect.width, rect.height) / 2)
            if radius < 0.5 { ctx.setShouldAntialias(false) }
            let target = shape.filled ? rect : rect.insetBy(dx: stroke / 2, dy: stroke / 2)
            let r = max(0, min(radius, min(target.width, target.height) / 2))
            let path = CGPath(roundedRect: target, cornerWidth: r, cornerHeight: r, transform: nil)
            ctx.addPath(path)
            if shape.filled { ctx.fillPath() } else { ctx.strokePath() }
        case .ellipse:
            let target = shape.filled ? rect : rect.insetBy(dx: stroke / 2, dy: stroke / 2)
            ctx.addEllipse(in: target)
            if shape.filled { ctx.fillPath() } else { ctx.strokePath() }
        }
        ctx.restoreGState()
        return nil
    }

    private static func drawPlaceholder(in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Pixel helpers

    /// Top-to-bottom luminance rows of an 8-bit gray context.
    static func pixels(of ctx: CGContext) -> [UInt8] {
        let width = ctx.width, height = ctx.height, stride = ctx.bytesPerRow
        guard let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [UInt8](repeating: 255, count: width * height) }
        var out = [UInt8](repeating: 255, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width { out[y * width + x] = base[y * stride + x] }
        }
        return out
    }

    static func makeGrayImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension MonoBitmap {
    /// Gray image of the bitmap (black dots on white) for display.
    public func makeCGImage() -> CGImage? {
        LabelRenderer.makeGrayImage(luminance(), width: width, height: height)
    }
}
