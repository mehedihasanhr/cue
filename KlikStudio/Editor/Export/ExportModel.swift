import AppKit
import Foundation
import Observation
import os
import RenderKit
import UniformTypeIdentifiers

/// One export, from the settings to the file on disk.
///
/// Its own object rather than more state on `EditorModel` because an export outlives the
/// sheet that started it: the settings persist, the progress has to survive the sheet
/// being scrolled, and a cancel has to reach a running task. Keeping it separate also
/// means the editor knows nothing about encoders.
@MainActor
@Observable
final class ExportModel {
    enum Phase: Equatable {
        case idle
        case running(ExportProgress)
        case finished(URL)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    private(set) var phase: Phase = .idle
    var settings: ExportSettings {
        didSet { store() }
    }

    private var task: Task<Void, Never>?
    private var exporter: VideoExporter?
    private let defaults = UserDefaults.standard

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "export")

    private enum Key {
        static let format = "export.format"
        static let frameRate = "export.frameRate"
        static let quality = "export.quality"
        static let codec = "export.codec"
        static let dimension = "export.dimension"
        static let audio = "export.audio"
        static let loops = "export.loops"
    }

    init() {
        // The settings someone chose last time are almost always the ones they want
        // again — an export sheet that resets to the defaults on every open is one they
        // have to re-read every time.
        var settings = ExportSettings()
        if let format = defaults.string(forKey: Key.format).flatMap(ExportFormat.init) {
            settings.format = format
        }
        if let rate = defaults.object(forKey: Key.frameRate) as? Int { settings.frameRate = rate }
        if let quality = defaults.string(forKey: Key.quality).flatMap(ExportQuality.init) {
            settings.quality = quality
        }
        if let codec = defaults.string(forKey: Key.codec).flatMap(ExportCodec.init) {
            settings.codec = codec
        }
        // Zero is how "the project's own size" is stored, since a missing key and a
        // deliberate "no cap" have to be told apart.
        if let dimension = defaults.object(forKey: Key.dimension) as? Double {
            settings.maximumDimension = dimension > 0 ? dimension : nil
        }
        if let audio = defaults.object(forKey: Key.audio) as? Bool { settings.includesAudio = audio }
        if let loops = defaults.object(forKey: Key.loops) as? Bool { settings.loops = loops }
        self.settings = settings
    }

    private func store() {
        defaults.set(settings.format.rawValue, forKey: Key.format)
        defaults.set(settings.frameRate, forKey: Key.frameRate)
        defaults.set(settings.quality.rawValue, forKey: Key.quality)
        defaults.set(settings.codec.rawValue, forKey: Key.codec)
        defaults.set(settings.maximumDimension ?? 0, forKey: Key.dimension)
        defaults.set(settings.includesAudio, forKey: Key.audio)
        defaults.set(settings.loops, forKey: Key.loops)
    }

    /// Asks where to put it, then writes it.
    ///
    /// The save panel comes first so the export starts against a destination the user
    /// has already agreed to — which is also what gives a sandboxed app the right to
    /// write there at all.
    func begin(from editor: EditorModel) {
        guard !phase.isRunning else { return }
        guard let exporter = editor.exporter(settings: settings) else {
            phase = .failed("This recording's video file is missing.")
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(editor.name).\(settings.format.fileExtension)"
        panel.allowedContentTypes = settings.format.contentTypes
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        self.exporter = exporter
        phase = .running(ExportProgress(framesWritten: 0, totalFrames: 0, elapsed: 0))

        task = Task {
            do {
                try await exporter.export(to: destination) { progress in
                    Task { @MainActor [weak self] in
                        // A late report arriving after a cancel must not put the sheet
                        // back into a running state it has already left.
                        guard let self, self.phase.isRunning else { return }
                        self.phase = .running(progress)
                    }
                }
                phase = .finished(destination)
                Self.log.notice("Wrote \(destination.lastPathComponent, privacy: .public)")
            } catch let error as ExportError {
                phase = error == .cancelled ? .idle : .failed(error.localizedDescription)
            } catch {
                phase = .failed(error.localizedDescription)
            }
            self.exporter = nil
        }
    }

    func cancel() {
        guard phase.isRunning else { return }
        let exporter = exporter
        Task { await exporter?.cancel() }
        task?.cancel()
        phase = .idle
    }

    func reveal() {
        guard case .finished(let url) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func reset() {
        guard !phase.isRunning else { return }
        phase = .idle
    }
}

extension ExportFormat {
    /// What the save panel will accept. Kept here rather than in `RenderKit` so the
    /// package stays free of anything UI-shaped.
    var contentTypes: [UTType] {
        switch self {
        case .mp4: [.mpeg4Movie]
        case .mov: [.quickTimeMovie]
        case .gif: [.gif]
        }
    }
}
