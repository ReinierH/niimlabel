import LabelKit
import NiimbotKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let element = model.editor.selectedElement {
                ElementInspector(editor: model.editor, element: element)
                    .id(element.id)
            } else if let document = model.editor.document {
                LabelInspector(editor: model.editor, document: document, printerModel: model.printer.model)
            } else {
                ContentUnavailableView("Geen label", systemImage: "sidebar.trailing")
            }
        }
    }
}

// MARK: - Label

struct LabelInspector: View {
    let editor: LabelEditor
    let document: LabelDocument
    let printerModel: PrinterModel
    @State private var showDataImporter = false
    @State private var dataError: String?

    var body: some View {
        Form {
            Section("Label") {
                TextField("Naam", text: editor.binding(\.name, fallback: ""))
                NumberRow(title: "Breedte", value: editor.binding(\.widthMM, fallback: 50), unit: "mm", range: 5 ... 300, step: 1)
                NumberRow(title: "Hoogte", value: editor.binding(\.heightMM, fallback: 30), unit: "mm", range: 5 ... 300, step: 1)
                Menu("Standaardformaat") {
                    ForEach(LabelPreset.presets(for: printerModel)) { preset in
                        Button(preset.name) {
                            editor.modify {
                                $0.widthMM = preset.widthMM
                                $0.heightMM = preset.heightMM
                                $0.printRotation = preset.printRotation
                                $0.labelType = preset.labelType
                            }
                        }
                    }
                }
            }

            Section {
                Picker("Afdrukrichting", selection: editor.binding(\.printRotation, fallback: 0)) {
                    Text("0°").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
                Picker("Labeltype", selection: editor.binding(\.labelType, fallback: .withGaps)) {
                    ForEach(LabelType.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Densiteit", selection: editor.binding(\.density, fallback: nil)) {
                    Text("Standaard (\(printerModel.defaultDensity))").tag(Int?.none)
                    ForEach(Array(printerModel.densityRange), id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
            } header: {
                Text("Afdrukken")
            } footer: {
                Text("Draai 90° als je het label liggend ontwerpt maar het staand door de printer gaat (bijv. D11/D110-labels).")
            }

            Section("Uitlijning corrigeren") {
                NumberRow(title: "Horizontaal", value: editor.binding(\.offsetXMM, fallback: 0), unit: "mm", range: -10 ... 10, step: 0.5)
                NumberRow(title: "Verticaal", value: editor.binding(\.offsetYMM, fallback: 0), unit: "mm", range: -10 ... 10, step: 0.5)
            }

            Section {
                if let table = editor.dataTable {
                    LabeledContent("Bestand", value: editor.dataFileName ?? "CSV")
                    LabeledContent("Rijen", value: "\(table.rows.count)")
                    LabeledContent("Kolommen", value: table.headers.joined(separator: ", "))
                    Button("Gegevens verwijderen", role: .destructive) {
                        editor.dataTable = nil
                        editor.dataFileName = nil
                        editor.previewRow = 0
                    }
                } else {
                    Button("CSV-bestand laden…") { showDataImporter = true }
                }
                let columns = VariableResolver.dataColumns(in: document.usedVariables)
                if !columns.isEmpty {
                    LabeledContent("Gebruikte velden", value: columns.sorted().joined(separator: ", "))
                }
            } header: {
                Text("Gegevens samenvoegen")
            } footer: {
                Text("Gebruik {Kolomnaam} in tekst, barcodes of QR-codes. Ingebouwd: {teller}, {teller:4}, {datum}, {tijd}, {datumtijd}, {datum:dd MMM yyyy}.")
            }

            Section("Elementen") {
                if document.elements.isEmpty {
                    Text("Nog geen elementen. Voeg tekst, een barcode of een afbeelding toe via de balk boven het label.")
                        .foregroundStyle(.secondary)
                }
                ForEach(document.elements.reversed()) { element in
                    Button {
                        editor.selectedID = element.id
                    } label: {
                        Label {
                            Text(element.content.summary.isEmpty ? element.content.kindName : element.content.summary)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: element.content.systemImage)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showDataImporter, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            guard case let .success(url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let table = CSVTable.parse(text)
                guard !table.headers.isEmpty else { dataError = "Het bestand bevat geen kolommen."; return }
                editor.dataTable = table
                editor.dataFileName = url.lastPathComponent
                editor.previewRow = 0
            } catch {
                dataError = error.localizedDescription
            }
        }
        .alert("CSV laden mislukt", isPresented: Binding(get: { dataError != nil }, set: { if !$0 { dataError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dataError ?? "")
        }
    }
}

// MARK: - Element

struct ElementInspector: View {
    let editor: LabelEditor
    let element: LabelElement

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(element.content.kindName, systemImage: element.content.systemImage)
                        .font(.headline)
                    Spacer()
                    Button("Gereed") { editor.selectedID = nil }
                }
            }

            switch element.content {
            case .text: TextInspector(editor: editor, element: element)
            case .barcode: BarcodeInspector(editor: editor, element: element)
            case .qrCode: QRInspector(editor: editor, element: element)
            case .image: ImageInspector(editor: editor, element: element)
            case .shape: ShapeInspector(editor: editor, element: element)
            }

            Section("Positie en grootte") {
                NumberRow(title: "X", value: editor.binding(element, \.x), unit: "mm", range: -100 ... 400, step: 0.5)
                NumberRow(title: "Y", value: editor.binding(element, \.y), unit: "mm", range: -100 ... 400, step: 0.5)
                NumberRow(title: "Breedte", value: editor.binding(element, \.width), unit: "mm", range: 0.5 ... 400, step: 0.5)
                NumberRow(title: "Hoogte", value: editor.binding(element, \.height), unit: "mm", range: 0.5 ... 400, step: 0.5)
                Picker("Rotatie", selection: editor.binding(element, \.rotation)) {
                    Text("0°").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Uitlijnen")
                    Spacer()
                    alignButton("align.horizontal.left", .left)
                    alignButton("align.horizontal.center", .centerH)
                    alignButton("align.horizontal.right", .right)
                    alignButton("align.vertical.top", .top)
                    alignButton("align.vertical.center", .centerV)
                    alignButton("align.vertical.bottom", .bottom)
                }
                .buttonStyle(.borderless)
            }

            Section("Schikken") {
                HStack {
                    Button("Voorgrond", systemImage: "square.3.layers.3d.top.filled") { editor.arrange(.front) }
                    Button("Naar voren", systemImage: "square.2.layers.3d.top.filled") { editor.arrange(.forward) }
                    Button("Naar achteren", systemImage: "square.2.layers.3d.bottom.filled") { editor.arrange(.backward) }
                    Button("Achtergrond", systemImage: "square.3.layers.3d.bottom.filled") { editor.arrange(.back) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                HStack {
                    Button("Dupliceren", systemImage: "plus.square.on.square") { editor.duplicateSelected() }
                    Spacer()
                    Button("Verwijderen", systemImage: "trash", role: .destructive) { editor.deleteSelected() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func alignButton(_ icon: String, _ alignment: LabelEditor.Alignment) -> some View {
        Button { editor.align(alignment) } label: { Image(systemName: icon) }
    }
}

struct TextInspector: View {
    let editor: LabelEditor
    let element: LabelElement

    var body: some View {
        Section("Tekst") {
            TextEditor(text: editor.binding(element, \.content.text!.text))
                .font(.body)
                .frame(minHeight: 60, maxHeight: 140)
            VariableMenu { token in
                editor.updateElement(element.id) { $0.content.text?.text += token }
            }
        }
        Section("Opmaak") {
            Picker("Lettertype", selection: editor.binding(element, \.content.text!.fontFamily)) {
                ForEach(FontCatalog.families, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            NumberRow(title: "Grootte", value: editor.binding(element, \.content.text!.fontSize), unit: "pt", range: 3 ... 200, step: 1)
                .disabled(element.content.text?.autoFit == true)
            Toggle("Automatisch passend maken", isOn: editor.binding(element, \.content.text!.autoFit))
            HStack {
                Toggle(isOn: editor.binding(element, \.content.text!.bold)) { Image(systemName: "bold") }
                Toggle(isOn: editor.binding(element, \.content.text!.italic)) { Image(systemName: "italic") }
                Toggle(isOn: editor.binding(element, \.content.text!.underline)) { Image(systemName: "underline") }
                Toggle(isOn: editor.binding(element, \.content.text!.inverted)) { Image(systemName: "character.textbox") }
                    .help("Witte tekst op zwart")
            }
            .toggleStyle(.button)
            Picker("Horizontaal", selection: editor.binding(element, \.content.text!.alignment)) {
                Image(systemName: "text.alignleft").tag(LabelKit.HorizontalAlignment.left)
                Image(systemName: "text.aligncenter").tag(LabelKit.HorizontalAlignment.center)
                Image(systemName: "text.alignright").tag(LabelKit.HorizontalAlignment.right)
            }
            .pickerStyle(.segmented)
            Picker("Verticaal", selection: editor.binding(element, \.content.text!.verticalAlignment)) {
                Text("Boven").tag(LabelKit.VerticalAlignment.top)
                Text("Midden").tag(LabelKit.VerticalAlignment.center)
                Text("Onder").tag(LabelKit.VerticalAlignment.bottom)
            }
            .pickerStyle(.segmented)
            NumberRow(title: "Regelafstand", value: editor.binding(element, \.content.text!.lineSpacing), unit: "pt", range: -10 ... 40, step: 1)
        }
    }
}

struct BarcodeInspector: View {
    let editor: LabelEditor
    let element: LabelElement

    var body: some View {
        let barcode = element.content.barcode!
        Section {
            TextField("Inhoud", text: editor.binding(element, \.content.barcode!.value))
            VariableMenu { token in
                editor.updateElement(element.id) { $0.content.barcode?.value += token }
            }
            Picker("Type", selection: editor.binding(element, \.content.barcode!.symbology)) {
                ForEach(BarcodeSymbology.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Tekst onder barcode", isOn: editor.binding(element, \.content.barcode!.showText))
            if barcode.showText {
                NumberRow(title: "Tekstgrootte", value: editor.binding(element, \.content.barcode!.textSize), unit: "pt", range: 4 ... 30, step: 1)
            }
        } header: {
            Text("Barcode")
        } footer: {
            Text(hint(for: barcode.symbology))
        }
    }

    private func hint(for symbology: BarcodeSymbology) -> String {
        switch symbology {
        case .code128: "Alle ASCII-tekens. Geschikt voor artikelnummers en tekst."
        case .ean13: "12 cijfers (controlecijfer wordt berekend) of 13 cijfers."
        case .ean8: "7 cijfers (controlecijfer wordt berekend) of 8 cijfers."
        case .upca: "11 cijfers (controlecijfer wordt berekend) of 12 cijfers."
        case .code39: "Hoofdletters, cijfers en - . $ / + % spatie."
        case .itf: "Alleen cijfers; bij een oneven aantal wordt een 0 toegevoegd."
        }
    }
}

struct QRInspector: View {
    let editor: LabelEditor
    let element: LabelElement

    var body: some View {
        Section("QR-code") {
            TextEditor(text: editor.binding(element, \.content.qrCode!.value))
                .frame(minHeight: 50, maxHeight: 120)
            VariableMenu { token in
                editor.updateElement(element.id) { $0.content.qrCode?.value += token }
            }
            Picker("Foutcorrectie", selection: editor.binding(element, \.content.qrCode!.correction)) {
                ForEach(QRCorrectionLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Menu("Snel invullen") {
                Button("Website") { set("https://") }
                Button("Wifi-netwerk") { set("WIFI:T:WPA;S:NetwerkNaam;P:Wachtwoord;;") }
                Button("Telefoonnummer") { set("tel:+31600000000") }
                Button("E-mail") { set("mailto:naam@voorbeeld.nl") }
                Button("Visitekaartje (vCard)") {
                    set("BEGIN:VCARD\nVERSION:3.0\nN:Achternaam;Voornaam\nFN:Voornaam Achternaam\nTEL:+31600000000\nEMAIL:naam@voorbeeld.nl\nEND:VCARD")
                }
            }
        }
    }

    private func set(_ value: String) {
        editor.updateElement(element.id) { $0.content.qrCode?.value = value }
    }
}

struct ImageInspector: View {
    let editor: LabelEditor
    let element: LabelElement
    @State private var showImporter = false

    var body: some View {
        let image = element.content.image!
        Section("Afbeelding") {
            Picker("Omzetting", selection: editor.binding(element, \.content.image!.dither)) {
                ForEach(DitherMode.allCases) { Text($0.displayName).tag($0) }
            }
            VStack(alignment: .leading) {
                Text(image.dither == .threshold ? "Drempel" : "Helderheid")
                Slider(value: editor.binding(element, \.content.image!.threshold), in: 10 ... 245)
            }
            Toggle("Omkeren", isOn: editor.binding(element, \.content.image!.invert))
            Toggle("Verhouding behouden", isOn: editor.binding(element, \.content.image!.keepAspectRatio))
            Button("Andere afbeelding kiezen…") { showImporter = true }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                editor.updateElement(element.id) { $0.content.image?.data = data }
            }
        }
    }
}

struct ShapeInspector: View {
    let editor: LabelEditor
    let element: LabelElement

    var body: some View {
        let shape = element.content.shape!
        Section("Vorm") {
            Picker("Soort", selection: editor.binding(element, \.content.shape!.kind)) {
                ForEach(ShapeKind.allCases, id: \.self) { Label($0.displayName, systemImage: $0.systemImage).tag($0) }
            }
            NumberRow(title: "Lijndikte", value: editor.binding(element, \.content.shape!.strokeMM), unit: "mm", range: 0.1 ... 10, step: 0.1)
            if shape.kind != .line {
                Toggle("Gevuld", isOn: editor.binding(element, \.content.shape!.filled))
            }
            if shape.kind == .rectangle {
                NumberRow(title: "Hoekradius", value: editor.binding(element, \.content.shape!.cornerRadiusMM), unit: "mm", range: 0 ... 50, step: 0.5)
            }
        }
    }
}

// MARK: - Shared controls

struct NumberRow: View {
    let title: String
    @Binding var value: Double
    let unit: String
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                          format: .number.precision(.fractionLength(0 ... 2)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
            }
        }
    }
}

struct VariableMenu: View {
    let insert: (String) -> Void

    var body: some View {
        Menu("Variabele invoegen") {
            Button("Teller") { insert("{teller}") }
            Button("Teller (4 cijfers)") { insert("{teller:4}") }
            Button("Datum") { insert("{datum}") }
            Button("Tijd") { insert("{tijd}") }
            Button("Datum en tijd") { insert("{datumtijd}") }
            Button("Houdbaarheidsdatum-formaat") { insert("{datum:dd-MM-yy}") }
            Divider()
            Button("CSV-kolom…") { insert("{Kolomnaam}") }
        }
    }
}

enum FontCatalog {
    static let families: [String] = {
        #if os(macOS)
        NSFontManager.shared.availableFontFamilies.sorted()
        #else
        UIFont.familyNames.sorted()
        #endif
    }()
}
