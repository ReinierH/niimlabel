import LabelKit
import NiimbotKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @Environment(AppModel.self) private var model
    /// Points per millimetre; nil = fit to window.
    @State private var zoom: Double?
    @State private var showImageImporter = false
    @FocusState private var canvasFocused: Bool

    var body: some View {
        if let document = model.editor.document {
            VStack(spacing: 0) {
                EditorToolbar(zoom: $zoom, showImageImporter: $showImageImporter)
                Divider()
                GeometryReader { geometry in
                    let fit = fitZoom(document, in: geometry.size)
                    let scale = zoom ?? fit
                    ScrollView([.horizontal, .vertical]) {
                        LabelCanvas(editor: model.editor, document: document, model: model.printer.model, zoom: scale)
                            .padding(48)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.editor.selectedID = nil
                                canvasFocused = true
                            }
                    }
                    .background(Color.canvasBackground)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($canvasFocused)
                    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                        guard model.editor.selectedElement != nil else { return .ignored }
                        let step = press.modifiers.contains(.shift) ? 2.0 : (press.modifiers.contains(.option) ? 0.1 : 0.5)
                        switch press.key {
                        case .upArrow: model.editor.nudge(dx: 0, dy: -step)
                        case .downArrow: model.editor.nudge(dx: 0, dy: step)
                        case .leftArrow: model.editor.nudge(dx: -step, dy: 0)
                        default: model.editor.nudge(dx: step, dy: 0)
                        }
                        return .handled
                    }
                    .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                        guard model.editor.selectedElement != nil else { return .ignored }
                        model.editor.deleteSelected()
                        return .handled
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        var added = false
                        for url in urls {
                            if let data = try? Data(contentsOf: url), UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                                model.editor.addImage(data: data)
                                added = true
                            }
                        }
                        return added
                    }
                    .onChange(of: model.editor.selectedID) { _, newValue in
                        if newValue != nil { canvasFocused = true }
                    }
                }
                Divider()
                EditorStatusBar(document: document)
            }
            .navigationTitle(document.name)
            .fileImporter(isPresented: $showImageImporter, allowedContentTypes: [.image]) { result in
                guard case let .success(url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { model.editor.addImage(data: data) }
            }
        }
    }

    private func fitZoom(_ document: LabelDocument, in size: CGSize) -> Double {
        let available = CGSize(width: max(100, size.width - 96), height: max(100, size.height - 96))
        return max(2, min(40, min(available.width / document.widthMM, available.height / document.heightMM)))
    }
}

struct EditorToolbar: View {
    @Environment(AppModel.self) private var model
    @Binding var zoom: Double?
    @Binding var showImageImporter: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content.labelStyle(.titleAndIcon)
            content.labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var content: some View {
        @Bindable var editor = model.editor
        return HStack(spacing: 8) {
            toolButton("Tekst", "textformat") { editor.add(.text(TextContent())) }
            toolButton("Barcode", "barcode") { editor.add(.barcode(BarcodeContent())) }
            toolButton("QR-code", "qrcode") { editor.add(.qrCode(QRContent())) }
            toolButton("Afbeelding", "photo") { showImageImporter = true }
            Menu {
                ForEach(ShapeKind.allCases, id: \.self) { kind in
                    Button(kind.displayName, systemImage: kind.systemImage) {
                        editor.add(.shape(ShapeContent(kind: kind, filled: false)))
                    }
                }
            } label: {
                Label("Vorm", systemImage: "square.on.circle")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Vorm toevoegen")

            Spacer()

            Toggle(isOn: $editor.snapToGrid) {
                Label("Raster", systemImage: "grid")
            }
            .toggleStyle(.button)
            .help("Uitlijnen op 0,5 mm raster")

            Divider().frame(height: 18)

            Button { zoom = max(2, (zoom ?? 10) / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Uitzoomen")
            Menu(zoom.map { "\(Int(($0 / 2.835) * 100))%" } ?? "Passend") {
                Button("Passend") { zoom = nil }
                ForEach([100, 200, 300, 400, 600], id: \.self) { percent in
                    Button("\(percent)%") { zoom = Double(percent) / 100 * 2.835 }
                }
            }
            .menuStyle(.button)
            .fixedSize()
            Button { zoom = min(40, (zoom ?? 10) * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Inzoomen")
        }
    }

    private func toolButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .help("\(title) toevoegen")
    }
}

struct EditorStatusBar: View {
    @Environment(AppModel.self) private var model
    let document: LabelDocument

    var body: some View {
        let printerModel = model.printer.model
        let dpmm = printerModel.dotsPerMM
        HStack(spacing: 12) {
            Text(document.sizeDescription)
            Text("\(Int((document.widthMM * dpmm).rounded())) × \(Int((document.heightMM * dpmm).rounded())) punten")
                .foregroundStyle(.secondary)
            Text("\(printerModel.name) · \(printerModel.dpi) dpi · printkop \(printerModel.printheadWidthMM.formattedMM) mm")
                .foregroundStyle(.secondary)
            // A few millimetres of unprinted edge is normal (e.g. 50 mm labels on a 48 mm B1 head).
            if acrossHead(document) > printerModel.printheadWidthMM + 4 {
                Label("Breder dan de printkop: de randen worden niet afgedrukt", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let table = model.editor.dataTable, !table.rows.isEmpty {
                @Bindable var editor = model.editor
                Text("Voorbeeld rij")
                    .foregroundStyle(.secondary)
                Stepper("\(editor.previewRow + 1) / \(table.rows.count)", value: $editor.previewRow, in: 0 ... table.rows.count - 1)
                    .fixedSize()
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func acrossHead(_ document: LabelDocument) -> Double {
        document.printRotation % 180 == 0 ? document.widthMM : document.heightMM
    }
}

/// The label with its 1-bit preview and interactive element frames.
struct LabelCanvas: View {
    let editor: LabelEditor
    let document: LabelDocument
    let model: PrinterModel
    let zoom: Double

    var body: some View {
        let rendered = LabelRenderer.shared.render(document, dotsPerMM: model.dotsPerMM, context: editor.previewContext)
        let size = CGSize(width: document.widthMM * zoom, height: document.heightMM * zoom)
        let radius = min(1.5 * zoom, 14)

        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Color.white
                if let image = rendered.bitmap.makeCGImage() {
                    Image(decorative: image, scale: 1)
                        .interpolation(zoom / model.dotsPerMM >= 1.5 ? .none : .medium)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                }
                NonPrintableArea(document: document, model: model, zoom: zoom)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .allowsHitTesting(false)

            ForEach(document.elements) { element in
                ElementHandle(editor: editor, element: element, zoom: zoom,
                              isSelected: editor.selectedID == element.id, issue: rendered.issues[element.id])
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: "canvas")
    }
}

/// Hatches the parts of the label the print head cannot reach.
struct NonPrintableArea: View {
    let document: LabelDocument
    let model: PrinterModel
    let zoom: Double

    var body: some View {
        let horizontal = document.printRotation % 180 == 0
        let across = horizontal ? document.widthMM : document.heightMM
        let margin = max(0, (across - model.printheadWidthMM) / 2)
        if margin > 0.25 {
            let thickness = margin * zoom
            let color = Color.red.opacity(0.12)
            if horizontal {
                HStack(spacing: 0) {
                    color.frame(width: thickness)
                    Spacer(minLength: 0)
                    color.frame(width: thickness)
                }
            } else {
                VStack(spacing: 0) {
                    color.frame(height: thickness)
                    Spacer(minLength: 0)
                    color.frame(height: thickness)
                }
            }
        }
    }
}

struct ElementHandle: View {
    let editor: LabelEditor
    let element: LabelElement
    let zoom: Double
    let isSelected: Bool
    let issue: String?

    @State private var startFrame: CGRect?
    @State private var gestureKey = ""
    @State private var hovering = false

    var body: some View {
        let width = max(element.width * zoom, 6)
        let height = max(element.height * zoom, 6)

        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Color.accentColor.opacity(isSelected ? 0.07 : 0.001))
                .overlay {
                    Rectangle()
                        .strokeBorder(borderColor, style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: isSelected ? [] : [4, 3]))
                }
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .overlay(Rectangle().stroke(.white, lineWidth: 1))
                    .frame(width: 10, height: 10)
                    .offset(x: 5, y: 5)
                    .gesture(resizeGesture)
                    .help("Sleep om de grootte te wijzigen")
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(moveGesture)
        .onHover { hovering = $0 }
        .help(issue ?? element.content.kindName)
        .offset(x: element.x * zoom, y: element.y * zoom)
    }

    private var borderColor: Color {
        if issue != nil { return .orange }
        if isSelected { return .accentColor }
        return hovering ? Color.accentColor.opacity(0.6) : .clear
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                if startFrame == nil {
                    startFrame = element.frame
                    gestureKey = "move-\(UUID().uuidString)"
                    editor.selectedID = element.id
                }
                guard let start = startFrame, hypot(value.translation.width, value.translation.height) > 1 else { return }
                editor.updateElement(element.id, key: gestureKey) {
                    $0.x = editor.snap(start.minX + value.translation.width / zoom)
                    $0.y = editor.snap(start.minY + value.translation.height / zoom)
                }
            }
            .onEnded { _ in startFrame = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                if startFrame == nil {
                    startFrame = element.frame
                    gestureKey = "resize-\(UUID().uuidString)"
                }
                guard let start = startFrame else { return }
                editor.updateElement(element.id, key: gestureKey) {
                    $0.width = max(0.5, editor.snap(start.width + value.translation.width / zoom))
                    $0.height = max(0.5, editor.snap(start.height + value.translation.height / zoom))
                }
            }
            .onEnded { _ in startFrame = nil }
    }
}

extension Color {
    static var canvasBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}
