import Foundation
import ImageIO
import LabelKit
import Observation
import SwiftUI

/// Editing session for one label: selection, mutations and undo/redo.
@MainActor
@Observable
final class LabelEditor {
    private(set) var document: LabelDocument?
    var selectedID: UUID?
    var snapToGrid = true
    /// Optional CSV data, used for the preview and for batch printing.
    var dataTable: CSVTable?
    var dataFileName: String?
    var previewRow = 0
    var previewCounter = 1

    /// Called after every change so the store can persist it.
    @ObservationIgnored var onChange: ((LabelDocument) -> Void)?

    @ObservationIgnored private var undoStack: [LabelDocument] = []
    @ObservationIgnored private var redoStack: [LabelDocument] = []
    @ObservationIgnored private var lastKey: String?
    @ObservationIgnored private var lastChange = Date.distantPast
    private(set) var undoCount = 0
    private(set) var redoCount = 0

    var canUndo: Bool { undoCount > 0 }
    var canRedo: Bool { redoCount > 0 }

    var selectedElement: LabelElement? {
        guard let selectedID else { return nil }
        return document?.element(selectedID)
    }

    var previewContext: VariableContext {
        VariableContext(counter: previewCounter, row: dataTable?.record(at: previewRow) ?? [:])
    }

    func load(_ document: LabelDocument?) {
        self.document = document
        selectedID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        syncCounts()
        lastKey = nil
    }

    // MARK: Mutation

    /// Applies a change and records an undo step. Changes with the same `key` within two seconds
    /// (e.g. a drag or typing in one field) are merged into one step.
    func modify(_ key: String? = nil, _ change: (inout LabelDocument) -> Void) {
        guard var updated = document else { return }
        let before = updated
        change(&updated)
        guard updated != before else { return }

        let now = Date()
        if key == nil || key != lastKey || now.timeIntervalSince(lastChange) > 2 {
            undoStack.append(before)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastKey = key
        lastChange = now
        updated.modified = now
        document = updated
        syncCounts()
        onChange?(updated)
    }

    func updateElement(_ id: UUID, key: String? = nil, _ change: (inout LabelElement) -> Void) {
        modify(key) { document in
            guard let index = document.elements.firstIndex(where: { $0.id == id }) else { return }
            change(&document.elements[index])
        }
    }

    func undo() {
        guard let previous = undoStack.popLast(), let current = document else { return }
        redoStack.append(current)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast(), let current = document else { return }
        undoStack.append(current)
        restore(next)
    }

    private func restore(_ snapshot: LabelDocument) {
        document = snapshot
        lastKey = nil
        if let selectedID, snapshot.element(selectedID) == nil { self.selectedID = nil }
        syncCounts()
        onChange?(snapshot)
    }

    private func syncCounts() {
        undoCount = undoStack.count
        redoCount = redoStack.count
    }

    // MARK: Bindings

    func binding<T>(_ path: WritableKeyPath<LabelDocument, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { self.document?[keyPath: path] ?? fallback },
            set: { value in self.modify("doc-\(path.hashValue)") { $0[keyPath: path] = value } }
        )
    }

    /// Binding to a property of an element. `element` is the fallback when the element disappears.
    func binding<T>(_ element: LabelElement, _ path: WritableKeyPath<LabelElement, T>) -> Binding<T> {
        Binding(
            get: { (self.document?.element(element.id) ?? element)[keyPath: path] },
            set: { value in self.updateElement(element.id, key: "el-\(element.id)-\(path.hashValue)") { $0[keyPath: path] = value } }
        )
    }

    // MARK: Element commands

    func add(_ content: ElementContent) {
        guard let document else { return }
        let w = document.widthMM, h = document.heightMM
        var size: CGSize = switch content {
        case .text: CGSize(width: w * 0.8, height: min(h * 0.3, 10))
        case .barcode: CGSize(width: w * 0.85, height: min(h * 0.45, 15))
        case .qrCode, .image: CGSize(width: min(w, h) * 0.7, height: min(w, h) * 0.7)
        case let .shape(shape): shape.kind == .line ? CGSize(width: w * 0.8, height: 1) : CGSize(width: w * 0.5, height: h * 0.5)
        }
        size.width = max(1, size.width)
        size.height = max(0.5, size.height)
        let element = LabelElement(x: ((w - size.width) / 2 * 2).rounded() / 2, y: ((h - size.height) / 2 * 2).rounded() / 2,
                                   width: size.width, height: size.height, content: content)
        modify { $0.elements.append(element) }
        selectedID = element.id
    }

    func addImage(data: Data) {
        guard let document else { return }
        var aspect = 1.0
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? Double, let ph = props[kCGImagePropertyPixelHeight] as? Double, pw > 0, ph > 0 {
            aspect = pw / ph
        }
        var height = document.heightMM * 0.8
        var width = height * aspect
        if width > document.widthMM * 0.9 {
            width = document.widthMM * 0.9
            height = width / aspect
        }
        let element = LabelElement(x: (document.widthMM - width) / 2, y: (document.heightMM - height) / 2,
                                   width: width, height: height, content: .image(ImageContent(data: data)))
        modify { $0.elements.append(element) }
        selectedID = element.id
    }

    func deleteSelected() {
        guard let selectedID else { return }
        modify { $0.elements.removeAll { $0.id == selectedID } }
        self.selectedID = nil
    }

    func duplicateSelected() {
        guard var copy = selectedElement else { return }
        copy.id = UUID()
        copy.x += 2
        copy.y += 2
        modify { $0.elements.append(copy) }
        selectedID = copy.id
    }

    enum Arrange { case front, forward, backward, back }

    func arrange(_ arrange: Arrange) {
        guard let selectedID else { return }
        modify { document in
            guard let index = document.elements.firstIndex(where: { $0.id == selectedID }) else { return }
            let element = document.elements.remove(at: index)
            let target = switch arrange {
            case .front: document.elements.count
            case .forward: min(document.elements.count, index + 1)
            case .backward: max(0, index - 1)
            case .back: 0
            }
            document.elements.insert(element, at: target)
        }
    }

    func nudge(dx: Double, dy: Double) {
        guard let selectedID else { return }
        updateElement(selectedID, key: "nudge-\(selectedID)") {
            $0.x = (($0.x + dx) * 10).rounded() / 10
            $0.y = (($0.y + dy) * 10).rounded() / 10
        }
    }

    enum Alignment { case left, centerH, right, top, centerV, bottom }

    /// Aligns the selected element relative to the label.
    func align(_ alignment: Alignment) {
        guard let selectedID, let document else { return }
        updateElement(selectedID) { element in
            switch alignment {
            case .left: element.x = 0
            case .centerH: element.x = (document.widthMM - element.width) / 2
            case .right: element.x = document.widthMM - element.width
            case .top: element.y = 0
            case .centerV: element.y = (document.heightMM - element.height) / 2
            case .bottom: element.y = document.heightMM - element.height
            }
        }
    }

    func snap(_ value: Double) -> Double {
        snapToGrid ? (value * 2).rounded() / 2 : (value * 10).rounded() / 10
    }
}
