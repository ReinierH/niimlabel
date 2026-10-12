import LabelKit
import NiimbotKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            TemplateSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            Group {
                if model.editor.document != nil {
                    EditorView()
                } else {
                    ContentUnavailableView {
                        Label("Geen label geselecteerd", systemImage: "tag")
                    } description: {
                        Text("Kies een label in de zijbalk of maak een nieuw label.")
                    } actions: {
                        Button("Nieuw label…") { model.showNewLabelSheet = true }
                    }
                }
            }
            .inspector(isPresented: $model.showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
            }
            .toolbar { MainToolbar() }
        }
        .sheet(isPresented: $model.showPrintSheet) {
            PrintSheet()
        }
        .sheet(isPresented: $model.showNewLabelSheet) {
            NewLabelSheet()
        }
        .alert("Printer", isPresented: Binding(get: { model.printer.lastError != nil && !model.showPrintSheet },
                                                set: { if !$0 { model.printer.lastError = nil } })) {
            Button("OK", role: .cancel) { model.printer.lastError = nil }
        } message: {
            Text(model.printer.lastError ?? "")
        }
        #if DEBUG && os(macOS)
        .onAppear { DebugSnapshot.scheduleIfRequested(model: model) }
        #endif
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showPrinterPanel.toggle()
            } label: {
                PrinterStatusLabel(printer: model.printer)
            }
            .help("Printerverbinding en status")
            .popover(isPresented: $model.showPrinterPanel, arrowEdge: .bottom) {
                PrinterPanel(printer: model.printer)
                    .frame(width: 380, height: 560)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showPrintSheet = true
            } label: {
                Label("Afdrukken", systemImage: "printer.fill")
            }
            .help("Label afdrukken (⌘P)")
            .disabled(model.editor.document == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showInspector.toggle()
            } label: {
                Label("Eigenschappen", systemImage: "sidebar.trailing")
            }
            .help("Eigenschappen tonen/verbergen")
        }
    }
}

struct PrinterStatusLabel: View {
    let printer: PrinterController

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(printer.isConnected ? printer.model.name : "Printer")
                    .font(.callout.weight(.medium))
                Text(printer.statusSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let battery = printer.batteryLevel, printer.isConnected {
                BatteryView(level: battery)
            }
        }
        .padding(.horizontal, 4)
    }

    private var color: Color {
        switch printer.state {
        case .disconnected: .secondary
        case .connecting: .orange
        case .connected: printer.heartbeat?.isLidOpen == true || printer.heartbeat?.hasPaper == false ? .orange : .green
        case .printing: .blue
        }
    }
}

struct BatteryView: View {
    /// Bars, 1…4.
    let level: Int

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(level <= 1 ? .red : .secondary)
            .help("Batterij \(max(0, min(level, 4)))/4")
    }

    private var symbol: String {
        switch level {
        case ...1: "battery.25percent"
        case 2: "battery.50percent"
        case 3: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
