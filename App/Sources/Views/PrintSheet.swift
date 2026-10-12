import LabelKit
import NiimbotKit
import SwiftUI

struct PrintSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var options = PrintOptions()
    @State private var isPrinting = false
    @State private var finished = false
    @State private var errorMessage: String?
    @State private var printTask: Task<Void, Never>?

    var body: some View {
        if let document = model.editor.document {
            let printer = model.printer
            let table = model.editor.dataTable
            let contexts = PrintPlanner.contexts(for: options, table: table)
            let perLabel = options.source == .single ? options.copies : options.copiesPerLabel
            let totalLabels = contexts.count * max(1, perLabel)

            VStack(alignment: .leading, spacing: 16) {
                Text("Afdrukken: \(document.name)")
                    .font(.title2.bold())

                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 8) {
                        preview(document, context: contexts.first ?? VariableContext(), model: printer.model)
                            .frame(width: 240, height: 180)
                        Text("\(totalLabels) label\(totalLabels == 1 ? "" : "s") · \(document.sizeDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Form {
                        Picker("Bron", selection: $options.source) {
                            ForEach(PrintOptions.Source.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        switch options.source {
                        case .single:
                            Stepper("Aantal: \(options.copies)", value: $options.copies, in: 1 ... 999)
                        case .series:
                            Stepper("Beginnen bij: \(options.seriesStart)", value: $options.seriesStart, in: 0 ... 999_999)
                            Stepper("Aantal labels: \(options.seriesCount)", value: $options.seriesCount, in: 1 ... 999)
                            Stepper("Stap: \(options.seriesStep)", value: $options.seriesStep, in: 1 ... 1000)
                            Stepper("Kopieën per label: \(options.copiesPerLabel)", value: $options.copiesPerLabel, in: 1 ... 99)
                            if !document.usedVariables.contains(where: { $0.lowercased().hasPrefix("teller") || $0.lowercased().hasPrefix("counter") }) {
                                Text("Tip: zet {teller} in een tekst of barcode om te nummeren.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case .data:
                            if let table, !table.rows.isEmpty {
                                Stepper("Van rij: \(options.dataFrom)", value: $options.dataFrom, in: 1 ... table.rows.count)
                                Stepper("Tot en met rij: \(options.dataTo)", value: $options.dataTo, in: options.dataFrom ... table.rows.count)
                                Stepper("Kopieën per label: \(options.copiesPerLabel)", value: $options.copiesPerLabel, in: 1 ... 99)
                            } else {
                                Text("Laad eerst een CSV-bestand in het eigenschappenpaneel van het label.")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Picker("Densiteit", selection: $options.density) {
                            ForEach(Array(printer.model.densityRange), id: \.self) { level in
                                Text(level == printer.model.defaultDensity ? "\(level) (standaard)" : "\(level)").tag(level)
                            }
                        }
                        Picker("Labeltype", selection: $options.labelType) {
                            ForEach(LabelType.allCases) { Text($0.displayName).tag($0) }
                        }
                        if let rfidType = printer.rfid?.labelType, rfidType != options.labelType {
                            Button("Labelrol meldt: \(rfidType.displayName) – overnemen") { options.labelType = rfidType }
                                .font(.caption)
                        }
                    }
                    .formStyle(.grouped)
                    .frame(minWidth: 340)
                    .disabled(isPrinting)
                }

                statusArea(printer: printer)

                HStack {
                    if !printer.isConnected {
                        Button("Printer verbinden…") {
                            dismiss()
                            model.showPrinterPanel = true
                        }
                    }
                    Spacer()
                    if isPrinting {
                        Button("Stoppen", role: .destructive) { printer.cancelPrint() }
                    } else {
                        Button("Sluiten", role: .cancel) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("Afdrukken") { startPrinting(document, printer: printer, table: table) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!printer.isConnected || contexts.isEmpty || totalLabels == 0)
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 660)
            .onAppear { configure(document, printer: printer, table: table) }
            .interactiveDismissDisabled(isPrinting)
        }
    }

    @ViewBuilder
    private func statusArea(printer: PrinterController) -> some View {
        if isPrinting, let progress = printer.progress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress.fraction)
                Text(stageText(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if finished {
            Label("Klaar met afdrukken", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if !printer.isConnected {
            Label("Geen printer verbonden.", systemImage: "printer.dotmatrix")
                .foregroundStyle(.secondary)
        } else if printer.heartbeat?.isLidOpen == true {
            Label("Het deksel van de printer is open.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if printer.heartbeat?.hasPaper == false {
            Label("De printer meldt geen labels.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func stageText(_ progress: PrintProgress) -> String {
        switch progress.stage {
        case .preparing: "Voorbereiden…"
        case .sending: "Gegevens versturen… (\(progress.printedLabels)/\(progress.totalLabels))"
        case .printing: "Afdrukken \(progress.printedLabels) van \(progress.totalLabels)"
        case .finishing: "Afronden…"
        case .done: "Klaar"
        }
    }

    private func preview(_ document: LabelDocument, context: VariableContext, model printerModel: PrinterModel) -> some View {
        let bitmap = LabelRenderer.shared.render(document, dotsPerMM: printerModel.dotsPerMM, context: context).bitmap
        return Group {
            if let image = bitmap.makeCGImage() {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            }
        }
    }

    private func configure(_ document: LabelDocument, printer: PrinterController, table: CSVTable?) {
        let range = printer.model.densityRange
        options.density = min(max(document.density ?? printer.model.defaultDensity, range.lowerBound), range.upperBound)
        options.labelType = document.labelType
        let variables = document.usedVariables
        if let table, !table.rows.isEmpty, !VariableResolver.dataColumns(in: variables).isEmpty {
            options.source = .data
            options.dataFrom = 1
            options.dataTo = table.rows.count
        } else if variables.contains(where: { $0.lowercased().hasPrefix("teller") || $0.lowercased().hasPrefix("counter") }) {
            options.source = .series
        }
    }

    private func startPrinting(_ document: LabelDocument, printer: PrinterController, table: CSVTable?) {
        errorMessage = nil
        finished = false
        let pages = PrintPlanner.pages(for: document, model: printer.model, options: options, table: table)
        guard !pages.isEmpty else { return }
        let job = PrintJob(pages: pages, density: options.density, labelType: options.labelType,
                           printProtocol: printer.printProtocol, printheadPixels: printer.model.printheadPixels)

        // Remember the chosen print settings with the label.
        if document.density != options.density || document.labelType != options.labelType {
            model.editor.modify {
                $0.density = options.density
                $0.labelType = options.labelType
            }
        }

        isPrinting = true
        printTask = Task {
            do {
                try await printer.print(job)
                finished = true
                isPrinting = false
                try? await Task.sleep(for: .seconds(1))
                if finished { dismiss() }
            } catch {
                errorMessage = error.localizedDescription
                isPrinting = false
            }
        }
    }
}
