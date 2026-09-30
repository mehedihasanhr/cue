import AVFoundation
import CoreMedia
import Foundation
import os

extension RecordingManifest {
    /// What recovery did to a take, kept so the editor — and anyone reading a bug report —
    /// can tell a rebuilt take from one that finished.
    public struct Recovery: Codable, Equatable, Sendable {
        public var recoveredAt: Date
        /// How much of the end of the take could not be kept, in seconds.
        ///
        /// Estimated from the telemetry, which reaches the disk twice a second where the
        /// picture reaches it once, so it knows roughly when the take really stopped. `nil`
        /// when there was no telemetry to ask.
        public var lostSeconds: Double?
        /// Files kept exactly as they were found, still in fragments, because there was no
        /// room to rewrite them. They play; they are only less tidy. `nil` when every file
        /// was rewritten.
        public var keptAsFound: [String]?

        public init(recoveredAt: Date = .now, lostSeconds: Double? = nil, keptAsFound: [String]? = nil) {
            self.recoveredAt = recoveredAt
            self.lostSeconds = lostSeconds
            self.keptAsFound = keptAsFound
        }
    }
}

/// A take that was being recorded when the app stopped, as the library sees it.
public struct InterruptedTake: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let startedAt: Date
    public let byteCount: Int64
    /// Its manifest is there too. The take finished and only the marker was left behind —
    /// the app stopped in the moment between writing one and removing the other.
    public let hasFinished: Bool
    /// Whether the picture got as far as its first second on disk — read from the file's
    /// headers, without opening it. A take stopped before that has nothing to recover, and
    /// is not worth asking anybody about.
    public let hasFootage: Bool

    public var id: URL { url }

    public init(url: URL, name: String, startedAt: Date, byteCount: Int64, hasFinished: Bool, hasFootage: Bool = true) {
        self.url = url
        self.name = name
        self.startedAt = startedAt
        self.byteCount = byteCount
        self.hasFinished = hasFinished
        self.hasFootage = hasFootage
    }
}

extension RecordingLibrary {
    /// Every take in the folder that carries a marker, and so never finished.
    ///
    /// `live` is what this app is recording right now: its package has a marker for the
    /// best of reasons. A take another running copy of the app is recording is left out
    /// the same way, from the process its marker names. Reads only, like `entries()`.
    public func interruptedTakes(excluding live: Set<URL> = []) -> [InterruptedTake] {
        let liveKeys = Set(live.map(Self.key))
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                    includingPropertiesForKeys: [.creationDateKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { $0.pathExtension == RecordingPackage.fileExtension }
            .compactMap { url in
                let package = RecordingPackage(url: url)
                guard package.hasMarker, !liveKeys.contains(Self.key(url)) else { return nil }
                let marker = try? package.readMarker()
                if marker?.isHeldByAnotherProcess == true { return nil }
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                let screen = marker?.manifest.track(.screen)?.path ?? "media/screen.mov"
                return InterruptedTake(url: url,
                                       name: url.deletingPathExtension().lastPathComponent,
                                       startedAt: marker?.startedAt ?? created ?? .distantPast,
                                       byteCount: Self.size(of: url),
                                       hasFinished: package.hasManifest,
                                       hasFootage: MovieAtoms(contentsOf: url.appending(path: screen))?.hasIndex == true)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }
}

/// What recovering a take came to.
public enum RecoveryOutcome: Equatable, Sendable {
    /// Rebuilt: the manifest is written and the take opens like any other.
    case recovered(RecordingManifest)
    /// It had finished; the marker was all that was wrong, and it is gone.
    case alreadyFinished
    /// It stopped before a single frame reached the disk. Nothing is changed — an empty
    /// recording would be worse than none — and the package is left for the user to throw
    /// away.
    case nothingRecorded
}

/// Why a take could not be recovered, each in one sentence a person can act on.
public enum RecoveryError: Error, LocalizedError, Equatable, Sendable {
    case notInterrupted
    case unreadableMarker
    case unreadableVideo
    case notEnoughSpace
    case couldNotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .notInterrupted: "This recording finished normally."
        case .unreadableMarker: "The note saying what was being recorded can\u{2019}t be read."
        case .unreadableVideo: "The video in this recording can\u{2019}t be read."
        case .notEnoughSpace: "There isn\u{2019}t enough free disk space to recover it."
        case .couldNotWrite(let reason): "The recovered recording couldn\u{2019}t be saved (\(reason))."
        }
    }
}

/// Makes an interrupted take into a normal recording.
///
/// Every file the take was writing was fragmented (`CrashSafety`), so each one plays up to
/// its last complete second however it was stopped. Recovery reads what plays, rewrites it
/// as an ordinary movie beside the original, checks the rewrite opens and holds every frame
/// the original held, and only then writes the manifest and puts the rewrite in the
/// original's place. The telemetry is cut to the length that was kept and the marker goes
/// last.
///
/// Nothing the take wrote is changed until the result has been verified. A failure at any
/// point before the manifest is written leaves the package exactly as it was, so recovery
/// can be tried again; after it, every file in the package plays.
public enum TakeRecovery {
    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "recovery")

    /// Room kept free beyond the files being rewritten: the manifest, the sidecars, and
    /// not running a disk that is already short to empty.
    static let spareBytes: Int64 = 64 * 1_000_000

    public static func recover(_ package: RecordingPackage,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws(RecoveryError) -> RecoveryOutcome {
        try await recover(package,
                          availableBytes: DiskSpaceMonitor().availableBytes(for: package.url),
                          progress: progress)
    }

    /// `availableBytes` is a parameter so the short-of-space path can be tested without
    /// filling a disk.
    static func recover(_ package: RecordingPackage,
                        availableBytes: Int64?,
                        progress: @escaping @Sendable (Double) -> Void) async throws(RecoveryError) -> RecoveryOutcome {
        guard package.hasMarker else { throw .notInterrupted }
        let marker: TakeMarker
        do { marker = try package.readMarker() } catch { throw .unreadableMarker }

        if package.hasManifest, (try? package.readManifest()) != nil {
            package.removeMarker()
            log.notice("\(package.url.lastPathComponent, privacy: .public) had finished; removed its marker")
            return .alreadyFinished
        }

        let draft = marker.manifest
        var probes: [String: MediaProbe] = [:]
        for track in draft.tracks {
            if let probe = await MediaProbe.inspect(package.url.appending(path: track.path), kind: track.kind) {
                probes[track.path] = probe
            }
        }
        guard let screenTrack = draft.track(.screen) else { throw .unreadableVideo }
        guard let screen = probes[screenTrack.path] else {
            // A file with an index that still will not play is damage; a file with no index
            // at all never got as far as its first second.
            let atoms = MovieAtoms(contentsOf: package.url.appending(path: screenTrack.path))
            if atoms?.hasIndex == true { throw .unreadableVideo }
            log.notice("\(package.url.lastPathComponent, privacy: .public): nothing was recorded")
            return .nothingRecorded
        }
        progress(0.05)

        // Rewrite what is still in fragments, when there is room to. Where there is not —
        // most often the disk that filled up and stopped the take — the fragments are kept
        // as they are: they play, and a take that plays is the point.
        let unfinished = draft.tracks.compactMap { track in probes[track.path].map { (track, $0) } }
            .filter { !$0.1.isFinished }
        let needed = unfinished.reduce(Int64(0)) { $0 + $1.1.byteCount } + spareBytes
        let rewrites = availableBytes.map { $0 >= needed } ?? true
        var replacements: [(original: URL, rewrite: URL)] = []
        var keptAsFound: [String] = []

        let total = max(1, unfinished.reduce(Int64(0)) { $0 + $1.1.byteCount })
        var done: Int64 = 0
        for (track, probe) in unfinished {
            let original = package.url.appending(path: track.path)
            let rewrite = original.deletingLastPathComponent()
                .appendingPathComponent(".recovering-\(original.lastPathComponent)")
            let start = done
            let share = probe.byteCount
            if rewrites, await rewriteMovie(probe, to: rewrite, progress: { fraction in
                progress(min(0.9, 0.05 + 0.85 * (Double(start) + Double(share) * fraction) / Double(total)))
            }) {
                replacements.append((original, rewrite))
            } else {
                keptAsFound.append(track.path)
            }
            done += share
        }
        progress(0.9)

        var manifest = draft
        manifest.tracks = draft.tracks.filter { probes[$0.path] != nil }
        manifest.duration = screen.lastTime
        manifest.telemetry = present(draft.telemetry, in: package)
        // A frame is on screen until the next one, so the last one's own stretch is kept.
        let frame = 1 / Double(screenTrack.frameRate ?? 60)
        let cut = manifest.duration + frame
        let telemetryEnd = Self.telemetryEnd(in: package.telemetryFolder)
        manifest.recovery = RecordingManifest.Recovery(
            lostSeconds: telemetryEnd.map { max(0, $0 - cut) },
            keptAsFound: keptAsFound.isEmpty ? nil : keptAsFound)

        // The manifest first: it names files that already play, whether or not the rewrites
        // are swapped in after it. Refused here, and nothing has changed.
        do {
            try package.write(manifest)
        } catch {
            for replacement in replacements { try? FileManager.default.removeItem(at: replacement.rewrite) }
            throw Self.isOutOfSpace(error) ? .notEnoughSpace : .couldNotWrite(error.localizedDescription)
        }

        for replacement in replacements {
            do {
                _ = try FileManager.default.replaceItemAt(replacement.original, withItemAt: replacement.rewrite)
            } catch {
                // The original still plays and the manifest names it; only the tidying is lost.
                try? FileManager.default.removeItem(at: replacement.rewrite)
                log.error("Kept \(replacement.original.lastPathComponent, privacy: .public) as found: \(error.localizedDescription, privacy: .public)")
            }
        }
        trimTelemetry(in: package.telemetryFolder, through: cut)
        package.removeMarker()
        progress(1)
        log.notice("Recovered \(package.url.lastPathComponent, privacy: .public): \(manifest.duration, format: .fixed(precision: 2))s, \(keptAsFound.count) kept as found")
        return .recovered(manifest)
    }

    /// Whether a file plays, for a writer whose `finishWriting` was refused. A fragmented
    /// file that would not finish still holds every second up to its last fragment.
    public static func isPlayable(_ url: URL, kind: RecordingManifest.Track.Kind) async -> Bool {
        await MediaProbe.inspect(url, kind: kind) != nil
    }

    // MARK: - Rewriting

    /// Copies every sample of a fragmented file into an ordinary one, unchanged: no
    /// decoding, no re-encoding, the same times. Then checks the copy.
    ///
    /// The session starts at zero, which is what reproduces the original's timeline
    /// exactly — the camera's empty stretch before its first frame, the sound's encoder
    /// priming — measured against a finished file, edit list for edit list.
    static func rewriteMovie(_ probe: MediaProbe, to destination: URL,
                             progress: (Double) -> Void) async -> Bool {
        // Ours, left by an earlier attempt that did not finish; never the original.
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: probe.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            guard let track = try await asset.loadTracks(withMediaType: probe.mediaType).first else { return false }
            let formats = try await track.load(.formatDescriptions)
            let transform = try await track.load(.preferredTransform)

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return false }
            reader.add(output)

            let writer = try AVAssetWriter(url: destination, fileType: probe.fileType)
            let input = AVAssetWriterInput(mediaType: probe.mediaType, outputSettings: nil, sourceFormatHint: formats.first)
            input.expectsMediaDataInRealTime = false
            if probe.mediaType == .video { input.transform = transform }
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            guard reader.startReading(), writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)

            let end = max(probe.lastTime, 0.001)
            // Stored in decode order, so shown times go back and forth; the bar should not.
            var reported = 0.0
            while let buffer = output.copyNextSampleBuffer() {
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { break }
                    try? await Task.sleep(for: .milliseconds(2))
                }
                guard input.append(buffer) else {
                    reader.cancelReading()
                    writer.cancelWriting()
                    return false
                }
                let time = buffer.presentationTimeStamp
                if time.isValid, time.seconds / end > reported {
                    reported = min(1, time.seconds / end)
                    progress(reported)
                }
            }
            // A reader that stopped at a damaged fragment has still read everything before
            // it, and the probe counted the same way; the comparison below decides.
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { return false }
        } catch {
            log.error("Couldn't rewrite \(probe.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            return false
        }

        guard let copy = await MediaProbe.inspect(destination, mediaType: probe.mediaType),
              copy.isFinished,
              copy.sampleCount == probe.sampleCount,
              abs(copy.lastTime - probe.lastTime) < 0.001
        else {
            log.error("The rewrite of \(probe.url.lastPathComponent, privacy: .public) did not match it; keeping the original")
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        return true
    }

    // MARK: - The manifest's telemetry

    /// The telemetry the draft named, less what is not on disk or is empty. A sidecar
    /// that never got a line is removed when it closes; after a crash it may never have
    /// been created. The pointer artwork's index is written when a take stops, so an
    /// interrupted take never has one, and its pointer is drawn the way every take's was
    /// before the artwork was kept.
    static func present(_ telemetry: RecordingManifest.Telemetry, in package: RecordingPackage) -> RecordingManifest.Telemetry {
        func kept(_ path: String?) -> String? {
            guard let path else { return nil }
            let url = package.url.appending(path: path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0 ? path : nil
        }
        var result = telemetry
        result.cursor = kept(telemetry.cursor)
        result.input = kept(telemetry.input)
        result.windowBounds = kept(telemetry.windowBounds)
        result.focus = kept(telemetry.focus)
        result.cursorArtwork = kept(telemetry.cursorArtwork)
        result.markers = kept(telemetry.markers)
        result.picture = kept(telemetry.picture)
        return result
    }

    // MARK: - Cutting the telemetry to the picture

    /// Every sidecar, whatever writes it: they are all JSON Lines with a time in `t`, at the
    /// top of the line or one level in (an input sample is `{"mouseDown": {"t": …}}`).
    private static func sidecars(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
    }

    static func time(ofLine line: Data) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if let t = (object["t"] as? NSNumber)?.doubleValue { return t }
        if object.count == 1, let inner = object.values.first as? [String: Any],
           let t = (inner["t"] as? NSNumber)?.doubleValue { return t }
        return nil
    }

    /// The last moment any sidecar recorded — roughly when the take really stopped.
    static func telemetryEnd(in folder: URL) -> Double? {
        var end: Double?
        for file in sidecars(in: folder) {
            guard let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: 0x0A) {
                if let t = time(ofLine: Data(line)) { end = max(end ?? t, t) }
            }
        }
        return end
    }

    /// Drops every line after `end`, and the half-written line a crash leaves at the end of
    /// a file. Best effort: a sidecar that cannot be rewritten keeps its extra lines, which
    /// the editor ignores past the end of the picture anyway.
    static func trimTelemetry(in folder: URL, through end: Double) {
        for file in sidecars(in: folder) {
            guard let data = try? Data(contentsOf: file) else { continue }
            var kept = Data()
            var changed = data.last != 0x0A && !data.isEmpty
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let line = Data(line)
                let isWhole = (try? JSONSerialization.jsonObject(with: line)) != nil
                if isWhole, (time(ofLine: line) ?? 0) <= end {
                    kept.append(line)
                    kept.append(0x0A)
                } else {
                    changed = true
                }
            }
            guard changed else { continue }
            let temporary = folder.appendingPathComponent(".\(file.lastPathComponent).recovering")
            do {
                try kept.write(to: temporary, options: .atomic)
                _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                log.error("Couldn't cut \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func isOutOfSpace(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error { return isOutOfSpace(underlying) }
        return false
    }
}

/// What one media file holds, read without trusting anything but the file.
struct MediaProbe: Sendable {
    let url: URL
    let mediaType: AVMediaType
    let atoms: MovieAtoms
    let byteCount: Int64
    /// Samples a reader could get out of it.
    let sampleCount: Int
    /// The last sample's time, in the file's own timeline: for the screen, seconds since
    /// its first frame.
    let lastTime: Double

    var isFinished: Bool { atoms.isFinished }

    var fileType: AVFileType {
        switch url.pathExtension.lowercased() {
        case "m4a": .m4a
        case "mp4": .mp4
        default: .mov
        }
    }

    static func inspect(_ url: URL, kind: RecordingManifest.Track.Kind) async -> MediaProbe? {
        await inspect(url, mediaType: kind == .screen || kind == .webcam ? .video : .audio)
    }

    /// `nil` unless the file opens, has a track of the kind asked for with at least one
    /// sample in it, and that sample decodes — a picture for video, sound for audio.
    static func inspect(_ url: URL, mediaType: AVMediaType) async -> MediaProbe? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, let atoms = MovieAtoms(contentsOf: url), atoms.hasIndex else { return nil }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: mediaType).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var count = 0
        var last = -Double.infinity
        var shown: [Double] = []
        while let buffer = output.copyNextSampleBuffer() {
            let samples = CMSampleBufferGetNumSamples(buffer)
            guard samples > 0 else { continue }
            count += samples
            if mediaType == .video, let timings = try? buffer.sampleTimingInfos() {
                for timing in timings where timing.presentationTimeStamp.isValid {
                    shown.append(timing.presentationTimeStamp.seconds)
                }
            } else if buffer.presentationTimeStamp.isValid {
                // A sound buffer holds many packets; its end is where the next begins.
                let end = buffer.presentationTimeStamp + (buffer.duration.isValid ? buffer.duration : .zero)
                last = max(last, end.seconds)
            }
        }
        if mediaType == .video, !shown.isEmpty {
            last = lastWhole(shown.sorted())
        }
        guard count > 0, last.isFinite else { return nil }
        guard await decodes(asset, track: track, mediaType: mediaType, at: last) else { return nil }
        return MediaProbe(url: url, mediaType: mediaType, atoms: atoms, byteCount: Int64(size),
                          sampleCount: count, lastTime: last)
    }

    /// The last frame of the unbroken run the picture ends with.
    ///
    /// Frames are stored in the order they are decoded, which with B-frames is not the order
    /// they are shown, so a file cut off mid-fragment can hold a frame that is shown after
    /// one it lost: measured, a take that shows frames 57 and 59 with 58 still to come.
    /// Only the last few frames can be missing their neighbours — a frame is never stored
    /// further from its place than the encoder's reordering reaches — so the last
    /// `reorderReach` shown frames are checked for a hole, and the take ends before the
    /// first one. The decode times cannot answer this: a QuickTime movie may decode a frame
    /// after it is shown, and these do.
    ///
    /// The stragglers stay in the file; the take simply ends before them, the way the
    /// manifest's duration always ends a take.
    static func lastWhole(_ shown: [Double], reorderReach: Int = 16) -> Double {
        guard let final = shown.last else { return -.infinity }
        guard shown.count >= 3 else { return final }
        let recent = shown.suffix(61)
        let gaps = zip(recent, recent.dropFirst()).map { $1 - $0 }.sorted()
        let spacing = gaps[gaps.count / 2]
        let tail = Array(shown.suffix(reorderReach + 1))
        for (earlier, later) in zip(tail, tail.dropFirst()) where later - earlier > spacing * 1.5 {
            return earlier
        }
        return final
    }

    /// Whether the start and the end of what was read actually decode: counting samples
    /// proves they are there, not that they are pictures.
    private static func decodes(_ asset: AVURLAsset, track: AVAssetTrack, mediaType: AVMediaType, at last: Double) async -> Bool {
        if mediaType == .video {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            generator.maximumSize = CGSize(width: 64, height: 64)
            for seconds in [0, last] {
                guard (try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))) != nil else { return false }
            }
            return true
        }
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        defer { reader.cancelReading() }
        while let buffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(buffer) > 0 { return true }
        }
        return false
    }
}
