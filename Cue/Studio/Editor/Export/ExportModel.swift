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
        didSet {
            // A codec the format cannot hold — HEVC with transparency left over from a
            // MOV when MP4 is chosen — goes back to Automatic rather than leaving the
            // codec pop-up showing a choice that is not in it.
            if !ExportCodec.choices(for: settings.format).contains(settings.codec) {
                settings.codec = .automatic
            }
            store()
        }
    }

    /// The job this sheet started, so it can show progress for it and hand it back if the
    /// sheet is closed and reopened. Nil until somebody exports something.
    private(set) var job: ExportJob?

    /// Something that went wrong before there was a job to carry it — a recording with no
    /// video file in it, which the exporter never gets a chance to complain about.
    var failure: String?

    /// How much of the edit to write: all of it, or the selected stretch.
    ///
    /// Not remembered between opens, unlike the settings: which stretch is selected is a
    /// fact about this moment, and a sheet that quietly exported last week's choice of
    /// "the selection" would write the wrong file.
    var scope: ExportScope = .whole

    /// The stretch the export covers, or `nil` for the whole edit. A scope of `selection`
    /// with nothing selected means the whole edit, so a stale choice cannot export nothing.
    func range(for editor: EditorModel) -> CMTimeRange? {
        scope == .selection ? editor.selectedRange : nil
    }

    /// How long the file will be.
    func duration(for editor: EditorModel) -> CMTime {
        range(for: editor)?.duration ?? editor.duration
    }

    private let defaults = UserDefaults.standard

    private static let log = Logger(subsystem: "com.stackrover.cue", category: "export")

    /// Not private: Settings › Export edits the same keys, so the sheet and the pane are
    /// one set of choices rather than two that drift apart.
    enum Key {
        static let format = "export.format"
        static let frameRate = "export.frameRate"
        static let quality = "export.quality"
        static let codec = "export.codec"
        static let dimension = "export.dimension"
        static let audio = "export.audio"
        static let loops = "export.loops"
        static let target = "export.targetBytes"
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
        // Zero for no limit, as the size cap above stores "none".
        if let target = defaults.object(forKey: Key.target) as? Int {
            settings.targetByteCount = target > 0 ? target : nil
        }
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
        defaults.set(settings.targetByteCount ?? 0, forKey: Key.target)
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
        let range = range(for: editor)
        guard let exporter = editor.exporter(settings: settings, range: range) else {
            failure = "This recording's video file is missing."
            return nil
        }

        let panel = NSSavePanel()
        // A part of the video is named as one, so it does not overwrite — or get mistaken
        // for — the export of the whole thing.
        let name = range == nil ? editor.name : "\(editor.name) (part)"
        panel.nameFieldStringValue = "\(name).\(settings.format.fileExtension)"
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
        // Unless Settings pins the folder, in which case the panel keeps opening there
        // however often a file is saved somewhere else.
        if defaults.object(forKey: StudioAppPreferences.Key.remembersExportFolder) as? Bool ?? true {
            defaults.set(destination.deletingLastPathComponent(), forKey: Key.folder)
        }

        let job = ExportJob(name: name,
                            destination: destination,
                            settings: settings,
                            estimate: estimate(for: editor),
                            exporter: exporter)
        self.job = job
        jobs.add(job)
        Self.log.notice("Queued \(destination.lastPathComponent, privacy: .public)")
        return job
    }

    /// What the file will be, before a byte of it is written. Follows the scope, so the
    /// size quoted for a ten-second excerpt is a ten-second file's.
    func estimate(for editor: EditorModel) -> ExportEstimate {
        settings.estimate(projectSize: editor.exportSize(for: ExportSettings(maximumDimension: nil)),
                          duration: duration(for: editor).seconds)
    }

    /// Lets go of a finished job so the sheet opens on the options again next time.
    /// A running one is left alone — it is not this sheet's to throw away.
    func forgetSettledJob() {
        if job?.phase.isSettled == true { job = nil }
    }
}

/// Whole edit, or the selected stretch of it.
enum ExportScope: Hashable {
    case whole
    case selection
}

extension ExportFormat {
    /// What the save panel will accept. Kept here rather than in `RenderKit` so the
    /// package stays free of anything UI-shaped.
    var contentTypes: [UTType] {
        switch self {
        case .mp4: [.mpeg4Movie]
        case .mov, .proRes422, .proRes4444: [.quickTimeMovie]
        case .gif: [.gif]
        }
    }
}
