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
        static let microphoneIDs = "recording.microphoneIDs"
        static let cameraID = "recording.cameraID"
        static let capturesClicks = "recording.clicks"
        static let capturesFocus = "recording.focus"
        static let cursorInVideo = "recording.cursorInVideo"
        static let libraryBookmark = "library.bookmark"
        static let opensEditor = "editor.openAfterRecording"
        static let suggestsZooms = "editor.suggestZooms"
        static let zoomsOnFocus = "editor.zoomsOnFocus"
        static let zoomsOnWindows = "editor.zoomsOnWindows"
        static let zoomScale = "editor.zoomScale"
        static let zoomHold = "editor.zoomHold"
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
        static let voiceoverCountIn = "editor.voiceoverCountIn"
        static let captionLanguage = "editor.captionLanguage"
        static let look = "editor.look"
        static let autosave = "editor.autosave"
        static let capturesKeys = "recording.keys"
    }

    /// Record which keyboard shortcuts were pressed, as data beside the video.
    ///
    /// Off by default, like the camera, and for a cousin of the same reason: it needs the
    /// Accessibility grant, and a recorder that quietly watches the keyboard because a
    /// setting was left on a fortnight ago is not one anybody should be surprised by. What
    /// is written is shortcuts only — see `KeyRecorder` for the rule that keeps typed
    /// text out of the file.
    var recordsKeys: Bool { didSet { defaults.set(recordsKeys, forKey: Key.capturesKeys) } }

    // MARK: - Recording

    var countdownSeconds: Int { didSet { defaults.set(countdownSeconds, forKey: Key.countdown) } }
    var frameRate: Int { didSet { defaults.set(frameRate, forKey: Key.frameRate) } }
    var quality: CaptureQuality { didSet { defaults.set(quality.rawValue, forKey: Key.quality) } }
    var codec: VideoCodec { didSet { defaults.set(codec.rawValue, forKey: Key.codec) } }
    var recordsSystemAudio: Bool { didSet { defaults.set(recordsSystemAudio, forKey: Key.systemAudio) } }
    var recordsMicrophone: Bool { didSet { defaults.set(recordsMicrophone, forKey: Key.microphone) } }
    /// Whether a take records the camera as well as the screen.
    ///
    /// Off by default, and it stays off until somebody says otherwise in this app: a
    /// recorder that remembers "yes" from a fortnight ago and films a face nobody expected
    /// is the one failure here that cannot be undone after the fact. It is persisted, so a
    /// user who does want it every time gets it — but nothing else ever sets it, and it is
    /// the only thing that puts a `webcamID` on a configuration.
    var recordsCamera: Bool { didSet { defaults.set(recordsCamera, forKey: Key.camera) } }
    /// Which microphones a take records, by `uniqueID`, in the order they will appear as
    /// lanes in the editor.
    ///
    /// A list rather than one, because a recording routinely has more than one voice in it
    /// — a built-in microphone and a guest's headset — and each is written to its own file
    /// so that turning one down in the editor leaves the other alone.
    ///
    /// Empty means "whatever the system calls the default input", which is what the single
    /// setting this replaced meant when it was empty, and is why an upgrade needs no
    /// migration beyond reading the old key once.
    var microphoneIDs: [String] { didSet { defaults.set(microphoneIDs, forKey: Key.microphoneIDs) } }

    /// The first microphone, for the places that can only use one — the voiceover
    /// recorder, and the bar's label when it names the input.
    var microphoneID: String { microphoneIDs.first ?? "" }

    /// Adds or removes one microphone, keeping the order the user chose them in.
    func setMicrophone(_ id: String, isOn: Bool) {
        if isOn {
            guard !microphoneIDs.contains(id) else { return }
            microphoneIDs.append(id)
        } else {
            microphoneIDs.removeAll { $0 == id }
        }
    }
    /// Which camera, by `uniqueID`. Empty means the system's default one.
    ///
    /// Remembered the way `microphoneIDs` is, for the same reason: somebody with a good
    /// external camera and a laptop lid should not have to pick it before every take. And
    /// held as an ID rather than as a device, so a camera unplugged since the last take
    /// fails when the recording starts rather than recording nothing.
    var cameraID: String { didSet { defaults.set(cameraID, forKey: Key.cameraID) } }
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
    /// How long a suggested zoom stays in after the last click of its moment, in seconds.
    /// See `ZoomSuggester.Tuning.holdAfter`, whose default this starts from.
    var zoomHoldSeconds: Double { didSet { defaults.set(zoomHoldSeconds, forKey: Key.zoomHold) } }
    static let zoomHoldRange: ClosedRange<Double> = 0.4...4

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
    /// The look a new recording starts from, laid over the settings above. Only what
    /// those settings do not cover is kept in here — see `useForNewRecordings(_:)`.
    var newRecordingLook: Look? {
        didSet { defaults.set(newRecordingLook.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.look) }
    }

    /// How loud the editor's preview is, and whether it is silenced.
    ///
    /// A preview setting, not a document one: it changes what this Mac plays while you
    /// work and nothing about the exported file, so it must not travel in the project or
    /// land on the undo stack.
    var previewVolume: Double { didSet { defaults.set(previewVolume, forKey: Key.previewVolume) } }
    var previewIsMuted: Bool { didSet { defaults.set(previewIsMuted, forKey: Key.previewMuted) } }

    /// How long the editor counts in before it starts recording a voiceover.
    ///
    /// Its own preference rather than `countdownSeconds`, which is the recorder's: that
    /// countdown is time to get out of the way of the screen and is often turned off
    /// entirely, whereas this one is time to draw breath and is wanted even by somebody
    /// who records the screen with no countdown at all. Sharing one number would mean
    /// each setting quietly changing the other feature.
    var voiceoverCountInSeconds: Int { didSet { defaults.set(voiceoverCountInSeconds, forKey: Key.voiceoverCountIn) } }

    /// The language captions are listened for, as a locale identifier. Empty means the
    /// language this Mac is set to.
    ///
    /// A preference rather than part of the project: it is what the person at this Mac
    /// speaks, and the project records what was *said* — the captions themselves.
    var captionLanguage: String { didSet { defaults.set(captionLanguage, forKey: Key.captionLanguage) } }

    /// The locale to listen in.
    var captionLocale: Locale {
        captionLanguage.isEmpty ? .current : Locale(identifier: captionLanguage)
    }

    /// Write edits into the recording on their own, a moment after each change and when
    /// the window closes. Off means being asked, as before. See `EditorAutosaver`.
    var savesAutomatically: Bool { didSet { defaults.set(savesAutomatically, forKey: Key.autosave) } }

    /// Shortcuts, the menu bar icon, speaker notes, the desktop and the camera preview —
    /// see `RecorderPreferences`.
    let recorder = RecorderPreferences()

    /// Appearance, the Dock, the restart question and what a finished export does — see
    /// `StudioAppPreferences`.
    let app = StudioAppPreferences()

    /// The pointer, captions and voice a new recording starts with — see
    /// `NewProjectDefaults`, which `styled(_:)` applies.
    let newProjects = NewProjectDefaults()

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
        // The old single-microphone key is read when the new one is absent, so somebody
        // who picked a headset last month still has it selected after the upgrade.
        microphoneIDs = defaults.object(forKey: Key.microphoneIDs) as? [String]
            ?? [defaults.string(forKey: Key.microphoneID)].compactMap { $0 }.filter { !$0.isEmpty }
        cameraID = defaults.string(forKey: Key.cameraID) ?? ""
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
        zoomHoldSeconds = (defaults.object(forKey: Key.zoomHold) as? Double)
            .map { min(max($0, Self.zoomHoldRange.lowerBound), Self.zoomHoldRange.upperBound) }
            ?? ZoomSuggester.Tuning().holdAfter
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
        voiceoverCountInSeconds = defaults.object(forKey: Key.voiceoverCountIn) as? Int ?? 3
        captionLanguage = defaults.string(forKey: Key.captionLanguage) ?? ""
        newRecordingLook = defaults.data(forKey: Key.look).flatMap { try? JSONDecoder().decode(Look.self, from: $0) }
        // On unless someone turns it off: an editor that loses an afternoon's edits to a
        // crash, having never been asked to save, is the failure this exists to prevent.
        savesAutomatically = defaults.object(forKey: Key.autosave) as? Bool ?? true
        recordsKeys = defaults.bool(forKey: Key.capturesKeys)

        library = (defaults.data(forKey: Key.libraryBookmark)).flatMap(Self.resolve) ?? Self.defaultLibrary

        // A look chosen for new recordings before Settings had controls for its pointer
        // and caption fields still carries them. Splitting it again moves those into the
        // controls, where they can be seen; for a look already split it changes nothing.
        if let look = newRecordingLook { useForNewRecordings(look) }
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

    /// Resolves the bookmark *and opens it*.
    ///
    /// Resolving a security-scoped bookmark gives a URL; it does not give access to what
    /// the URL points at. Without the `startAccessing` call this app can list a library
    /// the user chose and not much else — the recorder writes into it because a recording
    /// is created through a path the system already granted, but renaming a package,
    /// copying one or moving one to the Trash is refused by the sandbox. The failure is
    /// reported rather than silent, so it read as "Recordings can't rename things", which
    /// is not what was wrong.
    ///
    /// Never balanced with `stopAccessing`, deliberately: this is the app's one library
    /// folder, it is wanted for as long as the app is running, and the process exiting
    /// releases it.
    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
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
        configuration.capturesKeystrokes = recordsKeys
        // Nothing chosen means the system's default input, which is what somebody who
        // turned the microphone on and never opened the menu expects to be recorded.
        configuration.microphoneIDs = recordsMicrophone
            ? (microphoneIDs.isEmpty
               ? [MicrophoneRecorder.defaultDevice?.uniqueID].compactMap { $0 }
               : microphoneIDs)
            : []
        // The one place a camera is ever asked for. `recordsCamera` off leaves this `nil`,
        // and `nil` is the state in which `RecordingSession` never builds a camera session
        // at all — so "the toggle is off" and "the camera is not opened" are the same fact
        // rather than two that could drift apart.
        configuration.webcamID = recordsCamera ? (cameraID.isEmpty ? WebcamRecorder.defaultDevice?.uniqueID : cameraID) : nil
        configuration.hidesDesktopIcons = recorder.hidesDesktopIcons
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
        newProjects.apply(to: &timeline)
        // On top: the look carries only what the settings above do not, so nothing here
        // is said twice. See `useForNewRecordings(_:)`.
        newRecordingLook?.apply(to: &timeline)
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
