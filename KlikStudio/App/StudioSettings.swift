import AVFoundation
import Foundation
import Observation
import RecordKit
import TimelineKit

/// What Klik Studio does by default, and where it keeps things.
///
/// The add-on has its own settings because it is its own app: Klik can override any of
/// them per recording through a `RecordingRequest`, but someone who opens Klik Studio
/// directly should not have to go somewhere else to change how it records.
@MainActor
@Observable
final class StudioSettings {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let countdown = "recording.countdown"
        static let frameRate = "recording.frameRate"
        static let quality = "recording.quality"
        static let codec = "recording.codec"
        static let systemAudio = "recording.systemAudio"
        static let microphone = "recording.microphone"
        static let camera = "recording.camera"
        static let microphoneID = "recording.microphoneID"
        static let capturesClicks = "recording.clicks"
        static let capturesFocus = "recording.focus"
        static let cursorInVideo = "recording.cursorInVideo"
        static let libraryBookmark = "library.bookmark"
        static let opensEditor = "editor.openAfterRecording"
        static let suggestsZooms = "editor.suggestZooms"
        static let zoomsOnFocus = "editor.zoomsOnFocus"
        static let zoomsOnWindows = "editor.zoomsOnWindows"
        static let zoomScale = "editor.zoomScale"
        static let background = "editor.background"
        static let padding = "editor.padding"
        static let cornerRadius = "editor.cornerRadius"
        static let shadow = "editor.shadow"
        static let shadowRadius = "editor.shadowRadius"
        static let backgroundBlur = "editor.backgroundBlur"
        static let cursorScale = "editor.cursorScale"
        static let cursorSmoothing = "editor.cursorSmoothing"
        static let clickEffect = "editor.clickEffect"
        static let previewVolume = "editor.previewVolume"
        static let previewMuted = "editor.previewMuted"
    }

    // MARK: - Recording

    var countdownSeconds: Int { didSet { defaults.set(countdownSeconds, forKey: Key.countdown) } }
    var frameRate: Int { didSet { defaults.set(frameRate, forKey: Key.frameRate) } }
    var quality: CaptureQuality { didSet { defaults.set(quality.rawValue, forKey: Key.quality) } }
    var codec: VideoCodec { didSet { defaults.set(codec.rawValue, forKey: Key.codec) } }
    var recordsSystemAudio: Bool { didSet { defaults.set(recordsSystemAudio, forKey: Key.systemAudio) } }
    var recordsMicrophone: Bool { didSet { defaults.set(recordsMicrophone, forKey: Key.microphone) } }
    /// Kept, and kept off, until the webcam recorder lands: the bar shows the state
    /// so the feature is visibly coming rather than quietly missing.
    var recordsCamera: Bool { didSet { defaults.set(recordsCamera, forKey: Key.camera) } }
    /// Empty means "whatever the system calls the default input".
    var microphoneID: String { didSet { defaults.set(microphoneID, forKey: Key.microphoneID) } }
    var recordsClicks: Bool { didSet { defaults.set(recordsClicks, forKey: Key.capturesClicks) } }
    /// Record which window, app and text field had focus, so the editor can zoom to
    /// what was being looked at and not only to what was clicked.
    var recordsFocus: Bool { didSet { defaults.set(recordsFocus, forKey: Key.capturesFocus) } }
    /// Burn the system pointer into the video instead of recording it as data.
    ///
    /// Off, and worth leaving off: with it on, none of the cursor work in the editor —
    /// size, smoothing, click effects, auto-zoom — has anything to work with.
    var burnsCursorIntoVideo: Bool { didSet { defaults.set(burnsCursorIntoVideo, forKey: Key.cursorInVideo) } }

    // MARK: - After a recording

    var opensEditorAfterRecording: Bool { didSet { defaults.set(opensEditorAfterRecording, forKey: Key.opensEditor) } }
    /// Propose zooms from the recorded clicks as soon as a project opens.
    var suggestsZoomsOnOpen: Bool { didSet { defaults.set(suggestsZoomsOnOpen, forKey: Key.suggestsZooms) } }
    /// Let focus events propose zooms as well as clicks.
    var zoomsOnFocus: Bool { didSet { defaults.set(zoomsOnFocus, forKey: Key.zoomsOnFocus) } }
    /// Zoom when a whole window comes forward, not only when something inside one takes
    /// the caret. Off by default: in a recording of a single app it fires on every
    /// switch back to it, and the window is usually the whole picture anyway.
    var zoomsOnWindowChange: Bool { didSet { defaults.set(zoomsOnWindowChange, forKey: Key.zoomsOnWindows) } }
    /// How far a click zooms in.
    var zoomScale: Double { didSet { defaults.set(zoomScale, forKey: Key.zoomScale) } }

    // MARK: - New projects

    var backgroundPreset: BackgroundPreset { didSet { defaults.set(backgroundPreset.rawValue, forKey: Key.background) } }
    var padding: Double { didSet { defaults.set(padding, forKey: Key.padding) } }
    var cornerRadius: Double { didSet { defaults.set(cornerRadius, forKey: Key.cornerRadius) } }
    var shadowOpacity: Double { didSet { defaults.set(shadowOpacity, forKey: Key.shadow) } }
    var shadowRadius: Double { didSet { defaults.set(shadowRadius, forKey: Key.shadowRadius) } }
    var backgroundBlur: Double { didSet { defaults.set(backgroundBlur, forKey: Key.backgroundBlur) } }
    var cursorScale: Double { didSet { defaults.set(cursorScale, forKey: Key.cursorScale) } }
    var cursorSmoothing: Double { didSet { defaults.set(cursorSmoothing, forKey: Key.cursorSmoothing) } }
    var clickEffect: Bool { didSet { defaults.set(clickEffect, forKey: Key.clickEffect) } }

    /// How loud the editor's preview is, and whether it is silenced.
    ///
    /// A preview setting, not a document one: it changes what this Mac plays while you
    /// work and nothing about the exported file, so it must not travel in the project or
    /// land on the undo stack.
    var previewVolume: Double { didSet { defaults.set(previewVolume, forKey: Key.previewVolume) } }
    var previewIsMuted: Bool { didSet { defaults.set(previewIsMuted, forKey: Key.previewMuted) } }

    /// Where recordings are kept. A folder the user picked is held as a bookmark,
    /// because a sandboxed app that stores a path stores something it cannot open.
    private(set) var library: URL

    init() {
        countdownSeconds = defaults.object(forKey: Key.countdown) as? Int ?? 3
        frameRate = defaults.object(forKey: Key.frameRate) as? Int ?? 60
        quality = (defaults.string(forKey: Key.quality)).flatMap(CaptureQuality.init) ?? .better
        codec = (defaults.string(forKey: Key.codec)).flatMap(VideoCodec.init) ?? .automatic
        recordsSystemAudio = defaults.object(forKey: Key.systemAudio) as? Bool ?? true
        recordsMicrophone = defaults.bool(forKey: Key.microphone)
        recordsCamera = defaults.bool(forKey: Key.camera)
        microphoneID = defaults.string(forKey: Key.microphoneID) ?? ""
        recordsClicks = defaults.object(forKey: Key.capturesClicks) as? Bool ?? true
        recordsFocus = defaults.object(forKey: Key.capturesFocus) as? Bool ?? true
        burnsCursorIntoVideo = defaults.bool(forKey: Key.cursorInVideo)
        opensEditorAfterRecording = defaults.object(forKey: Key.opensEditor) as? Bool ?? true
        // On unless someone turns it off. The recorder writes clicks as data for
        // exactly this, and a project that opens with the zooms already proposed is the
        // difference between a feature and a menu item nobody finds.
        suggestsZoomsOnOpen = defaults.object(forKey: Key.suggestsZooms) as? Bool ?? true
        zoomsOnFocus = defaults.object(forKey: Key.zoomsOnFocus) as? Bool ?? true
        zoomsOnWindowChange = defaults.bool(forKey: Key.zoomsOnWindows)
        zoomScale = defaults.object(forKey: Key.zoomScale) as? Double ?? 1.8
        backgroundPreset = (defaults.string(forKey: Key.background)).flatMap(BackgroundPreset.init) ?? .indigo
        padding = defaults.object(forKey: Key.padding) as? Double ?? 0.06
        cornerRadius = defaults.object(forKey: Key.cornerRadius) as? Double ?? 0.02
        shadowOpacity = defaults.object(forKey: Key.shadow) as? Double ?? 0.45
        shadowRadius = defaults.object(forKey: Key.shadowRadius) as? Double ?? 0.03
        backgroundBlur = defaults.object(forKey: Key.backgroundBlur) as? Double ?? 0
        cursorScale = defaults.object(forKey: Key.cursorScale) as? Double ?? 1.4
        cursorSmoothing = defaults.object(forKey: Key.cursorSmoothing) as? Double ?? 0.6
        clickEffect = defaults.object(forKey: Key.clickEffect) as? Bool ?? true
        previewVolume = defaults.object(forKey: Key.previewVolume) as? Double ?? 1
        previewIsMuted = defaults.bool(forKey: Key.previewMuted)

        library = (defaults.data(forKey: Key.libraryBookmark)).flatMap(Self.resolve) ?? Self.defaultLibrary
    }

    static var defaultLibrary: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return movies.appendingPathComponent("Klik Studio", isDirectory: true)
    }

    var isUsingDefaultLibrary: Bool { library == Self.defaultLibrary }

    func setLibrary(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { return }
        defaults.set(bookmark, forKey: Key.libraryBookmark)
        library = url
    }

    func resetLibrary() {
        defaults.removeObject(forKey: Key.libraryBookmark)
        library = Self.defaultLibrary
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    // MARK: - What the settings mean

    /// The recording these settings describe.
    ///
    /// Pure apart from the target and the name, so "what will Record do?" can be
    /// answered without recording anything.
    func configuration(target: CaptureTarget, name: String, destination: URL? = nil) -> RecordingConfiguration {
        var configuration = RecordingConfiguration(target: target,
                                                   destination: destination ?? library,
                                                   name: name)
        configuration.frameRate = frameRate
        configuration.quality = quality
        configuration.codec = codec
        configuration.systemAudio = recordsSystemAudio
        configuration.capturesClicks = recordsClicks
        configuration.capturesFocus = recordsFocus
        configuration.capturesCursorInVideo = burnsCursorIntoVideo
        configuration.microphoneID = recordsMicrophone ? (microphoneID.isEmpty ? MicrophoneRecorder.defaultDevice?.uniqueID : microphoneID) : nil
        return configuration
    }

    /// How a brand-new project looks before anyone touches it.
    func styled(_ timeline: Timeline) -> Timeline {
        var timeline = timeline
        timeline.style.background = backgroundPreset.background
        timeline.style.padding = padding
        timeline.style.cornerRadius = cornerRadius
        timeline.style.shadowOpacity = shadowOpacity
        timeline.style.shadowRadius = shadowRadius
        timeline.style.backgroundBlur = backgroundBlur
        timeline.cursor.scale = cursorScale
        timeline.cursor.smoothing = cursorSmoothing
        timeline.cursor.clickEffect = clickEffect
        return timeline
    }

    /// Puts the frame's shape back to what a new project would have.
    ///
    /// The same numbers `styled(_:)` uses, deliberately: "what Reset gives me" and "what
    /// a new recording looks like" are one idea, and keeping them as two tables would
    /// have them disagreeing within a release. The background is left alone — a Reset
    /// beside a padding slider must not quietly throw away someone's wallpaper.
    func resetShape(_ timeline: inout Timeline) {
        timeline.style.padding = padding
        timeline.style.cornerRadius = cornerRadius
        timeline.style.shadowOpacity = shadowOpacity
        timeline.style.shadowRadius = shadowRadius
        timeline.style.backgroundBlur = backgroundBlur
    }
}

/// The backgrounds offered by name, so a preference survives as a word rather than as
/// four floating-point numbers nobody can read in a defaults dump.
enum BackgroundPreset: String, CaseIterable, Identifiable, Sendable {
    case indigo, sunset, slate, paper, black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .indigo: "Indigo"
        case .sunset: "Sunset"
        case .slate: "Slate"
        case .paper: "Paper"
        case .black: "Black"
        }
    }

    var background: FrameStyle.Background {
        switch self {
        case .indigo:
            .gradient(from: ColorValue(r: 0.36, g: 0.42, b: 0.85), to: ColorValue(r: 0.15, g: 0.16, b: 0.35), angle: 0.25)
        case .sunset:
            .gradient(from: ColorValue(r: 0.98, g: 0.55, b: 0.35), to: ColorValue(r: 0.72, g: 0.21, b: 0.46), angle: 0.3)
        case .slate:
            .gradient(from: ColorValue(r: 0.22, g: 0.25, b: 0.29), to: ColorValue(r: 0.08, g: 0.09, b: 0.11), angle: 0.25)
        case .paper:
            .color(ColorValue(r: 0.94, g: 0.93, b: 0.9))
        case .black:
            .color(ColorValue(r: 0.04, g: 0.04, b: 0.05))
        }
    }
}
