import CoreMedia
import Foundation
import os

/// How a take survives the app dying in the middle of it.
///
/// An `AVAssetWriter` writes the movie's index — the `moov` atom that says where every
/// frame is — only when `finishWriting` runs. A crash, a force quit, a panic or a power cut
/// before that left a file of frames with nothing to find them by: QuickTime refuses it and
/// so does everything else, and the take was gone. Measured on this Mac by copying a
/// recording's file three seconds before it would have finished: "Cannot Open".
///
/// With `movieFragmentInterval` set the writer puts a small index in front of the first
/// second and adds a fragment (`moof`) for every second after it, so the file on disk can
/// be played up to its last complete fragment at any moment. `finishWriting` then turns it
/// back into an ordinary movie — one `mdat`, one `moov` at the end — so a take that ends
/// normally is the same kind of file it always was. Measured:
///
/// - Tail at risk: at most one interval plus the encoder's few frames. A copy taken 6.3 s
///   into a take plays for 6.02 s; one taken at 6.9 s also plays for 6.02 s.
/// - Size: about 850 bytes a second per file are left as dead space by the fragments —
///   0.02 % of a screen recording, about 1.7 % of a 192 kb/s sound.
/// - Processor: no measurable difference; the fragments are written from samples that are
///   already encoded.
/// - Finishing a five-minute take: 0.14 s instead of 0.10 s.
///
/// A second rather than half of one: half a second halves the loss and doubles the dead
/// space, and a second is already less than anybody notices missing from the end of a take.
public enum CrashSafety {
    public static let fragmentInterval = CMTime(value: 1, timescale: 1)

    /// How often the telemetry sidecars reach the file. They trail the picture by no more
    /// than this, so a take cut short keeps its pointer for as long as it keeps its frames.
    public static let telemetryFlushInterval: TimeInterval = 0.5

    /// How often what has been written is pushed through to the disk itself.
    ///
    /// A crash of this app loses nothing that has been written: the kernel still has it. A
    /// panic or a power cut loses whatever the kernel had not yet handed to the disk, which
    /// without asking can be tens of seconds. One pass over a 1080p take's files costs 5 to
    /// 12 ms of waiting on a utility queue, measured.
    public static let syncInterval: TimeInterval = 2
}

/// The top level of a QuickTime or MPEG-4 file, read from the atom headers alone.
///
/// Enough to tell a finished movie from one that was abandoned without decoding anything:
/// a finished one has its index and no fragments; an abandoned one has fragments, or an
/// atom that runs off the end of the file.
struct MovieAtoms: Equatable {
    var types: [String] = []
    /// The last atom claims more bytes than the file has — the write that was in progress
    /// when it stopped.
    var isTruncated = false

    var hasIndex: Bool { types.contains("moov") }
    var hasFragments: Bool { types.contains("moof") }
    /// Closed by `finishWriting`: nothing more to do to it.
    var isFinished: Bool { hasIndex && !hasFragments && !isTruncated }

    init(types: [String] = [], isTruncated: Bool = false) {
        self.types = types
        self.isTruncated = isTruncated
    }

    /// `nil` when the file cannot be opened at all.
    init?(contentsOf url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }

        var offset: UInt64 = 0
        while offset + 8 <= end {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            var size = header.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if size == 1 {
                // A 64-bit size follows the type.
                guard header.count >= 16 else { isTruncated = true; break }
                size = header[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            } else if size == 0 {
                // "To the end of the file": what an `mdat` says while it is still growing.
                types.append(type)
                isTruncated = true
                break
            }
            guard size >= 8 else { isTruncated = true; break }
            types.append(type)
            if offset + size > end {
                isTruncated = true
                break
            }
            offset += size
        }
    }
}

/// Pushes a take's files through to the disk every couple of seconds while it records.
///
/// Opens each file afresh and asks for it: the writers keep their own descriptors to
/// themselves, and a flush is of the file, not of the descriptor it is asked through. Runs
/// on a queue of its own at utility priority, so the capture queue never waits on a disk.
public final class TakeSync: @unchecked Sendable {
    private let folders: [URL]
    private let queue = DispatchQueue(label: "com.stackrover.cue.studio.take-sync", qos: .utility)
    private var timer: DispatchSourceTimer?
    private static let log = Logger(subsystem: "com.stackrover.cue.studio", category: "take-sync")

    /// Everything in these folders is flushed, whatever writes it — a sidecar added later
    /// is covered without being named here.
    public init(folders: [URL]) {
        self.folders = folders
    }

    public func start(every interval: TimeInterval = CrashSafety.syncInterval) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.sync() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One pass: every file handed to the drive, then one full flush of the drive's own
    /// cache, which covers all of them at once.
    func sync() {
        var last: Int32 = -1
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where !file.hasDirectoryPath {
                let descriptor = open(file.path(percentEncoded: false), O_RDONLY)
                guard descriptor >= 0 else { continue }
                fsync(descriptor)
                if last >= 0 { close(last) }
                last = descriptor
            }
        }
        guard last >= 0 else { return }
        if fcntl(last, F_FULLFSYNC) != 0 {
            Self.log.debug("F_FULLFSYNC refused; the files were still flushed")
        }
        close(last)
    }
}
