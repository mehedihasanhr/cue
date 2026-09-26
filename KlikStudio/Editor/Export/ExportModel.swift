import AppKit
import CoreMedia
import Foundation
import Observation
import os
import RenderKit
import UniformTypeIdentifiers

/// The export sheet's state: what to write, and which job it started.
///
/// It does not run the export. That belongs to `ExportJobs`, which the app owns, because
/// an export outlives the sheet and often the window — this object is only the settings,
/// their persistence, and the one job this sheet is currently watching.
@MainActor
@Observable
final class ExportModel {
    var settings: ExportSettings {
        didSet { store() }
    }

    /// The job this sheet started, so it can show progress for it and hand it back if the
    /// sheet is closed and reopened. Nil until somebody exports something.
    private(set) var job: ExportJob?

    /// Something that went wrong before there was a job to carry it — a recording with no
    /// video file in it, which the exporter never gets a chance to complain about.
    var failure: String?

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
        static let folder = "export.folder"
    }

    init() {
        // The settings someone chose last time are almost always the ones they want
        // again — an export sheet that resets to the defaults on every open is one they
        // have to re-read every time. On the very first open there is nothing to restore,
        // and Send is a better starting point than a bare `ExportSettings()`: it is the
        // export most people came here for.
        var settings = defaults.string(forKey: Key.format) == nil
            ? ExportPreset.colleague.settings
            : ExportSettings()
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

    // MARK: - Presets

    /// The preset the current settings are, if they are one.
    ///
    /// Derived rather than stored, so a preset cannot be highlighted while the controls
    /// under it say something else — which is exactly what a remembered choice would do
    /// the first time someone nudged the frame rate.
    var preset: ExportPreset? { ExportPreset.matching(settings) }

    func apply(_ preset: ExportPreset) {
        var applied = preset.settings
        // Whether a GIF loops is nobody's idea of a preset's business, so the answer
        // someone gave before is kept.
        applied.loops = settings.loops
        settings = applied
    }

    // MARK: - Starting one

    /// Asks where to put it, then hands the work to the queue.
    ///
    /// The save panel comes first so the export starts against a destination the user has
    /// already agreed to — which is also what gives a sandboxed app the right to write
    /// there at all. Everything after that is the queue's problem, which is why this
    /// returns as soon as the job is filed: the sheet can be dismissed, the window can be
    /// closed, and the file still arrives.
    @discardableResult
    func begin(from editor: EditorModel, into jobs: ExportJobs) -> ExportJob? {
        failure = nil
        guard let exporter = editor.exporter(settings: settings) else {
            failure = "This recording's video file is missing."
            return nil
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(editor.name).\(settings.format.fileExtension)"
        panel.allowedContentTypes = settings.format.contentTypes
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // Back where the last one went. The panel remembers a location per app, but not
        // per purpose, and an export should not open in whatever folder a sound was
        // imported from ten minutes ago.
        if let folder = defaults.url(forKey: Key.folder),
           FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        defaults.set(destination.deletingLastPathComponent(), forKey: Key.folder)

        let job = ExportJob(name: editor.name,
                            destination: destination,
                            settings: settings,
                            estimate: estimate(for: editor),
                            exporter: exporter)
        self.job = job
        jobs.add(job)
        Self.log.notice("Queued \(destination.lastPathComponent, privacy: .public)")
        return job
    }

    /// What the file will be, before a byte of it is written.
    func estimate(for editor: EditorModel) -> ExportEstimate {
        settings.estimate(projectSize: editor.exportSize(for: ExportSettings(maximumDimension: nil)),
                          duration: editor.duration.seconds)
    }

    /// Lets go of a finished job so the sheet opens on the options again next time.
    /// A running one is left alone — it is not this sheet's to throw away.
    func forgetSettledJob() {
        if job?.phase.isSettled == true { job = nil }
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
