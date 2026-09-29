import Darwin
import Foundation

/// Says a take is being recorded, and what it will be.
///
/// Written into the package before the first frame and removed only once the manifest is
/// on disk, so finding one later means the take never finished: the app crashed, was
/// forced to quit, or the Mac lost power. It carries the manifest the take was going to
/// have — every track, its size and rate, the telemetry, the pointer's latency — because
/// all of that is known before recording starts and none of it can be read back out of a
/// half-written file afterwards. Recovery completes it with what is actually on disk.
///
/// It also says which process wrote it, so a take that another copy of the app is recording
/// right now is not mistaken for one that was abandoned.
public struct TakeMarker: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var formatVersion: Int
    public var startedAt: Date
    public var processID: Int32
    /// When that process started, in seconds since 1970. A process ID alone is reused;
    /// the pair is not.
    public var processStartedAt: Double?
    /// The take as it was set up: duration zero, every track it was asked for.
    public var manifest: RecordingManifest

    public init(manifest: RecordingManifest,
                startedAt: Date = .now,
                processID: Int32 = getpid(),
                processStartedAt: Double? = TakeMarker.startTime(of: getpid())) {
        formatVersion = Self.currentFormat
        self.startedAt = startedAt
        self.processID = processID
        self.processStartedAt = processStartedAt
        self.manifest = manifest
    }

    /// Whether a different process that is still running wrote this — another copy of the
    /// app, part-way through recording it. This process's own markers are never "someone
    /// else's": the app knows which take it is recording and leaves that one alone itself.
    public var isHeldByAnotherProcess: Bool {
        guard processID != getpid(), processID > 0 else { return false }
        guard let started = Self.startTime(of: processID) else { return false }
        guard let recorded = processStartedAt else { return true }
        return abs(started - recorded) < 1
    }

    /// When a process started, or `nil` when there is no such process.
    public static func startTime(of pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    }
}

extension RecordingPackage {
    /// Not hidden, deliberately: somebody looking inside a package in the Finder should be
    /// able to see that this take did not finish.
    public static let markerName = "in-progress.json"

    public var markerURL: URL { url.appendingPathComponent(Self.markerName) }

    public var hasMarker: Bool {
        FileManager.default.fileExists(atPath: markerURL.path(percentEncoded: false))
    }

    public var hasManifest: Bool {
        FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false))
    }

    /// Written in one step, like the manifest, so a crash while writing it leaves either
    /// the old one or the new one.
    public func writeMarker(_ marker: TakeMarker) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
    }

    public func readMarker() throws -> TakeMarker {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TakeMarker.self, from: Data(contentsOf: markerURL))
    }

    /// The take finished: its manifest is written, so the marker has nothing left to say.
    public func removeMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}
