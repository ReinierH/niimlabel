import LabelKit
import SwiftUI

@main
struct NiimLabelApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 560)
                #endif
        }
        .commands { AppCommands(model: model) }

        #if os(macOS)
        Settings {
            PrinterSettingsView(printer: model.printer)
                .frame(width: 460)
                .padding()
        }
        #endif
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nieuw label…") { model.showNewLabelSheet = true }
                .keyboardShortcut("n")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Ongedaan maken") { model.editor.undo() }
                .keyboardShortcut("z")
                .disabled(!model.editor.canUndo)
            Button("Opnieuw") { model.editor.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.editor.canRedo)
        }
        CommandGroup(replacing: .printItem) {
            Button("Afdrukken…") { model.showPrintSheet = true }
                .keyboardShortcut("p")
                .disabled(model.editor.document == nil)
        }
        CommandMenu("Label") {
            Button("Tekst toevoegen") { model.editor.add(.text(TextContent())) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Barcode toevoegen") { model.editor.add(.barcode(BarcodeContent())) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("QR-code toevoegen") { model.editor.add(.qrCode(QRContent())) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Rechthoek toevoegen") { model.editor.add(.shape(ShapeContent(kind: .rectangle))) }
            Button("Lijn toevoegen") { model.editor.add(.shape(ShapeContent(kind: .line))) }
            Divider()
            Button("Dupliceer element") { model.editor.duplicateSelected() }
                .keyboardShortcut("d")
                .disabled(model.editor.selectedElement == nil)
            Button("Verwijder element") { model.editor.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.editor.selectedElement == nil)
            Divider()
            Button("Naar voorgrond") { model.editor.arrange(.front) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.editor.selectedElement == nil)
            Button("Naar achtergrond") { model.editor.arrange(.back) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model.editor.selectedElement == nil)
        }
        CommandMenu("Printer") {
            Button("Printer…") { model.showPrinterPanel = true }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Status vernieuwen") { Task { await model.printer.refresh() } }
                .disabled(!model.printer.isConnected)
            Button("Verbinding verbreken") { model.printer.disconnect() }
                .disabled(!model.printer.isConnected)
        }
    }
}
