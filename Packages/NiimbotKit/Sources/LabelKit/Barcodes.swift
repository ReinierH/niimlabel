import CoreImage
import Foundation

public struct LinearBarcode: Equatable, Sendable {
    /// One entry per module, true = bar.
    public var modules: [Bool]
    /// Human readable text (including computed check digits).
    public var text: String
}

public enum BarcodeError: LocalizedError, Equatable {
    case empty
    case invalidCharacters(String)
    case invalidLength(String)
    case invalidCheckDigit(expected: Int)

    public var errorDescription: String? {
        switch self {
        case .empty: "Geen inhoud"
        case let .invalidCharacters(detail): "Ongeldige tekens: \(detail)"
        case let .invalidLength(detail): detail
        case let .invalidCheckDigit(expected): "Controlecijfer klopt niet (verwacht \(expected))"
        }
    }
}

public enum BarcodeEncoder {
    public static func encode(_ value: String, as symbology: BarcodeSymbology) throws -> LinearBarcode {
        guard !value.isEmpty else { throw BarcodeError.empty }
        switch symbology {
        case .code128: return try code128(value)
        case .ean13: return try ean13(value)
        case .ean8: return try ean8(value)
        case .upca: return try upca(value)
        case .code39: return try code39(value)
        case .itf: return try itf(value)
        }
    }

    // MARK: Code 128

    static let code128Patterns: [String] = [
        "212222", "222122", "222221", "121223", "121322", "131222", "122213", "122312", "132212", "221213",
        "221312", "231212", "112232", "122132", "122231", "113222", "123122", "123221", "223211", "221132",
        "221231", "213212", "223112", "312131", "311222", "321122", "321221", "312212", "322112", "322211",
        "212123", "212321", "232121", "111323", "131123", "131321", "112313", "132113", "132311", "211313",
        "231113", "231311", "112133", "112331", "132131", "113123", "113321", "133121", "313121", "211331",
        "231131", "213113", "213311", "213131", "311123", "311321", "331121", "312113", "312311", "332111",
        "314111", "221411", "431111", "111224", "111422", "121124", "121421", "141122", "141221", "112214",
        "112412", "122114", "122411", "142112", "142211", "241211", "221114", "413111", "241112", "134111",
        "111242", "121142", "121241", "114212", "124112", "124211", "411212", "421112", "421211", "212141",
        "214121", "412121", "111143", "111341", "131141", "114113", "114311", "411113", "411311", "113141",
        "114131", "311141", "411131", "211412", "211214", "211232", "2331112",
    ]

    /// Code values for Code 128 using sets B and C (C for digit runs).
    static func code128Values(_ value: String) throws -> [Int] {
        let chars = Array(value)
        if let bad = chars.first(where: { !($0.isASCII && (32 ... 126).contains($0.asciiValue ?? 0)) }) {
            throw BarcodeError.invalidCharacters("‘\(bad)’ kan niet in Code 128")
        }
        enum CodeSet { case b, c }
        var values: [Int] = []
        var current: CodeSet?

        func use(_ set: CodeSet) {
            guard current != set else { return }
            if current == nil { values.append(set == .b ? 104 : 105) } else { values.append(set == .b ? 100 : 99) }
            current = set
        }

        var i = 0
        while i < chars.count {
            var run = 0
            while i + run < chars.count, chars[i + run].isWholeNumber, chars[i + run].isASCII { run += 1 }
            let atEdge = i == 0 || i + run == chars.count
            if run >= 6 || (run >= 4 && atEdge) {
                if run % 2 == 1 {
                    if current == .c {
                        run -= 1 // already in set C: leave the last digit for set B
                    } else {
                        use(.b)
                        values.append(Int(chars[i].asciiValue!) - 32)
                        i += 1
                        run -= 1
                    }
                }
                use(.c)
                for pair in stride(from: 0, to: run, by: 2) {
                    values.append(Int(String(chars[i + pair ... i + pair + 1]))!)
                }
                i += run
            } else {
                use(.b)
                values.append(Int(chars[i].asciiValue!) - 32)
                i += 1
            }
        }

        var checksum = values[0]
        for (position, value) in values.enumerated().dropFirst() { checksum += position * value }
        values.append(checksum % 103)
        values.append(106)
        return values
    }

    static func code128(_ value: String) throws -> LinearBarcode {
        var modules: [Bool] = []
        for code in try code128Values(value) {
            for (index, width) in code128Patterns[code].enumerated() {
                modules += Array(repeating: index % 2 == 0, count: Int(String(width))!)
            }
        }
        return LinearBarcode(modules: modules, text: value)
    }

    // MARK: EAN / UPC

    static let eanL = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
    static let eanG = ["0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111"]
    static let eanR = ["1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100"]
    static let eanParity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]

    static func digits(_ value: String) throws -> [Int] {
        let trimmed = value.replacingOccurrences(of: " ", with: "")
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw BarcodeError.invalidCharacters("alleen cijfers toegestaan") }
        return trimmed.map { Int(String($0))! }
    }

    /// GS1 check digit: weights 3,1,3,… from the rightmost data digit.
    public static func gs1CheckDigit(_ digits: [Int]) -> Int {
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() { sum += digit * (offset % 2 == 0 ? 3 : 1) }
        return (10 - sum % 10) % 10
    }

    static func withCheckDigit(_ value: String, dataLength: Int, name: String) throws -> [Int] {
        var digits = try digits(value)
        if digits.count == dataLength {
            digits.append(gs1CheckDigit(digits))
        } else if digits.count == dataLength + 1 {
            let expected = gs1CheckDigit(Array(digits.dropLast()))
            guard expected == digits.last else { throw BarcodeError.invalidCheckDigit(expected: expected) }
        } else {
            throw BarcodeError.invalidLength("\(name) heeft \(dataLength) of \(dataLength + 1) cijfers nodig")
        }
        return digits
    }

    static func bits(_ pattern: String) -> [Bool] { pattern.map { $0 == "1" } }

    static func ean13(_ value: String) throws -> LinearBarcode {
        let d = try withCheckDigit(value, dataLength: 12, name: "EAN-13")
        var modules = bits("101")
        let parity = Array(eanParity[d[0]])
        for i in 1 ... 6 { modules += bits(parity[i - 1] == "L" ? eanL[d[i]] : eanG[d[i]]) }
        modules += bits("01010")
        for i in 7 ... 12 { modules += bits(eanR[d[i]]) }
        modules += bits("101")
        return LinearBarcode(modules: modules, text: d.map(String.init).joined())
    }

    static func ean8(_ value: String) throws -> LinearBarcode {
        let d = try withCheckDigit(value, dataLength: 7, name: "EAN-8")
        var modules = bits("101")
        for i in 0 ..< 4 { modules += bits(eanL[d[i]]) }
        modules += bits("01010")
        for i in 4 ..< 8 { modules += bits(eanR[d[i]]) }
        modules += bits("101")
        return LinearBarcode(modules: modules, text: d.map(String.init).joined())
    }

    static func upca(_ value: String) throws -> LinearBarcode {
        let d = try withCheckDigit(value, dataLength: 11, name: "UPC-A")
        var barcode = try ean13("0" + d.map(String.init).joined())
        barcode.text = String(barcode.text.dropFirst())
        return barcode
    }

    // MARK: Code 39

    static let code39Patterns: [Character: String] = [
        "0": "000110100", "1": "100100001", "2": "001100001", "3": "101100000", "4": "000110001",
        "5": "100110000", "6": "001110000", "7": "000100101", "8": "100100100", "9": "001100100",
        "A": "100001001", "B": "001001001", "C": "101001000", "D": "000011001", "E": "100011000",
        "F": "001011000", "G": "000001101", "H": "100001100", "I": "001001100", "J": "000011100",
        "K": "100000011", "L": "001000011", "M": "101000010", "N": "000010011", "O": "100010010",
        "P": "001010010", "Q": "000000111", "R": "100000110", "S": "001000110", "T": "000010110",
        "U": "110000001", "V": "011000001", "W": "111000000", "X": "010010001", "Y": "110010000",
        "Z": "011010000", "-": "010000101", ".": "110000100", " ": "011000100", "*": "010010100",
        "$": "010101000", "/": "010100010", "+": "010001010", "%": "000101010",
    ]

    static func code39(_ value: String) throws -> LinearBarcode {
        let text = value.uppercased()
        if let bad = text.first(where: { code39Patterns[$0] == nil || $0 == "*" }) {
            throw BarcodeError.invalidCharacters("‘\(bad)’ kan niet in Code 39")
        }
        var modules: [Bool] = []
        for (index, char) in ("*" + text + "*").enumerated() {
            if index > 0 { modules.append(false) }
            for (element, wide) in code39Patterns[char]!.enumerated() {
                modules += Array(repeating: element % 2 == 0, count: wide == "1" ? 3 : 1)
            }
        }
        return LinearBarcode(modules: modules, text: text)
    }

    // MARK: ITF

    static let itfPatterns = ["00110", "10001", "01001", "11000", "00101", "10100", "01100", "00011", "10010", "01010"]

    static func itf(_ value: String) throws -> LinearBarcode {
        var d = try digits(value)
        if d.count % 2 == 1 { d.insert(0, at: 0) }
        var modules = bits("1010")
        for pair in stride(from: 0, to: d.count, by: 2) {
            let bars = Array(itfPatterns[d[pair]])
            let spaces = Array(itfPatterns[d[pair + 1]])
            for i in 0 ..< 5 {
                modules += Array(repeating: true, count: bars[i] == "1" ? 3 : 1)
                modules += Array(repeating: false, count: spaces[i] == "1" ? 3 : 1)
            }
        }
        modules += [true, true, true, false, true]
        return LinearBarcode(modules: modules, text: d.map(String.init).joined())
    }
}

public enum QRCodeEncoder {
    /// Module matrix (row-major, true = dark) without quiet zone.
    public static func matrix(for value: String, correction: QRCorrectionLevel) -> [[Bool]]? {
        guard !value.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue(correction.rawValue, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard width > 0, height > 0, let image = context.createCGImage(output, from: extent),
              let gray = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        gray.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = LabelRenderer.pixels(of: gray)

        var rows: [[Bool]] = (0 ..< height).map { y in (0 ..< width).map { x in pixels[y * width + x] < 128 } }
        // Trim the quiet zone the generator adds.
        while let first = rows.first, !first.contains(true) { rows.removeFirst() }
        while let last = rows.last, !last.contains(true) { rows.removeLast() }
        guard !rows.isEmpty else { return nil }
        let left = rows.compactMap { $0.firstIndex(of: true) }.min() ?? 0
        let right = rows.compactMap { $0.lastIndex(of: true) }.max() ?? (width - 1)
        return rows.map { Array($0[left ... right]) }
    }
}
