#if DEBUG && os(macOS)
import AppKit
import LabelKit

/// Debug aid for inspecting the UI from scripts without screen recording permission:
/// `NiimLabel -snapshot out.png [-debugDocument 1] [-debugSelect 0] [-debugShow print|new]`
/// writes the main window (and an open sheet as `out-sheet.png`) to the sandboxed temp directory.
enum DebugSnapshot {
    @MainActor
    static func scheduleIfRequested(model: AppModel) {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard let name = value("-snapshot") else { return }

        if let index = value("-debugDocument").flatMap(Int.init), model.store.documents.indices.contains(index) {
            model.selectedDocumentID = model.store.documents[index].id
        }
        if let index = value("-debugSelect").flatMap(Int.init), let elements = model.editor.document?.elements,
           elements.indices.contains(index) {
            model.editor.selectedID = elements[index].id
        }
        switch value("-debugShow") {
        case "print": model.showPrintSheet = true
        case "new": model.showNewLabelSheet = true
        default: break
        }

        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil }) else { return }
            write(window, to: base)
            if let sheet = window.attachedSheet {
                write(sheet, to: base.deletingPathExtension().appendingPathExtension("sheet.png"))
            }
        }
    }

    @MainActor
    private static func write(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
