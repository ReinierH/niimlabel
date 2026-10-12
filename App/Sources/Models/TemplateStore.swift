import Foundation
import LabelKit
import Observation

/// Persists the user's label designs as JSON in Application Support.
@MainActor
@Observable
final class TemplateStore {
    private(set) var documents: [LabelDocument] = []
    var loadError: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NiimLabel", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("labels.json")
        load()
    }

    func document(_ id: UUID?) -> LabelDocument? {
        guard let id else { return nil }
        return documents.first { $0.id == id }
    }

    @discardableResult
    func add(_ document: LabelDocument) -> LabelDocument {
        documents.insert(document, at: 0)
        scheduleSave()
        return document
    }

    func update(_ document: LabelDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index] = document
        scheduleSave()
    }

    func delete(_ id: UUID) {
        documents.removeAll { $0.id == id }
        scheduleSave()
    }

    func duplicate(_ id: UUID) -> LabelDocument? {
        guard var copy = document(id) else { return nil }
        copy.id = UUID()
        copy.name += " (kopie)"
        copy.modified = .now
        copy.elements = copy.elements.map { var element = $0; element.id = UUID(); return element }
        if let index = documents.firstIndex(where: { $0.id == id }) {
            documents.insert(copy, at: index + 1)
        } else {
            documents.insert(copy, at: 0)
        }
        scheduleSave()
        return copy
    }

    // MARK: Import / export

    nonisolated static func encode(_ document: LabelDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    nonisolated static func decode(_ data: Data) throws -> LabelDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LabelDocument.self, from: data)
    }

    func importDocument(from data: Data) throws -> LabelDocument {
        var document = try Self.decode(data)
        document.id = UUID()
        document.modified = .now
        return add(document)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            documents = SampleLabels.all
            scheduleSave()
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            documents = try decoder.decode([LabelDocument].self, from: data)
        } catch {
            loadError = "Labels konden niet worden geladen: \(error.localizedDescription)"
            // Keep the unreadable file instead of overwriting it.
            try? FileManager.default.copyItem(at: fileURL, to: fileURL.appendingPathExtension("backup-\(Int(Date().timeIntervalSince1970))"))
            documents = SampleLabels.all
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(documents).write(to: fileURL, options: .atomic)
        } catch {
            loadError = "Opslaan mislukt: \(error.localizedDescription)"
        }
    }
}

enum SampleLabels {
    static var all: [LabelDocument] {
        [address, product, qr]
    }

    static var address: LabelDocument {
        LabelDocument(name: "Adreslabel", widthMM: 50, heightMM: 30, printRotation: 90, elements: [
            LabelElement(x: 3, y: 3, width: 44, height: 7,
                         content: .text(TextContent(text: "Jan Jansen", fontSize: 14, bold: true))),
            LabelElement(x: 3, y: 10.5, width: 44, height: 12,
                         content: .text(TextContent(text: "Dorpsstraat 1\n1234 AB Amsterdam", fontSize: 10, verticalAlignment: .top))),
            LabelElement(x: 3, y: 24, width: 44, height: 0.6, content: .shape(ShapeContent(kind: .line, strokeMM: 0.3))),
            LabelElement(x: 3, y: 25, width: 44, height: 3.5,
                         content: .text(TextContent(text: "Verzonden {datum}", fontSize: 7, alignment: .right))),
        ])
    }

    static var product: LabelDocument {
        LabelDocument(name: "Product met barcode", widthMM: 50, heightMM: 30, printRotation: 90, elements: [
            LabelElement(x: 2, y: 2, width: 46, height: 8,
                         content: .text(TextContent(text: "Product", fontSize: 16, bold: true, alignment: .center, autoFit: true))),
            LabelElement(x: 3, y: 11, width: 44, height: 13,
                         content: .barcode(BarcodeContent(value: "ART-{teller:4}", symbology: .code128))),
            LabelElement(x: 2, y: 25, width: 46, height: 4,
                         content: .text(TextContent(text: "€ 4,95", fontSize: 9, bold: true, alignment: .center))),
        ])
    }

    static var qr: LabelDocument {
        LabelDocument(name: "QR-code", widthMM: 40, heightMM: 30, printRotation: 90, elements: [
            LabelElement(x: 2, y: 3, width: 24, height: 24, content: .qrCode(QRContent(value: "https://computhings.nl"))),
            LabelElement(x: 26.5, y: 3, width: 12, height: 24,
                         content: .text(TextContent(text: "Scan\nmij", fontSize: 12, bold: true, alignment: .center))),
            LabelElement(x: 0.8, y: 0.8, width: 38.4, height: 28.4,
                         content: .shape(ShapeContent(kind: .rectangle, strokeMM: 0.4, cornerRadiusMM: 2))),
        ])
    }
}
