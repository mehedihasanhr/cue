import CoreMedia
import Foundation
import Observation
import os
import RecordKit

/// Something a user did to the timeline, as one undoable step.
///
/// A command names itself so the Undo menu can say what it will undo, which is the whole
/// reason not to just mutate the timeline in place.
public protocol TimelineCommand: Sendable {
    var name: String { get }
    /// Returns false when the edit was not possible, so a no-op never lands on the undo
    /// stack and Undo never does nothing visible.
    @discardableResult
    func apply(to timeline: inout Timeline) -> Bool
}

/// Snapshot undo.
///
/// Whole copies rather than inverse operations: a timeline is a few thousand value-typed
/// regions, its arrays share storage until one is written, and an inverse operation per
/// command is a second implementation of every edit — which is where undo bugs live.
public struct UndoStack: Sendable {
    public struct Entry: Sendable {
        public let name: String
        public let timeline: Timeline
    }

    private var past: [Entry] = []
    private var future: [Entry] = []
    public let limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var undoName: String? { past.last?.name }
    public var redoName: String? { future.last?.name }

    /// Records the state *before* an edit, and drops anything that was undone — the
    /// branch the user chose not to take.
    public mutating func record(_ timeline: Timeline, name: String) {
        past.append(Entry(name: name, timeline: timeline))
        if past.count > limit { past.removeFirst() }
        future.removeAll()
    }

    public mutating func undo(current: Timeline) -> Entry? {
        guard let entry = past.popLast() else { return nil }
        future.append(Entry(name: entry.name, timeline: current))
        return entry
    }

    public mutating func redo(current: Timeline) -> Entry? {
        guard let entry = future.popLast() else { return nil }
        past.append(Entry(name: entry.name, timeline: current))
        return entry
    }

    public mutating func clear() {
        past.removeAll()
        future.removeAll()
    }
}

/// An open project: a recording, an edit of it, and what has changed since it was saved.
///
/// `@MainActor` and `@Observable` because it is what the editor's views read. It holds no
/// frames and does no rendering — that is `RenderKit`'s job, and it takes a `Timeline`
/// value rather than a reference to this.
@MainActor
@Observable
public final class EditorDocument {
    public private(set) var timeline: Timeline
    public private(set) var manifest: RecordingManifest
    public let package: RecordingPackage

    private var undoStack = UndoStack()
    private var savedTimeline: Timeline

    /// Where the edit lives inside the package, beside the media it refers to.
    public nonisolated static let projectFileName = "project.json"

    public var isDirty: Bool { timeline != savedTimeline }
    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }
    public var undoName: String? { undoStack.undoName }
    public var redoName: String? { undoStack.redoName }

    /// The recording's video file, or `nil` for a manifest that names one that is gone.
    public var videoURL: URL? {
        guard let track = manifest.track(.screen) else { return nil }
        let url = package.url.appendingPathComponent(track.path)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// The camera's file, for a take that recorded one — `nil` otherwise, which is every
    /// recording made before the camera could be recorded at all.
    ///
    /// The existence check is the same one `videoURL` makes and matters for the same reason:
    /// a manifest naming media that has been deleted out of the package must read as "no
    /// camera" rather than as a decoder failure later on.
    public var webcamURL: URL? {
        guard let track = manifest.track(.webcam) else { return nil }
        let url = package.url.appendingPathComponent(track.path)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    public init(package: RecordingPackage) throws {
        let manifest = try package.readManifest()
        let projectURL = package.url.appendingPathComponent(Self.projectFileName)

        var timeline: Timeline
        var edited = false
        if let data = try? Data(contentsOf: projectURL) {
            do {
                timeline = try Self.decoder.decode(Timeline.self, from: data)
                edited = true
            } catch {
                // `Timeline` decodes leniently, so reaching here means the file is not a
                // project at all. Say so: silently handing back an empty edit is how a
                // user loses an afternoon's work without ever seeing an error.
                Self.log.error("Couldn't read \(Self.projectFileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                timeline = Timeline(sourceDuration: CMTime(seconds: manifest.duration, preferredTimescale: 600))
            }
        } else {
            // A recording that has never been edited: one clip, the whole take.
            timeline = Timeline(sourceDuration: CMTime(seconds: manifest.duration, preferredTimescale: 600))
        }
        // Hand-edited or older projects are normalised *before* the undo baseline, so
        // "undo everything" lands on a document that is valid rather than on whatever
        // was in the file.
        ClipSequence.clampRegions(&timeline)
        // The sources this recording captured — the screen, each microphone — as lanes the
        // edit can set a level on. A no-op for a project that already names them and for a
        // recording made before they were captured separately.
        timeline.adoptSoundTracks(from: manifest)

        self.package = package
        self.manifest = manifest
        self.timeline = timeline
        savedTimeline = timeline
        hasBeenEdited = edited
    }

    /// Whether this project has ever been saved with an edit in it.
    ///
    /// A recording that has only ever been recorded has no `project.json`: the timeline
    /// was derived from the manifest a moment ago. That is the one moment when applying
    /// somebody's defaults is not overwriting their work.
    public private(set) var hasBeenEdited: Bool

    /// Replaces the timeline without touching undo — for defaults applied at open, which
    /// are the starting point rather than a step to undo.
    public func adopt(_ timeline: Timeline) {
        guard !hasBeenEdited else { return }
        self.timeline = timeline
        savedTimeline = timeline
        undoStack.clear()
    }

    // MARK: - Editing

    /// Applies a command, recording the state before it for undo.
    ///
    /// Inside an interaction the entry is *not* recorded: a drag that applies a command
    /// per mouse-move is still one thing the user did, and `beginInteraction` already
    /// recorded the state to go back to. Without this, dragging a zoom for a second
    /// would push thirty entries and a long drag would push the whole history off the
    /// end of the stack.
    @discardableResult
    public func apply(_ command: some TimelineCommand) -> Bool {
        let before = timeline
        var draft = timeline
        guard command.apply(to: &draft) else { return false }
        if !isInteracting {
            undoStack.record(before, name: command.name)
        }
        timeline = draft
        return true
    }

    /// Edits that are not undoable one keystroke at a time — dragging a slider — go
    /// through here, which coalesces them under one name until `endInteraction()`.
    public func change(_ name: String, _ mutate: (inout Timeline) -> Void) {
        if !isInteracting {
            undoStack.record(timeline, name: name)
        }
        var draft = timeline
        mutate(&draft)
        timeline = draft
    }

    /// Whether a gesture is in flight.
    ///
    /// Read by the editor as well as by `apply`: work that only matters once the gesture is
    /// over — rebuilding the player's composition, reconciling the waveform stores — is
    /// skipped while this is true and done once at the end. Sixty times a second is sixty
    /// times too many for work whose answer cannot change until the user lets go.
    public private(set) var isInteracting = false

    public func beginInteraction(_ name: String) {
        guard !isInteracting else { return }
        undoStack.record(timeline, name: name)
        isInteracting = true
    }

    public func endInteraction() { isInteracting = false }

    public func undo() {
        guard let entry = undoStack.undo(current: timeline) else { return }
        timeline = entry.timeline
    }

    public func redo() {
        guard let entry = undoStack.redo(current: timeline) else { return }
        timeline = entry.timeline
    }

    // MARK: - Saving

    /// Writes the edit into the package, beside the media.
    ///
    /// Written to a neighbour and swapped in, like the manifest: a half-written
    /// `project.json` would read as a corrupt project even with every frame intact.
    public func save() throws {
        hasBeenEdited = true
        let data = try Self.encoder.encode(timeline)
        try Self.write(data, into: package.url)
        savedTimeline = timeline
    }

    /// The same write, off the main thread, for a save nobody asked for.
    ///
    /// Autosave runs while somebody is working, so the disk must not stall the picture.
    /// The edit is read the instant this is called — before anything else on the main
    /// actor can run — and marked saved *after* the write lands, as that same value: if
    /// the person edits while the file is being written, the document is still dirty
    /// afterwards, against the version on disk, which is the only honest comparison, and
    /// the next write picks it up. Callers serialise their writes; two in flight would
    /// race for the file.
    @discardableResult
    public func saveInBackground() -> Task<Void, any Error> {
        let snapshot = timeline
        let folder = package.url
        return Task {
            let data = try Self.encoder.encode(snapshot)
            try await Task.detached(priority: .utility) {
                try Self.write(data, into: folder)
            }.value
            hasBeenEdited = true
            savedTimeline = snapshot
        }
    }

    /// Writes the project file into a package, atomically.
    ///
    /// To a neighbour and swapped in, like the manifest: a half-written `project.json`
    /// would read as a corrupt project even with every frame intact, and a crash or a
    /// power cut in the middle of a save has to leave the previous file whole. Every
    /// step here is either a write to a fresh temporary name or a rename, and a rename
    /// is the one thing the file system promises not to leave half done.
    nonisolated private static func write(_ data: Data, into folder: URL) throws {
        let destination = folder.appendingPathComponent(Self.projectFileName)
        let temporary = folder.appendingPathComponent(".project.\(UUID().uuidString).json")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    // MARK: - Telemetry

    /// The recorded pointer, read once and kept.
    ///
    /// The renderer asks for a position per frame, and re-reading a 150,000-line sidecar
    /// per frame is not a thing to do. Read on first use rather than in `init` because
    /// opening a project should not wait on a file the user may never look at, and
    /// `@ObservationIgnored` because caching is not a change anything should redraw for.
    public var cursorTrack: CursorTrack {
        if let cachedCursorTrack { return cachedCursorTrack }
        let samples = manifest.telemetry.cursor.map {
            TelemetryFile.read(CursorSample.self, at: package.url.appendingPathComponent($0))
        } ?? []
        let input = manifest.telemetry.input.map {
            TelemetryFile.read(InputSample.self, at: package.url.appendingPathComponent($0))
        } ?? []
        let track = CursorTrack(samples: samples, input: input)
        cachedCursorTrack = track
        return track
    }

    @ObservationIgnored private var cachedCursorTrack: CursorTrack?

    /// What each pointer in this recording actually looked like — see
    /// `CursorArtworkIndex`. Empty for a recording that did not keep it, which is every
    /// recording made before it could.
    public var cursorArtwork: CursorArtworkIndex {
        if let cachedCursorArtwork { return cachedCursorArtwork }
        let index = CursorArtworkIndex.read(manifest, in: package.url)
        cachedCursorArtwork = index
        return index
    }

    @ObservationIgnored private var cachedCursorArtwork: CursorArtworkIndex?

    /// The recorded clicks, scrolls and keys, with their positions.
    ///
    /// Kept separate from `cursorTrack` because the two are read for different things:
    /// the track is asked for a position per frame, this is read once by the zoom
    /// suggester, which needs *where* each click landed.
    public var inputSamples: [InputSample] {
        if let cachedInputSamples { return cachedInputSamples }
        let samples = manifest.telemetry.input.map {
            TelemetryFile.read(InputSample.self, at: package.url.appendingPathComponent($0))
        } ?? []
        cachedInputSamples = samples
        return samples
    }

    @ObservationIgnored private var cachedInputSamples: [InputSample]?

    /// What had focus while the recording ran.
    ///
    /// Empty for a recording made before the track existed, or one made with the focus
    /// sidecar turned off — which the suggester treats as "propose zooms from clicks
    /// alone" rather than as an error.
    public var focusSamples: [FocusSample] {
        if let cachedFocusSamples { return cachedFocusSamples }
        let samples = manifest.telemetry.focus.map {
            TelemetryFile.read(FocusSample.self, at: package.url.appendingPathComponent($0))
        } ?? []
        cachedFocusSamples = samples
        return samples
    }

    @ObservationIgnored private var cachedFocusSamples: [FocusSample]?

    /// The markers dropped while this was recorded, in recording time — see `MarkerLog`.
    /// Empty for a take with none, and for every recording made before they could be.
    public var recordedMarkers: [MarkerSample] {
        if let cachedMarkers { return cachedMarkers }
        let samples = manifest.telemetry.markers.map {
            TelemetryFile.read(MarkerSample.self, at: package.url.appendingPathComponent($0))
        } ?? []
        cachedMarkers = samples
        return samples
    }

    @ObservationIgnored private var cachedMarkers: [MarkerSample]?

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "document")
}

/// Reads a JSON Lines sidecar back.
///
/// A line that will not decode is skipped rather than failing the file: a recording
/// killed mid-write ends in half a line, and losing the last sample is better than
/// losing the take.
public enum TelemetryFile {
    public static func read<Sample: Decodable>(_ type: Sample.Type, at url: URL) -> [Sample] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            try? decoder.decode(Sample.self, from: Data(line.utf8))
        }
    }
}
