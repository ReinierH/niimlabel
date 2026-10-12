import Foundation
import LabelKit
import NiimbotKit
import Observation

@MainActor
@Observable
final class AppModel {
    let store = TemplateStore()
    let editor = LabelEditor()
    let printer = PrinterController()

    var showPrintSheet = false
    var showNewLabelSheet = false
    var showPrinterPanel = false
    var showInspector = true

    var selectedDocumentID: UUID? {
        didSet {
            guard selectedDocumentID != oldValue else { return }
            editor.load(store.document(selectedDocumentID))
        }
    }

    init() {
        editor.onChange = { [weak self] document in self?.store.update(document) }
        selectedDocumentID = store.documents.first?.id
        editor.load(store.document(selectedDocumentID))
    }

    func create(_ document: LabelDocument) {
        store.add(document)
        selectedDocumentID = document.id
    }

    func duplicate(_ id: UUID) {
        if let copy = store.duplicate(id) { selectedDocumentID = copy.id }
    }

    func delete(_ id: UUID) {
        let index = store.documents.firstIndex { $0.id == id }
        store.delete(id)
        if selectedDocumentID == id {
            let remaining = store.documents
            selectedDocumentID = index.flatMap { remaining.indices.contains($0) ? remaining[$0].id : remaining.last?.id }
        }
    }

    func importDocument(_ data: Data) throws {
        let document = try store.importDocument(from: data)
        selectedDocumentID = document.id
    }
}

/// Settings for one print run.
struct PrintOptions: Equatable {
    enum Source: String, CaseIterable, Identifiable {
        case single, series, data
        var id: String { rawValue }
        var title: String {
            switch self {
            case .single: "Kopieën"
            case .series: "Nummering"
            case .data: "Gegevens (CSV)"
            }
        }
    }

    var source: Source = .single
    var copies = 1
    var seriesStart = 1
    var seriesCount = 10
    var seriesStep = 1
    var dataFrom = 1
    var dataTo = 1
    var copiesPerLabel = 1
    var density = 3
    var labelType: LabelType = .withGaps
}

enum PrintPlanner {
    static func contexts(for options: PrintOptions, table: CSVTable?, date: Date = .now) -> [VariableContext] {
        switch options.source {
        case .single:
            return [VariableContext(counter: options.seriesStart, date: date)]
        case .series:
            return (0 ..< max(1, options.seriesCount)).map {
                VariableContext(counter: options.seriesStart + $0 * options.seriesStep, date: date)
            }
        case .data:
            guard let table, !table.rows.isEmpty else { return [] }
            let from = max(1, min(options.dataFrom, table.rows.count))
            let to = max(from, min(options.dataTo, table.rows.count))
            return (from ... to).map { VariableContext(counter: $0, row: table.record(at: $0 - 1), date: date) }
        }
    }

    /// Renders every label and merges consecutive identical labels into one page with a higher quantity.
    static func pages(for document: LabelDocument, model: PrinterModel, options: PrintOptions, table: CSVTable?) -> [PrintPage] {
        let quantity = options.source == .single ? max(1, options.copies) : max(1, options.copiesPerLabel)
        var pages: [PrintPage] = []
        for context in contexts(for: options, table: table) {
            let bitmap = LabelRenderer.shared.printBitmap(for: document, model: model, context: context)
            if let last = pages.last, last.bitmap == bitmap, last.quantity + quantity <= 65535 {
                pages[pages.count - 1].quantity += quantity
            } else {
                pages.append(PrintPage(bitmap: bitmap, quantity: quantity))
            }
        }
        return pages
    }
}
