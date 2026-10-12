import LabelKit
import NiimbotKit
import SwiftUI

struct NewLabelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Nieuw label"
    @State private var selectedPreset: LabelPreset?
    @State private var customWidth = 50.0
    @State private var customHeight = 30.0
    @State private var useCustom = false

    var body: some View {
        let printerModel = model.printer.model
        let presets = LabelPreset.presets(for: printerModel)

        VStack(alignment: .leading, spacing: 16) {
            Text("Nieuw label")
                .font(.title2.bold())

            TextField("Naam", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("Formaat voor \(printerModel.name) (printkop \(printerModel.printheadWidthMM.formattedMM) mm)")
                .font(.headline)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                    ForEach(presets) { preset in
                        PresetTile(title: preset.name, width: preset.widthMM, height: preset.heightMM,
                                   isSelected: !useCustom && selectedPreset == preset)
                            .onTapGesture {
                                selectedPreset = preset
                                useCustom = false
                            }
                    }
                    PresetTile(title: "Aangepast", width: customWidth, height: customHeight, isSelected: useCustom)
                        .onTapGesture { useCustom = true }
                }
                .padding(2)
            }
            .frame(minHeight: 220)

            if useCustom {
                HStack {
                    NumberRow(title: "Breedte", value: $customWidth, unit: "mm", range: 5 ... 300, step: 1)
                    NumberRow(title: "Hoogte", value: $customHeight, unit: "mm", range: 5 ... 300, step: 1)
                }
            }

            HStack {
                Spacer()
                Button("Annuleren", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Maken") { create(printerModel) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!useCustom && selectedPreset == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
        .onAppear { selectedPreset = presets.first }
    }

    private func create(_ printerModel: PrinterModel) {
        var document: LabelDocument
        if useCustom || selectedPreset == nil {
            document = LabelDocument(name: name, widthMM: customWidth, heightMM: customHeight,
                                     printRotation: LabelDocument.suggestedRotation(widthMM: customWidth, heightMM: customHeight,
                                                                                    printheadMM: printerModel.printheadWidthMM))
        } else {
            let preset = selectedPreset!
            document = LabelDocument(name: name, widthMM: preset.widthMM, heightMM: preset.heightMM,
                                     printRotation: preset.printRotation, labelType: preset.labelType)
        }
        let margin = min(document.widthMM, document.heightMM) * 0.1
        document.elements = [
            LabelElement(x: margin, y: margin, width: document.widthMM - 2 * margin, height: document.heightMM - 2 * margin,
                         content: .text(TextContent(text: "Tekst", fontSize: 18, bold: true, alignment: .center, autoFit: false))),
        ]
        model.create(document)
        dismiss()
    }
}

struct PresetTile: View {
    let title: String
    let width: Double
    let height: Double
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            let scale = 56 / max(width, height)
            RoundedRectangle(cornerRadius: 3)
                .fill(.white)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.5)))
                .frame(width: width * scale, height: height * scale)
                .frame(height: 60)
            Text(title)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
    }
}
