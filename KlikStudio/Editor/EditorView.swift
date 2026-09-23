import CoreMedia
import RecordKit
import SwiftUI
import TimelineKit

/// The editor: the picture, what to do to it, and where you are in it.
struct EditorView: View {
    @Environment(StudioSettings.self) private var settings
    @State private var model: EditorModel?
    @State private var loadError: String?
    /// Held by the view rather than made per presentation, so the settings someone chose
    /// survive closing the sheet and a running export is not thrown away by a redraw.
    @State private var export = ExportModel()
    @State private var isExporting = false
    let packageURL: URL

    var body: some View {
        Group {
            if let model {
                loaded(model)
            } else if let loadError {
                ContentUnavailableView("Couldn't open this recording", systemImage: "film.stack", description: Text(loadError))
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task(id: packageURL) {
            guard model == nil else { return }
            do {
                model = try EditorModel(package: RecordingPackage(url: packageURL), settings: settings)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func loaded(_ model: EditorModel) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PreviewPane(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                TransportBar(model: model)
                Divider()
                TimelineStrip(model: model)
                    .frame(height: TimelineStrip.height(for: model.timeline))
            }
            Divider()
            // Full height, beside the whole editor rather than inside it, so the rail
            // does not shrink when the timeline grows a row.
            ToolRail(model: model)
        }
        .inspector(isPresented: .constant(true)) {
            InspectorPanel(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .focusedSceneValue(\.editor, model)
        .focusedSceneValue(\.exportAction) { isExporting = true }
        .sheet(isPresented: $isExporting) {
            ExportSheet(editor: model, model: export)
        }
        .navigationTitle(model.name)
        .navigationSubtitle(model.isDirty ? "Edited" : "Saved")
        .toolbar { toolbar(model) }
        .alert("Klik Studio", isPresented: .init(get: { model.errorMessage != nil },
                                                 set: { if !$0 { model.dismissError() } })) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ model: EditorModel) -> some ToolbarContent {
        ToolbarItemGroup {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.document.canUndo)
                .help(model.document.undoName.map { "Undo \($0)" } ?? "Undo")
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.document.canRedo)
            Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s")
                .disabled(!model.isDirty)
            Button { isExporting = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .help("Export this as a video or a GIF")
        }
    }
}
