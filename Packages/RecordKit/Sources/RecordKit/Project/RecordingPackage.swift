import CoreGraphics
import Foundation

/// What one recording produced.
///
/// Written once when a session ends, and read by the editor before it opens anything
/// heavy: what tracks exist, how big the picture is, what the clock was. Versioned from
/// the first release, because a format that cannot say which version it is can only be
/// guessed at later.
public struct RecordingManifest: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public struct Track: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case screen, webcam, microphone, systemAudio
        }

        public var kind: Kind
        /// Relative to the package, always with forward slashes.
        public var path: String
        public var pixelSize: CGSize?
        public var frameRate: Int?
        public var codec: String?
        /// What to call this track in the editor: the device's name for a microphone,
        /// nothing for the screen.
        ///
        /// Stored rather than looked up when the project is opened, and that is the point:
        /// the headset this was recorded on may not be plugged in next week, and a lane
        /// labelled "Microphone 2" tells you nothing about which of the two voices it is.
        public var name: String?
        /// The capture device's `uniqueID`, for a track that came from one.
        ///
        /// Not used to find the device again — the recording is finished, there is nothing
        /// to re-open — but to tell two microphones apart when they share a name, which
        /// two of the same model do.
        public var deviceID: String?

        public init(kind: Kind,
                    path: String,
                    pixelSize: CGSize? = nil,
                    frameRate: Int? = nil,
                    codec: String? = nil,
                    name: String? = nil,
                    deviceID: String? = nil) {
            self.kind = kind
            self.path = path
            self.pixelSize = pixelSize
            self.frameRate = frameRate
            self.codec = codec
            self.name = name
            self.deviceID = deviceID
        }
    }

    public struct Telemetry: Codable, Equatable, Sendable {
        public var cursor: String?
        public var input: String?
        public var windowBounds: String?
        /// What had focus while the recording ran. Absent from recordings made before
        /// the track existed, which is why every field here is optional.
        public var focus: String?
        /// An index of what each pointer actually looked like — see `CursorArtworkWriter`.
        /// Absent from every recording made before the artwork was kept, and from any take
        /// where saving it was turned off.
        public var cursorArtwork: String?
        /// Seconds added to every pointer sample and click when it was written, so that it
        /// says when the picture showed the pointer there — see `PointerLatency`.
        ///
        /// For the record, not for correcting: the times in the sidecars already include
        /// it. Absent from recordings made before the correction, whose pointer runs this
        /// far ahead of their picture.
        public var pointerLatency: Double?
        /// Whether the keys were watched, and if not, why — see `KeyCapture`. Absent when
        /// it was not asked for, which is also every recording made before it could be.
        public var keys: KeyCapture?
        /// The markers dropped while recording — see `MarkerLog`. Absent when none were,
        /// and from every recording made before they could be.
        public var markers: String? = nil
        /// Where a window recording's picture sat inside its frame, each time that changed
        /// — see `PictureTracker`. Absent when the picture filled the frame throughout,
        /// which is every take of a display or an area, most takes of a window, and every
        /// recording made before it was written down. Optional and defaulted, so a manifest
        /// that never heard of it decodes exactly as it always did.
        public var picture: String? = nil

        public init(cursor: String? = nil,
                    input: String? = nil,
                    windowBounds: String? = nil,
                    focus: String? = nil,
                    cursorArtwork: String? = nil,
                    pointerLatency: Double? = nil,
                    keys: KeyCapture? = nil,
                    markers: String? = nil,
                    picture: String? = nil) {
            self.cursor = cursor
            self.input = input
            self.windowBounds = windowBounds
            self.focus = focus
            self.cursorArtwork = cursorArtwork
            self.pointerLatency = pointerLatency
            self.keys = keys
            self.markers = markers
            self.picture = picture
        }
    }

    public var formatVersion: Int
    public var name: String
    public var createdAt: Date
    public var duration: Double
    /// Points-to-pixels of the recorded display, so the editor can put a cursor sample
    /// (points) on top of a frame (pixels) without guessing.
    public var displayScale: Double
    /// The area of the display that was recorded, in points, when it was not the whole
    /// display.
    public var sourceRect: CGRect?
    public var tracks: [Track]
    public var telemetry: Telemetry
    public var recordedBy: String
    /// Set when the take was rebuilt from what an interrupted recording left on disk — see
    /// `TakeRecovery`. Absent from every take that finished normally.
    public var recovery: Recovery? = nil

    public init(name: String,
                createdAt: Date = .now,
                duration: Double = 0,
                displayScale: Double = 2,
                sourceRect: CGRect? = nil,
                tracks: [Track] = [],
                telemetry: Telemetry = Telemetry(),
                recordedBy: String = "Klik Studio",
                formatVersion: Int = RecordingManifest.currentFormat) {
        self.formatVersion = formatVersion
        self.name = name
        self.createdAt = createdAt
        self.duration = duration
        self.displayScale = displayScale
        self.sourceRect = sourceRect
        self.tracks = tracks
        self.telemetry = telemetry
        self.recordedBy = recordedBy
    }

    public func track(_ kind: Track.Kind) -> Track? { tracks.first { $0.kind == kind } }

    /// Every track of a kind, in the order they were recorded.
    ///
    /// `track(_:)` answers for the kinds there can only be one of — the screen, the
    /// camera. A recording can hold several microphones, so asking for "the" microphone
    /// would quietly drop all but the first.
    public func tracks(_ kind: Track.Kind) -> [Track] { tracks.filter { $0.kind == kind } }

    /// The sound this recording captured, screen first, then the microphones in the order
    /// they were chosen.
    ///
    /// Screen first because that is how a mixing desk is read and because it is the one
    /// that is always there; the microphones keep their own order so the lane a user set a
    /// level on yesterday is in the same place today.
    public var audioTracks: [Track] {
        tracks.filter { $0.kind == .systemAudio } + tracks.filter { $0.kind == .microphone }
    }
}

/// A `.klikrec` package on disk.
///
/// A package rather than a folder of loose files or a single container: the user drags
/// one object, Finder treats it as a document, and the recorder can still append to the
/// media inside it while it is being written. A single container would mean rewriting
/// the whole thing to add a track.
public struct RecordingPackage: Sendable {
    public static let fileExtension = "klikrec"

    public let url: URL

    public var mediaFolder: URL { url.appendingPathComponent("media", isDirectory: true) }
    public var telemetryFolder: URL { url.appendingPathComponent("telemetry", isDirectory: true) }
    /// Regenerable: waveform peaks, filmstrip tiles, the poster frame. Never part of
    /// whether the document is dirty, and safe to delete.
    public var derivedFolder: URL { url.appendingPathComponent("derived", isDirectory: true) }
    public var manifestURL: URL { url.appendingPathComponent("manifest.json") }

    public init(url: URL) { self.url = url }

    /// Creates the package's folders, picking a name that is not taken.
    ///
    /// The suffix is numeric rather than a timestamp because a user who records four
    /// takes of the same thing wants to see 1, 2, 3, 4.
    public static func create(named name: String, in folder: URL) throws -> RecordingPackage {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var candidate = folder.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appendingPathComponent("\(name) \(index)").appendingPathExtension(fileExtension)
            index += 1
        }

        let package = RecordingPackage(url: candidate)
        for directory in [package.url, package.mediaFolder, package.telemetryFolder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return package
    }

    public func file(_ name: String, in folder: URL) -> URL {
        folder.appendingPathComponent(name)
    }

    /// The path a manifest records for a file inside the package.
    public func relativePath(of file: URL) -> String {
        let base = url.path(percentEncoded: false)
        let path = file.path(percentEncoded: false)
        guard path.hasPrefix(base) else { return file.lastPathComponent }
        return String(path.dropFirst(base.count).drop(while: { $0 == "/" }))
    }

    /// Writes the manifest, replacing any previous one in a single step.
    ///
    /// Written to a neighbour and swapped in: a crash mid-write would otherwise leave a
    /// truncated manifest, which reads as a corrupt recording even though every frame is
    /// safely on disk beside it.
    public func write(_ manifest: RecordingManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)

        let temporary = url.appendingPathComponent(".manifest.\(UUID().uuidString).json")
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: temporary)
    }

    public func readManifest() throws -> RecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingManifest.self, from: Data(contentsOf: manifestURL))
    }

    /// Removes a package that never got any media — a cancelled countdown, a failed
    /// start. Refuses to delete anything that is not obviously ours.
    public func discard() {
        guard url.pathExtension == Self.fileExtension else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
