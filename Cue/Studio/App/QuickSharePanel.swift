import AppKit
import CoreMedia
import Observation
import RecordKit
import RenderKit
import SwiftUI

/// The small panel that comes up when a take stops: Edit, Save, Copy, Share.
///
/// Most takes are sent somewhere rather than edited, and going straight to the editor made
/// every one of them a trip through a window full of controls to reach Export. The take is
/// exported with the export settings used last, so the panel needs no settings of its own:
/// whoever wants different ones presses Edit.
@MainActor
final class QuickShareController {
    private let settings: StudioSettings
    private let exports: ExportJobs
    private let openEditor: (URL) -> Void
    private var panel: NSPanel?
    private var model: QuickShareModel?

    init(settings: StudioSettings, exports: ExportJobs, openEditor: @escaping (URL) -> Void) {
        self.settings = settings
        self.exports = exports
        self.openEditor = openEditor
    }

    /// Offers `recording`, replacing whatever take the panel was offering before.
    func show(_ recording: URL) {
        let model = QuickShareModel(recording: recording, settings: settings, exports: exports)
        model.edit = { [weak self] in
            self?.close()
            self?.openEditor(recording)
        }
        model.close = { [weak self] in self?.close() }
        self.model = model

        let hosting = NSHostingView(rootView: QuickShareView(model: model).padding(14))
        hosting.sizingOptions = [.preferredContentSize]
        let panel = self.panel ?? Self.makePanel()
        panel.contentView = hosting
        model.anchor = { [weak hosting] in hosting }
        panel.setContentSize(hosting.fittingSize)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        Task { await model.loadPoster() }
    }

    /// Takes the panel down and lets go of it, so nothing of it is kept between takes.
    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        model = nil
    }

    /// Presses one of the panel's buttons: Record & Copy and Record & Save are the panel
    /// with its button already pressed.
    func perform(_ action: QuickShareModel.Action) {
        model?.perform(action)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 110),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Dark whatever the system is set to, like the recorder bar it follows.
        panel.appearance = NSAppearance(named: .darkAqua)
        // Never in a recording of the screen it sits on.
        panel.sharingType = .none
        return panel
    }
}

/// What the panel is doing: waiting, exporting for one of its buttons, or done.
@MainActor
@Observable
final class QuickShareModel {
    enum Action: Equatable { case save, copy, share }

    enum Phase: Equatable {
        case idle
        case exporting(Action, Double)
        case done(Action, URL)
        case failed(String)
    }

    let recording: URL
    private(set) var phase: Phase = .idle
    private(set) var poster: NSImage?
    let name: String

    @ObservationIgnored var edit: () -> Void = {}
    @ObservationIgnored var close: () -> Void = {}
    /// The view a share sheet comes out of.
    @ObservationIgnored var anchor: () -> NSView? = { nil }

    @ObservationIgnored private let settings: StudioSettings
    @ObservationIgnored private let exports: ExportJobs

    init(recording: URL, settings: StudioSettings, exports: ExportJobs) {
        self.recording = recording
        self.settings = settings
        self.exports = exports
        name = recording.deletingPathExtension().lastPathComponent
    }

    var isBusy: Bool {
        if case .exporting = phase { return true }
        return false
    }

    func loadPoster() async {
        if let data = await RecordingPoster.jpeg(for: recording) {
            poster = NSImage(data: data)
        }
    }

    func perform(_ action: Action) {
        guard !isBusy else { return }
        Task { await run(action) }
    }

    private func run(_ action: Action) async {
        phase = .exporting(action, 0)
        do {
            let file = try await export(into: folder(for: action))
            switch action {
            case .save:
                NSWorkspace.shared.activateFileViewerSelecting([file])
            case .copy:
                let board = NSPasteboard.general
                board.clearContents()
                board.writeObjects([file as NSURL])
            case .share:
                if let view = anchor() {
                    NSSharingServicePicker(items: [file]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
                }
            }
            phase = .done(action, file)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Saved files go to Downloads, where anybody looks for something just made; a copy or
    /// a share goes to the app's own folder, because the file only has to outlive the paste.
    private func folder(for action: Action) throws -> URL {
        let folder: URL
        switch action {
        case .save:
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .copy, .share:
            folder = URL.applicationSupportDirectory.appending(path: "Cue Studio/Clipboard Exports", directoryHint: .isDirectory)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Exports the whole take with the export settings used last, through the app's export
    /// queue, so it shows in the editor's export list like any other.
    private func export(into folder: URL) async throws -> URL {
        let editor = try EditorModel(package: RecordingPackage(url: recording), settings: settings)
        let exportSettings = ExportModel().settings
        guard let exporter = editor.exporter(settings: exportSettings) else {
            throw QuickShareError.noVideo
        }
        let destination = Self.unused(folder.appending(path: "\(name).\(exportSettings.format.fileExtension)"))
        let job = ExportJob(name: name,
                            destination: destination,
                            settings: exportSettings,
                            estimate: exportSettings.estimate(projectSize: editor.exportSize(for: ExportSettings(maximumDimension: nil)),
                                                              duration: editor.duration.seconds),
                            exporter: exporter)
        exports.add(job)
        while !job.phase.isSettled {
            if case .running(let progress) = job.phase, case .exporting(let action, _) = phase {
                phase = .exporting(action, progress.fraction)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        switch job.phase {
        case .finished(let url): return url
        case .failed(let message): throw QuickShareError.failed(message)
        default: throw CancellationError()
        }
    }

    /// `Demo.mp4`, or `Demo 2.mp4` if that is taken: a quick export never overwrites.
    private static func unused(_ url: URL) -> URL {
        var candidate = url
        var index = 2
        let base = url.deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = url.deletingLastPathComponent().appending(path: "\(base) \(index).\(url.pathExtension)")
            index += 1
        }
        return candidate
    }
}

enum QuickShareError: LocalizedError {
    case noVideo
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: "This recording's video file is missing."
        case .failed(let message): message
        }
    }
}

/// The panel: the take's first frame, its name and what is happening, and four buttons.
struct QuickShareView: View {
    let model: QuickShareModel

    var body: some View {
        HStack(spacing: 14) {
            poster
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.Recorder.chosen)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
            .frame(width: 170, alignment: .leading)
            HStack(spacing: 6) {
                button("Edit", "slider.horizontal.3", primary: false) { model.edit() }
                button("Save", "square.and.arrow.down", action: .save)
                button("Copy", "doc.on.doc", action: .copy)
                button("Share", "square.and.arrow.up", action: .share)
            }
            StudioIconButton(systemImage: "xmark", help: "Close", accessibilityName: "Close quick share") {
                model.close()
            }
        }
        .padding(12)
        .studioGlass(cornerRadius: StudioTheme.Recorder.barRadius)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick share")
    }

    private var poster: some View {
        Group {
            if let poster = model.poster {
                Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.white.opacity(0.08))
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(StudioTheme.squircle(8))
        .overlay(StudioTheme.squircle(8).strokeBorder(.white.opacity(0.12)))
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            Text("Recording saved")
                .font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.Recorder.offered)
        case .exporting(_, let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(StudioTheme.Recorder.brand)
                .frame(width: 150)
        case .done(let action, _):
            Text(action == .save ? "Saved to Downloads" : action == .copy ? "Copied — paste it anywhere" : "Ready to share")
                .font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.Recorder.offered)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.red)
                .lineLimit(2)
        }
    }

    private func button(_ title: String, _ symbol: String, action: QuickShareModel.Action) -> some View {
        let isRunning: Bool = {
            if case .exporting(let running, _) = model.phase { return running == action }
            return false
        }()
        return button(title, isRunning ? "hourglass" : symbol, primary: action == .copy) {
            model.perform(action)
        }
        .disabled(model.isBusy)
    }

    private func button(_ title: String, _ symbol: String, primary: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(StudioTheme.Recorder.chosen)
            .frame(width: 56, height: 50)
            .background(primary ? StudioTheme.Recorder.brand : .white.opacity(0.08),
                        in: StudioTheme.squircle(10))
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressStyle())
        .help(title)
    }
}
