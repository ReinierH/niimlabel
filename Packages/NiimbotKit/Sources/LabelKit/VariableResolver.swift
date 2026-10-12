import Foundation

/// Values available while rendering one label.
public struct VariableContext: Sendable {
    public var counter: Int
    public var row: [String: String]
    public var date: Date

    public init(counter: Int = 1, row: [String: String] = [:], date: Date = .now) {
        self.counter = counter
        self.row = row
        self.date = date
    }
}

/// Replaces `{…}` placeholders:
/// `{teller}` / `{counter}`, `{teller:4}` (zero padded), `{datum}`, `{tijd}`, `{datumtijd}`,
/// `{datum:dd-MM-yyyy}` (custom format), and `{Kolom}` for CSV columns.
public enum VariableResolver {
    private static let pattern = try! NSRegularExpression(pattern: "\\{([^{}\\n]+)\\}")

    public static func placeholders(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..., in: text)
        return Set(pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// Placeholder names that are filled from CSV data (everything that is not built in).
    public static func dataColumns(in names: Set<String>) -> Set<String> {
        names.filter { builtIn(name($0)) == false }
    }

    public static func resolve(_ text: String, with context: VariableContext) -> String {
        guard text.contains("{") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
            result += text[last ..< whole.lowerBound]
            result += value(for: String(text[inner]), context: context) ?? String(text[whole])
            last = whole.upperBound
        }
        result += text[last...]
        return result
    }

    private static func name(_ token: String) -> String {
        token.split(separator: ":", maxSplits: 1).first.map { String($0).lowercased() } ?? ""
    }

    private static func builtIn(_ name: String) -> Bool {
        ["teller", "counter", "nr", "datum", "date", "tijd", "time", "datumtijd", "datetime"].contains(name)
    }

    private static func value(for token: String, context: VariableContext) -> String? {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let argument = parts.count > 1 ? parts[1] : nil

        switch key.lowercased() {
        case "teller", "counter", "nr":
            if let argument, let width = Int(argument) {
                let digits = String(context.counter)
                return String(repeating: "0", count: max(0, width - digits.count)) + digits
            }
            return String(context.counter)
        case "datum", "date":
            return format(context.date, argument ?? "dd-MM-yyyy")
        case "tijd", "time":
            return format(context.date, argument ?? "HH:mm")
        case "datumtijd", "datetime":
            return format(context.date, argument ?? "dd-MM-yyyy HH:mm")
        default:
            if let exact = context.row[key] { return exact }
            return context.row.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }
    }

    private static func format(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

/// Minimal RFC 4180 CSV reader with delimiter detection (`,` `;` or tab).
public struct CSVTable: Equatable, Sendable {
    public var headers: [String]
    public var rows: [[String]]

    public init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
    }

    public func record(at index: Int) -> [String: String] {
        guard rows.indices.contains(index) else { return [:] }
        var record: [String: String] = [:]
        for (column, header) in headers.enumerated() {
            record[header] = column < rows[index].count ? rows[index][column] : ""
        }
        return record
    }

    public static func parse(_ text: String) -> CSVTable {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let delimiter: Character = [";", "\t", ","].max { a, b in
            firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
        } ?? ","

        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var iterator = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        if iterator.first == "\u{FEFF}" { iterator.removeFirst() }

        var i = 0
        while i < iterator.count {
            let c = iterator[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < iterator.count, iterator[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                record.append(field); field = ""
            } else if c == "\n" {
                record.append(field); field = ""
                records.append(record); record = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !record.isEmpty { record.append(field); records.append(record) }
        records.removeAll { $0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

        guard let header = records.first else { return CSVTable(headers: [], rows: []) }
        return CSVTable(headers: header.map { $0.trimmingCharacters(in: .whitespaces) }, rows: Array(records.dropFirst()))
    }
}
