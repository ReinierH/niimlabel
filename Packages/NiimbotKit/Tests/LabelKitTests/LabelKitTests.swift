import XCTest
import NiimbotKit
@testable import LabelKit

final class BarcodeTests: XCTestCase {
    func testCode128PatternWidths() {
        for (index, pattern) in BarcodeEncoder.code128Patterns.enumerated() {
            let sum = pattern.reduce(0) { $0 + Int(String($1))! }
            XCTAssertEqual(sum, index == 106 ? 13 : 11, "pattern \(index)")
        }
    }

    func testCode128Values() throws {
        // "Wikipedia" in set B: (104 + Σ i·v) mod 103 = 88
        XCTAssertEqual(try BarcodeEncoder.code128Values("Wikipedia"), [104, 55, 73, 75, 73, 80, 69, 68, 73, 65, 88, 106])
        // Pure digits use set C.
        XCTAssertEqual(try BarcodeEncoder.code128Values("123456"), [105, 12, 34, 56, (105 + 12 + 68 + 168) % 103, 106])
        // Odd digit run: first digit in B, then C.
        let values = try BarcodeEncoder.code128Values("12345")
        XCTAssertEqual(Array(values.prefix(4)), [104, 17, 99, 23])
        XCTAssertThrowsError(try BarcodeEncoder.code128Values("é"))
    }

    func testEAN13() throws {
        let barcode = try BarcodeEncoder.encode("400638133393", as: .ean13)
        XCTAssertEqual(barcode.text, "4006381333931")
        XCTAssertEqual(barcode.modules.count, 95)
        XCTAssertThrowsError(try BarcodeEncoder.encode("4006381333930", as: .ean13))
        XCTAssertEqual(try BarcodeEncoder.encode("9638507", as: .ean8).text, "96385074")
        XCTAssertEqual(try BarcodeEncoder.encode("03600029145", as: .upca).text, "036000291452")
    }

    func testCode39AndITF() throws {
        for (char, pattern) in BarcodeEncoder.code39Patterns {
            XCTAssertEqual(pattern.filter { $0 == "1" }.count, 3, "\(char)")
        }
        XCTAssertEqual(try BarcodeEncoder.encode("abc", as: .code39).text, "ABC")
        XCTAssertEqual(try BarcodeEncoder.encode("123", as: .itf).text, "0123")
    }

    func testQROrientation() throws {
        let matrix = try XCTUnwrap(QRCodeEncoder.matrix(for: "hallo", correction: .medium))
        let n = matrix.count
        XCTAssertEqual(n, 21)
        // Finder patterns at top-left, top-right and bottom-left; not at bottom-right.
        XCTAssertTrue((0 ..< 7).allSatisfy { matrix[0][$0] && matrix[0][n - 1 - $0] && matrix[n - 1][$0] })
        XCTAssertFalse((0 ..< 7).allSatisfy { matrix[n - 1][n - 1 - $0] })
    }
}

final class VariableTests: XCTestCase {
    func testResolve() {
        let date = DateComponents(calendar: .init(identifier: .gregorian), year: 2026, month: 3, day: 4, hour: 9, minute: 5).date!
        let context = VariableContext(counter: 7, row: ["Naam": "Jan"], date: date)
        XCTAssertEqual(VariableResolver.resolve("#{teller:3} {naam} {datum} {tijd} {onbekend}", with: context),
                       "#007 Jan 04-03-2026 09:05 {onbekend}")
        XCTAssertEqual(VariableResolver.dataColumns(in: ["teller:3", "Naam", "datum"]), ["Naam"])
    }

    func testCSV() {
        let table = CSVTable.parse("Naam;Prijs\n\"Kaas; jong\";\"4,50\"\nMelk;1\n")
        XCTAssertEqual(table.headers, ["Naam", "Prijs"])
        XCTAssertEqual(table.rows, [["Kaas; jong", "4,50"], ["Melk", "1"]])
        XCTAssertEqual(table.record(at: 1)["Prijs"], "1")
    }
}

final class RendererTests: XCTestCase {
    func testRendersAndRotatesForB1() {
        var document = LabelDocument(name: "Test", widthMM: 50, heightMM: 30)
        document.elements = [
            LabelElement(x: 0, y: 0, width: 50, height: 2, content: .shape(ShapeContent(kind: .rectangle, filled: true))),
            LabelElement(x: 5, y: 5, width: 40, height: 10, content: .text(TextContent(text: "Hallo {teller}", fontSize: 20))),
            LabelElement(x: 5, y: 16, width: 40, height: 12, content: .barcode(BarcodeContent(value: "12345678"))),
        ]
        let rendered = LabelRenderer.shared.render(document, dotsPerMM: 8)
        XCTAssertEqual(rendered.bitmap.width, 400)
        XCTAssertEqual(rendered.bitmap.height, 240)
        XCTAssertTrue(rendered.issues.isEmpty, "\(rendered.issues)")
        // Filled bar at the top: row 0..15 fully black.
        XCTAssertTrue(rendered.bitmap[200, 2])
        XCTAssertFalse(rendered.bitmap[200, 30])

        let printable = LabelRenderer.shared.printBitmap(for: document, model: .b1)
        XCTAssertEqual(printable.width, 384) // 50 mm label clipped to the 48 mm head
        XCTAssertEqual(printable.height, 240)

        var narrow = document
        narrow.widthMM = 40
        narrow.heightMM = 12
        narrow.printRotation = 90
        let d11 = LabelRenderer.shared.printBitmap(for: narrow, model: PrinterModel.named("D11")!)
        XCTAssertEqual(d11.width, 96)
        XCTAssertEqual(d11.height, 320)
    }

    func testImageDithering() throws {
        // 2×1 PNG: black and white pixel, generated in memory.
        let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)

        let image = ImageContent(data: data as Data, dither: .threshold, keepAspectRatio: false)
        let processed = try XCTUnwrap(LabelRenderer.processImage(image, width: 20, height: 10))
        XCTAssertEqual(processed.width, 20)
    }
}
