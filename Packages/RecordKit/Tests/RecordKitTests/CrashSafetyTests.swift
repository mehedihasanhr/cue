import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import RecordKit
@testable import RecordKitCrashProbe

/// A take is never lost: what is written survives the app dying, the package says it did
/// not finish, and recovery makes it an ordinary recording again.
///
/// Every take here is made up — pictures and sound generated in the test and written
/// through the recorder's own writers — so nothing is captured and nothing asks for
/// permission. A crash is simulated two ways: by copying the package while the writers are
/// still open, which is byte for byte what a crash leaves (the kernel has everything the
/// process wrote), and by running the writer in a child process and killing it with
/// SIGKILL.
@Suite("Crash safety")
struct CrashSafetyTests {
    private func temporaryFolder() -> URL {
        let url = URL.temporaryDirectory.appending(path: "RecordKitCrashSafety-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// What a crash at this moment would leave: the package, copied as it is on disk now.
    private func crash(_ take: SyntheticTake, into folder: URL) throws -> RecordingPackage {
        let copy = folder.appendingPathComponent(take.package.url.lastPathComponent)
        try FileManager.default.copyItem(at: take.package.url, to: copy)
        return RecordingPackage(url: copy)
    }

    /// The writers of a take whose copy has been taken, let go of. Cancelled rather than
    /// finished, so nothing is spent closing a file nobody reads.
    private func abandon(_ take: SyntheticTake) async {
        take.queue.sync { _ = take.cursor.close() }
        take.screen.cancel()
        take.systemAudio.cancel()
        take.microphone.cancel()
        await withCheckedContinuation { continuation in take.queue.async { continuation.resume() } }
    }

    /// Every frame's presentation time in the order they are shown, and every decode time
    /// in the order they are stored.
    private func frameTimes(of url: URL) async throws -> (shown: [Double], decoded: [Double]) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var shown: [Double] = []
        var decoded: [Double] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            for timing in try buffer.sampleTimingInfos() {
                shown.append(timing.presentationTimeStamp.seconds)
                if timing.decodeTimeStamp.isValid { decoded.append(timing.decodeTimeStamp.seconds) }
            }
        }
        return (shown.sorted(), decoded)
    }

    private func duration(of url: URL, _ type: AVMediaType) async throws -> Double {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try #require(try await asset.loadTracks(withMediaType: type).first)
        return try await track.load(.timeRange).duration.seconds
    }

    private func isPlayable(_ url: URL) async throws -> Bool {
        try await AVURLAsset(url: url).load(.isPlayable)
    }

    /// Frames one frame-length apart from zero, with none missing and none out of order,
    /// as far as the take runs.
    private func expectFramesInPlace(_ times: (shown: [Double], decoded: [Double]), frameRate: Int,
                                     through end: Double = .infinity,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        for (index, time) in times.shown.enumerated() where time <= end + 1e-6 {
            let expected = Double(index) / Double(frameRate)
            guard abs(time - expected) < 0.002 else {
                Issue.record("frame \(index) is at \(time)s, not \(expected)s", sourceLocation: sourceLocation)
                return
            }
        }
        #expect(zip(times.decoded, times.decoded.dropFirst()).allSatisfy { $0 < $1 },
                "decode times only ever go forward", sourceLocation: sourceLocation)
    }

    private func lines(of url: URL) throws -> [Data] {
        try Data(contentsOf: url).split(separator: 0x0A).map { Data($0) }
    }

    private func contents(of package: RecordingPackage) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let walker = FileManager.default.enumerator(at: package.url, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = walker?.nextObject() as? URL {
            guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            result[package.relativePath(of: file)] = try Data(contentsOf: file)
        }
        return result
    }

    // MARK: - Writing

    /// A take that ends normally is the file it always was: one index at the end, no
    /// fragments, every frame where the clock put it.
    @Test func aFinishedTakeIsAnOrdinaryMovie() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = try SyntheticTake(named: "Finished", in: folder)
        take.record(seconds: 2.5)
        let manifest = try await take.finish()

        let screen = take.package.mediaFolder.appendingPathComponent("screen.mov")
        let atoms = try #require(MovieAtoms(contentsOf: screen))
        #expect(atoms.isFinished)
        #expect(!atoms.hasFragments, "finishing turns the fragments back into one movie")
        #expect(try await isPlayable(screen))
        let times = try await frameTimes(of: screen)
        #expect(times.shown.count >= take.framesWritten)
        expectFramesInPlace(times, frameRate: take.frameRate)
        #expect(manifest.duration >= 2.4)
        #expect(take.screen.droppedFrames == 0)

        for file in ["system-audio.m4a", "microphone-1.m4a"] {
            let url = take.package.mediaFolder.appendingPathComponent(file)
            #expect(try #require(MovieAtoms(contentsOf: url)).isFinished)
            #expect(abs(try await duration(of: url, .audio) - 2.5) < 0.1)
        }
        #expect(!take.package.hasMarker)
    }

    /// The same take, copied before it finished: the part up to its last second plays.
    /// Without fragments this copy is a file QuickTime will not open.
    @Test func anUnfinishedTakePlaysUpToItsLastFragment() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = try SyntheticTake(named: "Unfinished", in: folder)
        take.record(seconds: 3.5)
        let crashed = try crash(take, into: temporaryFolder())
        defer { try? FileManager.default.removeItem(at: crashed.url.deletingLastPathComponent()) }
        await abandon(take)

        let screen = crashed.mediaFolder.appendingPathComponent("screen.mov")
        let atoms = try #require(MovieAtoms(contentsOf: screen))
        #expect(atoms.hasFragments)
        #expect(!atoms.isFinished)
        #expect(try await isPlayable(screen))
        let length = try await duration(of: screen, .video)
        #expect(length > 3.5 - 1.25 && length <= 3.6, "at most a fragment and the encoder's few frames are lost; got \(length)s")
        for file in ["system-audio.m4a", "microphone-1.m4a"] {
            let sound = try await duration(of: crashed.mediaFolder.appendingPathComponent(file), .audio)
            #expect(sound > 3.5 - 1.25, "the sound is protected the same way; got \(sound)s")
        }
    }

    /// The pointer's sidecar reaches the file on a clock, not only when a buffer fills, so
    /// it is never more than about a second behind the picture.
    @Test func theSidecarReachesTheDiskWithinASecond() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = DispatchQueue(label: "test.sidecar")
        let writer = JSONLWriter(url: folder.appendingPathComponent("input.jsonl"), queue: queue)
        queue.sync {
            try? writer.open()
            writer.append(InputSample.mouseDown(t: 1, button: 0, x: 1, y: 1))
            writer.append(InputSample.mouseUp(t: 1.1, button: 0, x: 1, y: 1))
        }
        try await Task.sleep(for: .seconds(1))
        #expect(try lines(of: writer.url).count == 2, "two clicks are not 64 KB, and used to wait for the take to end")
        queue.sync { _ = writer.close() }
    }

    // MARK: - Knowing a take was interrupted

    /// The marker is there from before the first frame until the manifest is written, and
    /// it describes the take that was set up.
    @Test func aTakeCarriesAMarkerUntilItFinishes() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = try SyntheticTake(named: "Marked", in: folder)
        #expect(take.package.hasMarker)
        let marker = try take.package.readMarker()
        #expect(marker.processID == getpid())
        #expect(marker.manifest.tracks.map(\.kind) == [.screen, .systemAudio, .microphone])
        #expect(marker.manifest.track(.screen)?.frameRate == 30)
        #expect(!marker.isHeldByAnotherProcess, "this process's own take is the app's to judge")

        take.record(seconds: 0.5, realTime: false)
        _ = try await take.finish()
        #expect(!take.package.hasMarker)
        #expect(take.package.hasManifest)
    }

    /// The library lists what carries a marker, and leaves out the take being recorded
    /// here and one that another running copy of the app is recording.
    @Test func interruptedTakesAreListedAndLiveOnesAreNot() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = RecordingManifest(name: "Take", tracks: [.init(kind: .screen, path: "media/screen.mov")])

        let abandoned = try RecordingPackage.create(named: "Abandoned", in: folder)
        // A process that is gone: nothing runs with this ID.
        try abandoned.writeMarker(TakeMarker(manifest: manifest, processID: 99_999, processStartedAt: 1))
        let live = try RecordingPackage.create(named: "Live", in: folder)
        try live.writeMarker(TakeMarker(manifest: manifest))
        let elsewhere = try RecordingPackage.create(named: "Elsewhere", in: folder)
        let parent = getppid()
        try elsewhere.writeMarker(TakeMarker(manifest: manifest, processID: parent,
                                             processStartedAt: TakeMarker.startTime(of: parent)))
        let finished = try RecordingPackage.create(named: "Finished", in: folder)
        try finished.write(manifest)

        let found = RecordingLibrary(folder: folder).interruptedTakes(excluding: [live.url])
        #expect(found.map(\.name) == ["Abandoned"])
        #expect(found.first?.hasFinished == false)
        #expect(RecordingLibrary(folder: folder).entries().isEmpty == false, "a finished take is still an ordinary entry")
    }

    // MARK: - Recovering

    /// A take cut short becomes a normal recording: every playable second kept, the
    /// manifest completed and marked as recovered, the pointer cut to the picture, the
    /// marker gone, and every frame at the time the clock gave it.
    @Test func aTakeCutShortIsRecovered() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = try SyntheticTake(named: "Cut Short", in: folder)
        take.record(seconds: 4)
        let crashed = try crash(take, into: temporaryFolder())
        defer { try? FileManager.default.removeItem(at: crashed.url.deletingLastPathComponent()) }
        await abandon(take)
        try await expectRecovered(crashed, recordedFor: 4, frameRate: take.frameRate)
    }

    /// A take that was paused and then cut short: the pause is still gone from the
    /// recovered picture and pointer, so every frame and every sample is where the clock
    /// put it — the fragments change nothing about the timing rules.
    @Test func aPausedTakeCutShortKeepsItsTimeline() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = try SyntheticTake(named: "Paused", in: folder)
        take.record(seconds: 1.5)
        take.pause(seconds: 2)
        take.record(seconds: 2.5)
        let crashed = try crash(take, into: temporaryFolder())
        defer { try? FileManager.default.removeItem(at: crashed.url.deletingLastPathComponent()) }
        await abandon(take)
        // Four seconds were recorded; the two on hold are in no file.
        try await expectRecovered(crashed, recordedFor: 4, frameRate: take.frameRate)
        let cursor = try lines(of: crashed.telemetryFolder.appendingPathComponent("cursor.jsonl"))
            .map { try JSONDecoder().decode(CursorSample.self, from: $0) }
        let steps = zip(cursor, cursor.dropFirst()).map { $1.t - $0.t }
        #expect(steps.allSatisfy { abs($0 - 1.0 / 120) < 1e-6 }, "the pointer has no hole where the pause was")
    }

    /// The real thing: the writer in a child process, killed with SIGKILL part-way through.
    @Test func aTakeKilledMidStreamIsRecovered() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = try #require(Self.probeExecutable(), "the crash probe is built beside the tests")

        let process = Process()
        process.executableURL = probe
        process.arguments = [folder.path(percentEncoded: false), "Killed"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        defer { if process.isRunning { kill(pid, SIGKILL) } }

        var packagePath: String?
        var recorded = 0.0
        var pending = ""
        let reader = output.fileHandleForReading
        while recorded < 3.5 {
            let data = reader.availableData
            guard !data.isEmpty else { break }
            pending += String(decoding: data, as: UTF8.self)
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline])
                pending = String(pending[pending.index(after: newline)...])
                if line.hasPrefix("package ") { packagePath = String(line.dropFirst("package ".count)) }
                if line.hasPrefix("recorded "), let seconds = Double(line.dropFirst("recorded ".count)) { recorded = seconds }
            }
        }
        #expect(recorded >= 3.5, "the probe recorded for as long as it was asked to")
        kill(pid, SIGKILL)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)

        let package = RecordingPackage(url: URL(fileURLWithPath: try #require(packagePath)))
        #expect(package.hasMarker, "a killed take says it did not finish")
        #expect(!package.hasManifest)
        #expect(!(try package.readMarker()).isHeldByAnotherProcess, "its process is gone")
        let listed = RecordingLibrary(folder: folder).interruptedTakes()
        #expect(listed.map(\.url.lastPathComponent) == [package.url.lastPathComponent])
        #expect(listed.first?.hasFootage == true)

        try await expectRecovered(package, recordedFor: recorded, frameRate: 30)
    }

    private func expectRecovered(_ package: RecordingPackage, recordedFor seconds: Double, frameRate: Int,
                                 sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let progress = ProgressLog()
        let outcome = try await TakeRecovery.recover(package) { progress.add($0) }
        guard case .recovered(let manifest) = outcome else {
            Issue.record("expected a recovered take, got \(outcome)", sourceLocation: sourceLocation)
            return
        }
        // What the manifest says, and that it is what is on disk.
        #expect(Self.sameApartFromDates(try package.readManifest(), manifest), sourceLocation: sourceLocation)
        #expect(!package.hasMarker, sourceLocation: sourceLocation)
        #expect(manifest.tracks.map(\.kind) == [.screen, .systemAudio, .microphone], sourceLocation: sourceLocation)
        #expect(manifest.track(.screen)?.frameRate == frameRate, sourceLocation: sourceLocation)
        #expect(manifest.track(.microphone)?.name == "Test Microphone", sourceLocation: sourceLocation)
        #expect(manifest.duration > seconds - 1.25 && manifest.duration < seconds,
                "within a fragment of where it stopped; got \(manifest.duration)s of \(seconds)s", sourceLocation: sourceLocation)
        let recovery = try #require(manifest.recovery, sourceLocation: sourceLocation)
        let lost = try #require(recovery.lostSeconds, "the pointer says roughly when it really stopped", sourceLocation: sourceLocation)
        #expect(lost >= 0 && lost < 1.3, "lost \(lost)s", sourceLocation: sourceLocation)
        #expect(recovery.keptAsFound == nil, "there was room to rewrite everything", sourceLocation: sourceLocation)
        #expect(progress.values.last == 1, sourceLocation: sourceLocation)
        #expect(zip(progress.values, progress.values.dropFirst()).allSatisfy { $0 <= $1 }, "\(progress.values.map { ($0 * 1000).rounded() / 1000 })", sourceLocation: sourceLocation)

        // The picture: an ordinary movie now, with every frame where it belongs.
        let screen = package.mediaFolder.appendingPathComponent("screen.mov")
        #expect(try #require(MovieAtoms(contentsOf: screen)).isFinished, sourceLocation: sourceLocation)
        #expect(try await isPlayable(screen), sourceLocation: sourceLocation)
        let times = try await frameTimes(of: screen)
        expectFramesInPlace(times, frameRate: frameRate, through: manifest.duration, sourceLocation: sourceLocation)
        #expect(times.shown.contains { abs($0 - manifest.duration) < 0.001 }, "the take ends on a frame", sourceLocation: sourceLocation)

        // Both sounds, the same length give or take their own fragment.
        for file in ["system-audio.m4a", "microphone-1.m4a"] {
            let url = package.mediaFolder.appendingPathComponent(file)
            #expect(try #require(MovieAtoms(contentsOf: url)).isFinished, sourceLocation: sourceLocation)
            let length = try await duration(of: url, .audio)
            #expect(length > seconds - 1.25 && length <= seconds + 0.05, "\(file): \(length)s", sourceLocation: sourceLocation)
        }

        // The pointer, cut to the picture and no further behind it than a flush.
        let cursor = try lines(of: package.telemetryFolder.appendingPathComponent("cursor.jsonl"))
        let samples = try cursor.map { try JSONDecoder().decode(CursorSample.self, from: $0) }
        let last = try #require(samples.last, sourceLocation: sourceLocation)
        #expect(samples.allSatisfy { $0.t <= manifest.duration + 1 / Double(frameRate) + 1e-9 }, sourceLocation: sourceLocation)
        #expect(last.t > manifest.duration - 0.6, "the sidecar kept up with the picture; ends at \(last.t)s", sourceLocation: sourceLocation)

        // No stray working files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: package.mediaFolder.path(percentEncoded: false))
            .filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty, sourceLocation: sourceLocation)
    }

    /// Stopped before the first frame: there is nothing to recover, recovery says so, and
    /// it does not make an empty recording out of it.
    @Test func aTakeStoppedBeforeItsFirstFrameHasNothingToRecover() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = try SyntheticTake(named: "Empty", in: folder)
        let crashed = try crash(take, into: temporaryFolder())
        defer { try? FileManager.default.removeItem(at: crashed.url.deletingLastPathComponent()) }
        await abandon(take)
        let before = try contents(of: crashed)

        #expect(RecordingLibrary(folder: crashed.url.deletingLastPathComponent()).interruptedTakes().first?.hasFootage == false,
                "the library can tell without opening anything")
        #expect(try await TakeRecovery.recover(crashed) == .nothingRecorded)
        #expect(!crashed.hasManifest, "no empty recording")
        #expect(try contents(of: crashed) == before, "nothing is changed, the marker included")
    }

    /// The marker outlived a take that did finish — the app stopped between writing the
    /// manifest and removing it. Recovery removes the marker and touches nothing else.
    @Test func aFinishedTakeWithItsMarkerLeftBehindOnlyLosesTheMarker() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = try SyntheticTake(named: "Finished Marked", in: folder)
        take.record(seconds: 1, realTime: false)
        let manifest = try await take.finish()
        try take.package.writeMarker(TakeMarker(manifest: take.manifest(duration: 0), processID: 99_999))
        var before = try contents(of: take.package)
        before[RecordingPackage.markerName] = nil

        #expect(try await TakeRecovery.recover(take.package) == .alreadyFinished)
        #expect(!take.package.hasMarker)
        #expect(Self.sameApartFromDates(try take.package.readManifest(), manifest))
        #expect(try contents(of: take.package) == before)
    }

    /// A recovery that cannot finish leaves the take exactly as it found it, so it can be
    /// tried again. Here the package cannot be written to, so the manifest is refused
    /// after the rewrites were made — and they are thrown away, not swapped in.
    @Test func aRecoveryThatCannotSaveLeavesTheTakeAsItWas() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = try SyntheticTake(named: "Locked", in: folder)
        take.record(seconds: 2.5)
        let crashed = try crash(take, into: temporaryFolder())
        defer { try? FileManager.default.removeItem(at: crashed.url.deletingLastPathComponent()) }
        await abandon(take)
        let before = try contents(of: crashed)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: crashed.url.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: crashed.url.path(percentEncoded: false)) }

        await #expect(throws: RecoveryError.self) { try await TakeRecovery.recover(crashed) }
        #expect(try contents(of: crashed) == before)
        #expect(crashed.hasMarker)
    }

    /// No room to rewrite — the disk that filled up and stopped the take. The fragments
    /// are kept as they are, because they play, and the manifest says so.
    @Test func aTakeWithNoRoomToRewriteIsKeptAsFound() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = try SyntheticTake(named: "Full Disk", in: folder)
        take.record(seconds: 2.5)
        let crashed = try crash(take, into: temporaryFolder())
        defer { try? FileManager.default.removeItem(at: crashed.url.deletingLastPathComponent()) }
        await abandon(take)
        let screenBefore = try Data(contentsOf: crashed.mediaFolder.appendingPathComponent("screen.mov"))

        let outcome = try await TakeRecovery.recover(crashed, availableBytes: 0, progress: { _ in })
        guard case .recovered(let manifest) = outcome else {
            Issue.record("expected a recovered take, got \(outcome)")
            return
        }
        #expect(manifest.recovery?.keptAsFound == ["media/screen.mov", "media/system-audio.m4a", "media/microphone-1.m4a"])
        let screen = crashed.mediaFolder.appendingPathComponent("screen.mov")
        #expect(try Data(contentsOf: screen) == screenBefore, "kept byte for byte")
        #expect(try await isPlayable(screen))
        expectFramesInPlace(try await frameTimes(of: screen), frameRate: take.frameRate, through: manifest.duration)
        #expect(!crashed.hasMarker)
    }

    // MARK: - Pieces

    /// Recordings from before recovery existed have no note about it, and still open.
    @Test func aManifestWithoutARecoveryNoteStillOpens() throws {
        let json = #"{"createdAt":"2026-09-01T10:00:00Z","displayScale":2,"duration":12.5,"formatVersion":1,"name":"Old","recordedBy":"Klik Studio","telemetry":{"cursor":"telemetry/cursor.jsonl"},"tracks":[{"kind":"screen","path":"media/screen.mov"}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(RecordingManifest.self, from: Data(json.utf8))
        #expect(manifest.recovery == nil)
        #expect(manifest.duration == 12.5)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let written = try #require(String(data: try encoder.encode(manifest), encoding: .utf8))
        #expect(!written.contains("recovery"), "a normal take's manifest looks as it always did")
    }

    /// The sidecars are cut at the picture's end, whatever shape their lines are, and the
    /// half-written line a crash leaves is dropped.
    @Test func telemetryIsCutToThePicture() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cursor = folder.appendingPathComponent("cursor.jsonl")
        let input = folder.appendingPathComponent("input.jsonl")
        try Data("""
        {"shape":"arrow","t":0.5,"x":1,"y":1}
        {"shape":"arrow","t":1.5,"x":1,"y":1}
        {"shape":"arrow","t":2.5,"x":1,"y":1}
        {"shape":"arr
        """.utf8).write(to: cursor)
        try Data("""
        {"mouseDown":{"button":0,"t":1,"x":1,"y":1}}
        {"mouseUp":{"button":0,"t":3,"x":1,"y":1}}

        """.utf8).write(to: input)

        #expect(TakeRecovery.telemetryEnd(in: folder) == 3)
        TakeRecovery.trimTelemetry(in: folder, through: 2)
        #expect(try lines(of: cursor).compactMap(TakeRecovery.time(ofLine:)) == [0.5, 1.5])
        #expect(try lines(of: input).compactMap(TakeRecovery.time(ofLine:)) == [1])
    }

    /// Finished, fragmented and cut off mid-write are told apart from the headers alone.
    @Test func atomsTellAFinishedMovieFromAnAbandonedOne() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func atom(_ type: String, _ body: Int) -> Data {
            var data = Data()
            let size = UInt32(8 + body)
            data.append(contentsOf: [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
            data.append(Data(type.utf8))
            data.append(Data(count: body))
            return data
        }
        let finished = folder.appendingPathComponent("finished.mov")
        try (atom("ftyp", 12) + atom("mdat", 100) + atom("moov", 40)).write(to: finished)
        let fragmented = folder.appendingPathComponent("fragmented.mov")
        try (atom("ftyp", 12) + atom("mdat", 100) + atom("moov", 40) + atom("moof", 20) + atom("mdat", 50)).write(to: fragmented)
        let cut = folder.appendingPathComponent("cut.mov")
        try (atom("ftyp", 12) + atom("moov", 40) + atom("mdat", 500).prefix(60)).write(to: cut)
        let neverIndexed = folder.appendingPathComponent("never.mov")
        try (atom("ftyp", 12) + atom("mdat", 500).prefix(60)).write(to: neverIndexed)

        #expect(try #require(MovieAtoms(contentsOf: finished)).isFinished)
        #expect(try #require(MovieAtoms(contentsOf: fragmented)).hasFragments)
        #expect(!(try #require(MovieAtoms(contentsOf: fragmented)).isFinished))
        #expect(try #require(MovieAtoms(contentsOf: cut)).isTruncated)
        #expect(!(try #require(MovieAtoms(contentsOf: neverIndexed)).hasIndex))
        #expect(MovieAtoms(contentsOf: folder.appendingPathComponent("absent.mov")) == nil)
    }

    /// A manifest read back from disk has its dates to the second, as ISO 8601 writes them.
    static func sameApartFromDates(_ first: RecordingManifest, _ second: RecordingManifest) -> Bool {
        var first = first, second = second
        first.createdAt = second.createdAt
        if first.recovery != nil, second.recovery != nil { first.recovery?.recoveredAt = second.recovery!.recoveredAt }
        return first == second
    }

    /// A take that ends on B-frames can be cut with a frame missing and the ones after it
    /// present — measured: frames 57, 59 and 61 with 58 and 60 still to come. The take ends
    /// before the first hole, not after the last straggler.
    @Test func aTakeEndsBeforeAFrameItLost() {
        let frame = 1.0 / 30
        let cut = (0...57).map { Double($0) * frame } + [59, 61].map { Double($0) * frame }
        #expect(abs(MediaProbe.lastWhole(cut) - 57 * frame) < 1e-9)
        // Nothing lost: the last frame is the last frame.
        let whole = (0...61).map { Double($0) * frame }
        #expect(MediaProbe.lastWhole(whole) == 61 * frame)
        // A frame dropped long before the end is the writer's business, not a lost tail.
        let dropped = (0...61).filter { $0 != 20 }.map { Double($0) * frame }
        #expect(MediaProbe.lastWhole(dropped) == 61 * frame)
    }

    // MARK: - The probe

    /// The crash probe is built into the same folder as this test bundle.
    static func probeExecutable() -> URL? {
        let bundles = [Bundle(for: ProgressLog.self)] + Bundle.allBundles
        for bundle in bundles where bundle.bundleURL.pathExtension == "xctest" {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("RecordKitCrashProbe")
            if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return nil
    }
}

/// Progress as it was reported, from whichever thread reported it.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}
