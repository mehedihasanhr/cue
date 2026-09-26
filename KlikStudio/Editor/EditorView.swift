import AppKit
import CoreMedia
import RecordKit
import SwiftUI
import TimelineKit

/// The editor: the picture, what to do to it, and where you are in it.
struct EditorView: View {
    @Environment(StudioSettings.self) private var settings
    /// What has loaded and whether the export sheet is up. Owned by the window rather
    /// than by this view, because the menu bar acts on the front editor and cannot reach
    /// a view's private state.
    @Bindable var session: EditorSession
    /// Held by the view rather than made per presentation, so the settings someone chose
    /// survive closing the sheet and a running export is not thrown away by a redraw.
    @State private var export = ExportModel()
    /// How wide the settings column is. Remembered across windows and launches, because
    /// somebody who widened it to read a caption meant it, and dragging it back every
    /// morning is not a setting — it is a chore.
    @AppStorage("editor.settingsWidth") private var settingsWidth: Double = 300

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

    /// Settings on the left, picture on the right, time along the bottom.
    ///
    /// The tool rail is the only thing that runs the full height: it is how you choose
    /// what the whole window is about, so it belongs to the window rather than to a row
    /// in it. Everything else is two decks. The top one is the settings panel and the
    /// picture it is changing, side by side and the same height, because a panel that
    /// runs past the bottom of the preview is mostly empty and still costs the picture
    /// the width. The bottom one is the transport and the timeline, on the same two
    /// columns, so the edge between settings and picture is one straight line down the
    /// window instead of two that nearly agree.
    ///
    /// The old arrangement put the panel in a trailing `.inspector`, which meant the two
    /// halves of one decision — the tool you picked on the far left and the controls it
    /// opened on the far right — sat a window apart, with the picture between them.
    private func loaded(_ model: EditorModel) -> some View {
        VStack(spacing: 0) {
            // The window's own title bar is transparent and empty — `EditorWindowController`
            // makes it so — and this is the top of the window: the name, and Export.
            EditorToolbar(model: model) { session.isExporting = true }

            HStack(spacing: 0) {
                ToolRail(model: model)
                StudioDivider(axis: .vertical)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        InspectorPanel(model: model)
                            .frame(width: CGFloat(settingsWidth), alignment: .leading)
                            // A fixed width is a proposal, not a promise: a control that
                            // will not shrink below it draws straight out over the rail
                            // and the picture, and — centred in the frame — slides
                            // sideways every time a number in the panel grows a digit.
                            // Pinned to the leading edge and clipped, the column is a
                            // column whatever it is given.
                            .clipped()
                        ColumnSplitter(width: $settingsWidth, range: 260...460)

                        PreviewPane(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    StudioDivider()

                    HStack(spacing: 0) {
                        // The same width as the panel above it, from the same number:
                        // two columns that have to line up must not be two measurements.
                        TransportBar(model: model)
                            .frame(width: CGFloat(settingsWidth), alignment: .leading)
                            .clipped()
                        StudioDivider(axis: .vertical)
                        TimelineStrip(model: model)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: TimelineStrip.height(for: model.timeline,
                                                       hasSound: model.waveform.state != .unavailable))
                }
            }
        }
        // The bar runs to the very top of the window, under where the title bar was.
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $session.isExporting) {
            ExportSheet(editor: model, model: export)
        }
        .alert("Klik Studio", isPresented: .init(get: { model.errorMessage != nil },
                                                 set: { if !$0 { model.dismissError() } })) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The line between the settings and the picture, which can be dragged.
///
/// A hairline is the right thing to look at and the wrong thing to aim at, so the grab
/// area is ten points wide and invisible. The pointer changes over it, which is the only
/// promise a splitter gets to make before it is used.
private struct ColumnSplitter: View {
    @Binding var width: Double
    let range: ClosedRange<Double>

    /// The width the drag started from. Tracked so the column follows the pointer exactly
    /// rather than drifting: adding each frame's translation to the running width applies
    /// the same movement twice.
    @State private var startWidth: Double?

    var body: some View {
        StudioDivider(axis: .vertical)
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                width = min(max(start + value.translation.width, range.lowerBound),
                                            range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
            .accessibilityHidden(true)
    }
}
