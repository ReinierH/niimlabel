import LabelKit
import SwiftUI
import UniformTypeIdentifiers

struct TemplateSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var showImporter = false
    @State private var exportDocument: LabelFile?
    @State private var errorMessage: String?

    private var filtered: [LabelDocument] {
        let all = model.store.documents
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedDocumentID) {
            Section("Mijn labels") {
                ForEach(filtered) { document in
                    TemplateRow(document: document)
                        .tag(document.id)
                        .contextMenu { menu(for: document) }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Zoeken")
        .navigationTitle("Labels")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Nieuw label…", systemImage: "plus") { model.showNewLabelSheet = true }
                    Button("Importeren…", systemImage: "square.and.arrow.down") { showImporter = true }
                } label: {
                    Label("Nieuw", systemImage: "plus")
                } primaryAction: {
                    model.showNewLabelSheet = true
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                for url in urls {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do { try model.importDocument(Data(contentsOf: url)) } catch {
                        errorMessage = "\(url.lastPathComponent) kon niet worden geïmporteerd: \(error.localizedDescription)"
                    }
                }
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .json, defaultFilename: exportDocument?.document.name) { result in
            if case let .failure(error) = result { errorMessage = error.localizedDescription }
        }
        .alert("Fout", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    @ViewBuilder
    private func menu(for document: LabelDocument) -> some View {
        Button("Dupliceren", systemImage: "plus.square.on.square") { model.duplicate(document.id) }
        Button("Exporteren…", systemImage: "square.and.arrow.up") { exportDocument = LabelFile(document: document) }
        Divider()
        Button("Verwijderen", systemImage: "trash", role: .destructive) { model.delete(document.id) }
    }
}

struct TemplateRow: View {
    @Environment(AppModel.self) private var model
    let document: LabelDocument

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 44, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.name)
                    .lineLimit(1)
                Text(document.sizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var thumbnail: some View {
        let dpmm = 3.0
        let image = LabelRenderer.shared.render(document, dotsPerMM: dpmm, context: VariableContext()).bitmap.makeCGImage()
        return Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.medium)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
            }
        }
    }
}

/// JSON label file for export.
struct LabelFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var document: LabelDocument

    init(document: LabelDocument) {
        self.document = document
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        document = try TemplateStore.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try TemplateStore.encode(document))
    }
}
