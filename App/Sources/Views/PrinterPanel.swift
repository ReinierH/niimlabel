import CoreBluetooth
import NiimbotKit
import SwiftUI

struct PrinterPanel: View {
    let printer: PrinterController
    @State private var tab = Tab.status

    enum Tab: String, CaseIterable, Identifiable {
        case status = "Printer", settings = "Instellingen", log = "Logboek"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Weergave", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch tab {
            case .status:
                if printer.isConnected { ConnectedPrinterView(printer: printer) } else { PrinterDiscoveryView(printer: printer) }
            case .settings:
                ScrollView { PrinterSettingsView(printer: printer).padding() }
            case .log:
                ProtocolLogView(printer: printer)
            }
        }
    }
}

struct PrinterDiscoveryView: View {
    let printer: PrinterController

    var body: some View {
        let bluetooth = printer.bluetooth
        VStack(alignment: .leading, spacing: 12) {
            if bluetooth.state != .poweredOn {
                Label(bluetooth.stateDescription, systemImage: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if case let .connecting(name) = printer.state {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Verbinden met \(name)…")
                }
                .padding(.horizontal)
            }

            HStack {
                Text("Printers in de buurt")
                    .font(.headline)
                Spacer()
                if bluetooth.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { bluetooth.stopScan() }
                } else {
                    Button("Zoeken") { bluetooth.startScan() }
                        .disabled(bluetooth.state != .poweredOn)
                }
            }
            .padding(.horizontal)

            List {
                if let lastID = printer.lastDeviceID, let lastName = printer.lastDeviceName,
                   !bluetooth.discovered.contains(where: { $0.id == lastID }) {
                    Section("Laatst gebruikt") {
                        deviceRow(id: lastID, name: lastName, rssi: nil)
                    }
                }
                Section("Gevonden") {
                    if bluetooth.discovered.isEmpty {
                        Text(bluetooth.isScanning ? "Zoeken… zet de printer aan en houd hem dichtbij." : "Klik op Zoeken om printers te vinden.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(bluetooth.discovered) { device in
                        deviceRow(id: device.id, name: device.name, rssi: device.rssi)
                    }
                }
            }
            .listStyle(.inset)

            Toggle("Alle Bluetooth-apparaten tonen", isOn: Binding(get: { bluetooth.showAllDevices }, set: { bluetooth.showAllDevices = $0 }))
                .font(.caption)
                .padding([.horizontal, .bottom])
        }
        .padding(.top, 12)
        .onAppear {
            if bluetooth.state == .poweredOn, bluetooth.discovered.isEmpty, !printer.isConnected { bluetooth.startScan() }
        }
        .onDisappear { bluetooth.stopScan() }
    }

    private func deviceRow(id: UUID, name: String, rssi: Int?) -> some View {
        HStack {
            Image(systemName: "printer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(name)
                Text(PrinterModel.detect(advertisedName: name)?.name ?? "Onbekend model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let rssi {
                SignalView(rssi: rssi)
            }
            Button("Verbind") {
                Task { await printer.connect(to: id, name: name) }
            }
            .disabled(printer.state != .disconnected)
        }
    }
}

struct SignalView: View {
    let rssi: Int

    var body: some View {
        let bars = rssi > -60 ? 3 : (rssi > -75 ? 2 : 1)
        Image(systemName: "cellularbars", variableValue: Double(bars) / 3)
            .foregroundStyle(.secondary)
            .help("\(rssi) dBm")
    }
}

struct ConnectedPrinterView: View {
    let printer: PrinterController

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "printer.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(printer.deviceName ?? printer.model.name)
                            .font(.headline)
                        Text("\(printer.model.name) · \(printer.statusSummary)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Status") {
                if let level = printer.batteryLevel {
                    LabeledContent("Batterij") {
                        HStack {
                            BatteryView(level: level)
                            Text("\(max(0, min(level, 4))) / 4")
                        }
                    }
                }
                if let lid = printer.heartbeat?.isLidOpen {
                    LabeledContent("Deksel", value: lid ? "Open" : "Gesloten")
                }
                if let paper = printer.heartbeat?.hasPaper {
                    LabeledContent("Labels", value: paper ? "Aanwezig" : "Niet gevonden")
                }
                if let progress = printer.progress, printer.isPrinting {
                    ProgressView(value: progress.fraction) {
                        Text("Afdrukken \(progress.printedLabels) van \(progress.totalLabels)")
                    }
                }
            }

            Section {
                if let rfid = printer.rfid {
                    LabeledContent("Resterend", value: "\(rfid.remainingLabels) van \(rfid.totalLabels)")
                    ProgressView(value: Double(rfid.remainingLabels), total: Double(max(1, rfid.totalLabels)))
                    LabeledContent("Type", value: rfid.labelType?.displayName ?? "Onbekend (\(rfid.rawLabelType))")
                    LabeledContent("Barcode", value: rfid.barcode)
                    LabeledContent("Serienummer", value: rfid.serial)
                } else {
                    Text("Geen RFID-gegevens. Niet-originele rollen werken ook, kies dan zelf het labeltype.")
                        .foregroundStyle(.secondary)
                }
                Button("RFID opnieuw lezen") { Task { await printer.readRFID() } }
                    .disabled(printer.isPrinting)
            } header: {
                Text("Labelrol")
            }

            Section("Apparaat") {
                LabeledContent("Model", value: printer.model.name)
                if let id = printer.info.modelId { LabeledContent("Model-ID", value: "\(id)") }
                if let serial = printer.info.serialNumber { LabeledContent("Serienummer", value: serial) }
                if let software = printer.info.softwareVersion { LabeledContent("Firmware", value: software) }
                if let hardware = printer.info.hardwareVersion { LabeledContent("Hardware", value: hardware) }
                if let address = printer.info.bluetoothAddress { LabeledContent("Bluetooth-adres", value: address) }
                LabeledContent("Resolutie", value: "\(printer.model.dpi) dpi, \(printer.model.printheadPixels) punten")
                LabeledContent("Protocol", value: printer.printProtocol.displayName)
            }

            Section("Automatisch uitschakelen") {
                Picker("Na", selection: Binding(
                    get: { printer.info.autoShutdownTime.flatMap { AutoShutdownTime(rawValue: UInt8($0)) } ?? .minutes30 },
                    set: { value in Task { await printer.setAutoShutdown(value) } }
                )) {
                    ForEach(AutoShutdownTime.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(printer.isPrinting)
            }

            Section {
                HStack {
                    Button("Vernieuwen") { Task { await printer.refresh() } }
                        .disabled(printer.isPrinting)
                    Spacer()
                    Button("Verbreken", role: .destructive) { printer.disconnect() }
                }
            } footer: {
                Text("Kalibreren: druk bij een B1 twee keer kort op de aan/uit-knop met de labelrol erin.")
            }
        }
        .formStyle(.grouped)
    }
}

struct PrinterSettingsView: View {
    @Bindable var printer: PrinterController

    var body: some View {
        Form {
            Section("Verbinding") {
                Toggle("Automatisch verbinden met laatste printer", isOn: $printer.autoReconnect)
            }
            Section {
                Picker("Model", selection: $printer.preferredModelName) {
                    ForEach(PrinterModel.all) { Text($0.name).tag($0.name) }
                }
                Toggle("Altijd dit model gebruiken", isOn: $printer.forceModel)
                Picker("Protocol", selection: $printer.protocolOverride) {
                    Text("Automatisch").tag(PrintProtocol?.none)
                    ForEach(PrintProtocol.allCases) { Text($0.displayName).tag(PrintProtocol?.some($0)) }
                }
            } header: {
                Text("Printermodel")
            } footer: {
                Text("Het model wordt normaal automatisch herkend. Het gekozen model wordt gebruikt voor het ontwerpen zonder verbonden printer.")
            }
            Section {
                Stepper("Pauze tussen pakketten: \(printer.packetIntervalMs) ms", value: $printer.packetIntervalMs, in: 0 ... 50)
                Toggle("Afbeeldingsdata loggen", isOn: $printer.logImageData)
            } header: {
                Text("Geavanceerd")
            } footer: {
                Text("Verhoog de pauze als afdrukken halverwege stopt of strepen bevat.")
            }
        }
        .formStyle(.grouped)
    }
}

struct ProtocolLogView: View {
    let printer: PrinterController

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(printer.log) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.secondary)
                        Text(entry.direction.rawValue)
                            .foregroundStyle(color(entry.direction))
                        Text(entry.text)
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .id(entry.id)
                }
                .listStyle(.plain)
                .onChange(of: printer.log.count) {
                    if let last = printer.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Text("\(printer.log.count) regels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Kopiëren") { copyLog() }
                Button("Wissen") { printer.clearLog() }
            }
            .padding(8)
        }
    }

    private func color(_ direction: ProtocolLogEntry.Direction) -> Color {
        switch direction {
        case .sent: .blue
        case .received: .green
        case .info: .secondary
        }
    }

    private func copyLog() {
        let formatter = ISO8601DateFormatter()
        let text = printer.log.map { "\(formatter.string(from: $0.date)) \($0.direction.rawValue) \($0.text)" }.joined(separator: "\n")
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
