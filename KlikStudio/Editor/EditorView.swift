import AppKit
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
    /// How wide the inspector is: one width, always.
    ///
    /// It could be dragged wider, and was remembered at whatever width it was left — so it
    /// opened stretched in one window and narrow in the next, every slider and row a
    /// different length from one day to another, and a column of controls that is laid out
    /// for one width looked loose at the other. A slider's track and its name need about
    /// three hundred points, plus the tool rail down the column's left edge.
    static let inspectorWidth: CGFloat = 352

    var body: some View {
        Group {
            if let model = session.model {
                // Swapped rather than laid over: the editor underneath would keep telling
                // the renderer its own, smaller, pane size.
                if session.isPresenting {
                    FullScreenPreview(model: model, session: session)
                } else {
                    loaded(model)
                }
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

    /// Picture on the left, its settings on the right, time along the bottom.
    ///
    /// Three bands, top to bottom. The upper one is the picture and the inspector side by
    /// side, the same height, with the tools as a rail down the inspector's left edge —
    /// between the picture and the settings — so choosing a tool and seeing what it opened
    /// happen side by side in one column. Under it, one slim transport bar across the
    /// full width; under that, the timeline, also full width, because its width is what
    /// decides how finely an edit can be placed and nothing up here earns a share of it.
    ///
    /// The previous arrangement ran a tool rail down the far left and stacked the panel
    /// beside it, with the transport in a column of its own under the panel: the timeline
    /// lost the panel's width to a block that was mostly an empty gap, and the picture sat
    /// boxed in between two strips of chrome.
    private func loaded(_ model: EditorModel) -> some View {
        VStack(spacing: 0) {
            // The window's own title bar is transparent and empty — `EditorWindowController`
            // makes it so — and this is the top of the window: the name, and Export.
            EditorToolbar(model: model,
                          exports: exports,
                          showsInspector: $session.showsInspector) { session.isExporting = true }

            HStack(spacing: 0) {
                PreviewPane(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if session.showsInspector {
                    // Splitter and column come and go together, so a hidden inspector leaves
                    // no stray hairline at the window's edge.
                    HStack(spacing: 0) {
                        StudioDivider(axis: .vertical)
                        InspectorPanel(model: model)
                            .frame(width: Self.inspectorWidth, alignment: .leading)
                            // A fixed width is a proposal, not a promise: a control that will
                            // not shrink below it draws straight out over the picture, and —
                            // centred in the frame — slides sideways every time a number in
                            // the panel grows a digit. Pinned to the leading edge and clipped,
                            // the column is a column whatever it is given.
                            .clipped()
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            // The picture is the thing that moves when the column comes or goes, so the
            // two are animated as one change rather than the column sliding over a picture
            // that has already jumped to its new size.
            .animation(StudioMotion.shape, value: session.showsInspector)

            StudioDivider()
            TransportBar(model: model) { session.present(true) }
            StudioDivider()

            TimelineStrip(model: model)
                .frame(maxWidth: .infinity)
                .frame(height: TimelineStrip.height(for: model.timeline,
                                                    hasSound: model.waveform.state != .unavailable))
        }
        // Asking for a tool is asking to see its settings. However it was asked for — a
        // rail tab, the View menu, its shortcut, a Frame menu item that needs its panel — a
        // hidden inspector comes back for it, rather than the request landing in a column
        // nobody can see.
        .onChange(of: model.toolRequests) {
            if !session.showsInspector { session.showsInspector = true }
        }
        // The bar runs to the very top of the window, under where the title bar was.
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $session.isExporting) {
            ExportSheet(editor: model, model: export, jobs: exports,
                        startsOnSelection: session.exportsSelection)
        }
        .sheet(isPresented: .init(get: { model.isTranslatingCaptions },
                                  set: { model.isTranslatingCaptions = $0 })) {
            if #available(macOS 15.0, *) {
                TranslateCaptionsSheet(model: model)
            } else {
                TranslationUnavailableSheet { model.isTranslatingCaptions = false }
            }
        }
        .sheet(isPresented: .init(get: { model.pacing != nil },
                                  set: { if !$0 { model.cancelPacing() } })) {
            PacingSheet(model: model)
        }
        .sheet(isPresented: .init(get: { model.sensitive.review != nil },
                                  set: { if !$0 { model.cancelSensitiveScan() } })) {
            SensitiveSheet(model: model)
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
