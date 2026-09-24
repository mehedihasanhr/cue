import CoreMedia
import RecordKit
import SwiftUI
import TimelineKit

/// The editor: the picture, what to do to it, and where you are in it.
struct EditorView: View {
    @Environment(StudioSettings.self) private var settings
    /// The app's exports, not this window's: one of them may well have been started here
    /// and be finishing long after this window has gone.
    @Environment(ExportJobs.self) private var exports
    /// What has loaded and whether the export sheet is up. Owned by the window rather
    /// than by this view, because the menu bar acts on the front editor and cannot reach
    /// a view's private state.
    @Bindable var session: EditorSession
    /// The sheet's own state — the settings and which job it last started. The export
    /// itself lives in `exports` above, so nothing here is holding the work.
    @State private var export = ExportModel()

    var body: some View {
        Group {
            if let model = session.model {
                loaded(model)
            } else if let loadError = session.loadError {
                ContentUnavailableView("Couldn't open this recording", systemImage: "film.stack", description: Text(loadError))
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task(id: session.packageURL) {
            guard session.model == nil else { return }
            do {
                session.model = try EditorModel(package: RecordingPackage(url: session.packageURL), settings: settings)
            } catch {
                session.loadError = error.localizedDescription
            }
        }
    }

    private func loaded(_ model: EditorModel) -> some View {
        VStack(spacing: 0) {
            // The window's own title bar is transparent and empty — `EditorWindowController`
            // makes it so — and this is the top of the window: the name, and Export.
            EditorToolbar(model: model, exports: exports) { session.isExporting = true }

            HStack(spacing: 0) {
                // Full height, beside the whole editor rather than inside it, so the rail
                // does not shrink when the timeline grows a row.
                ToolRail(model: model)
                Divider()
                VStack(spacing: 0) {
                    PreviewPane(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    TransportBar(model: model)
                    Divider()
                    TimelineStrip(model: model)
                        .frame(height: TimelineStrip.height(for: model.timeline,
                                                           hasSound: model.waveform.state != .unavailable))
                }
            }
        }
        // The bar runs to the very top of the window, under where the title bar was.
        .ignoresSafeArea(.container, edges: .top)
        .inspector(isPresented: .constant(true)) {
            InspectorPanel(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .sheet(isPresented: $session.isExporting) {
            ExportSheet(editor: model, model: export, jobs: exports)
        }
        .alert("Klik Studio", isPresented: .init(get: { model.errorMessage != nil },
                                                 set: { if !$0 { model.dismissError() } })) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // Here rather than on the sound lane because two places ask to re-attach — the
        // lane's context menu and the Edit menu — and a dialogue attached to the lane
        // would not appear for a recording whose lane is hidden for having no sound.
        .confirmationDialog("Re-attach the recording's sound?",
                            isPresented: .init(get: { model.soundReattachWarning != nil },
                                               set: { if !$0 { model.cancelSoundReattach() } })) {
            Button("Re-attach", role: .destructive) { model.attachSound() }
            Button("Cancel", role: .cancel) { model.cancelSoundReattach() }
        } message: {
            Text(model.soundReattachWarning ?? "")
        }
    }
}
