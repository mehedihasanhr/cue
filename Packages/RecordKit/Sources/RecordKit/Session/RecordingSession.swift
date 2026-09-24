import AVFoundation
import Foundation
import Observation
import os
import ScreenCaptureKit

/// One recording, from "go" to a `.klikrec` package.
///
/// The conductor: it starts the screen, the microphone and the telemetry together on one
/// clock, watches the disk, and stops everything in the right order. It is `@MainActor`
/// and `@Observable` because it is what a UI binds to — no frame ever reaches it, so
/// there is nothing here for an actor to protect.
@MainActor
@Observable
public final class RecordingSession {
    public enum State: Equatable, Sendable {
        case idle
        case preparing
        case countdown(remaining: Int)
        case recording(startedAt: Date)
        /// Still armed, writing nothing. The paused stretch never reaches the file.
        case paused(startedAt: Date, at: Date)
        case finishing
        case finished(URL)
        case failed(RecordingError)

        public var isBusy: Bool {
            switch self {
            case .idle, .finished, .failed: false
            case .preparing, .countdown, .recording, .paused, .finishing: true
            }
        }

        /// A take is under way: something has been written, or is being written right now.
        ///
        /// The one answer to "may this be stopped, and does stopping keep the file?", and
        /// the reason it exists at all. Stop used to be decided twice — once by the bar,
        /// which counted `.paused` as recording, and once by the bridge's `stop()`, which
        /// matched `.recording` alone. The two disagreed for exactly one state, and in that
        /// state the button was live and the guard silently refused: pause, then stop, and
        /// the take was gone. A single predicate that both the button's enablement and the
        /// guard read cannot disagree with itself, which is a stronger guarantee than
        /// adding a second `case .paused` to the guard and hoping the next reader copies it.
        ///
        /// `.paused` counts because pausing holds the file open rather than closing it:
        /// `stop()` resumes first and then finishes, so the recorded stretch survives.
        /// `.finishing` does not — the stop already happened.
        public var isTaking: Bool {
            switch self {
            case .recording, .paused: true
            case .idle, .preparing, .countdown, .finishing, .finished, .failed: false
            }
        }

        /// Getting ready: permission, content, the writer, the encoder, and the countdown
        /// that hides all of it. Nothing is written yet, so there is nothing here to lose
        /// by cancelling — which is why this is a different question from `isTaking`.
        public var isStarting: Bool {
            switch self {
            case .preparing, .countdown: true
            case .idle, .recording, .paused, .finishing, .finished, .failed: false
            }
        }

        /// Seconds left before the first frame, or `nil` when nothing is counting down.
        public var countdownRemaining: Int? {
            if case .countdown(let remaining) = self { remaining } else { nil }
        }

        /// What went wrong, for a UI that has to say it. A failure the user cannot read is
        /// the same as no failure at all.
        public var failure: RecordingError? {
            if case .failed(let error) = self { error } else { nil }
        }

        /// The hold, as a state change rather than as a side effect.
        ///
        /// `nil` when there is nothing to hold. Pulled out of `pause()` so that the pause
        /// and resume arithmetic — the half of stopping-while-paused that decides whether
        /// the take can still be finished — is provable in a test, which the capture path
        /// around it never can be: it needs a screen, a permission grant and an encoder.
        func held(at now: Date) -> Self? {
            guard case .recording(let started) = self else { return nil }
            return .paused(startedAt: started, at: now)
        }

        /// Letting go of the hold. `nil` when nothing is being held.
        ///
        /// The start time moves forward by the length of the hold, so the elapsed time a UI
        /// shows counts recorded seconds rather than wall-clock ones — the paused stretch is
        /// absent from the file, so it must be absent from the clock too.
        func released(at now: Date) -> Self? {
            guard case .paused(let started, let pausedAt) = self else { return nil }
            return .recording(startedAt: started.addingTimeInterval(now.timeIntervalSince(pausedAt)))
        }
    }

    public private(set) var state: State = .idle
    /// Set when the disk is getting tight, so the UI can say so before the stop that
    /// follows.
    public private(set) var diskWarning: String?

    private let content = ShareableContentStore()
    private let disk = DiskSpaceMonitor()
    private var clock = RecordingClock()
    private let queue = DispatchQueue(label: "com.stackrover.klik.studio.capture", qos: .userInitiated)

    private var package: RecordingPackage?
    private var configuration: RecordingConfiguration?
    private var writer: SessionWriter?
    private var screen: ScreenRecorder?
    private var microphone: MicrophoneRecorder?
    private var cursor: CursorTracker?
    private var focus: FocusTracker?
    private var cursorWriter: JSONLWriter?
    private var inputWriter: JSONLWriter?
    private var focusWriter: JSONLWriter?
    private var diskTimer: Timer?
    private var startedAt: Date?
    private var pixelSize: CGSize = .zero
    private var displayScale: Double = 2

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "session")

    public init() {}

    // MARK: - Starting

    /// Counts down, then records until `stop()`.
    ///
    /// The countdown is part of starting rather than something the UI does first,
    /// because everything expensive — permission, content, the writer, the encoder —
    /// happens during it. By the time the number reaches zero the recording is already
    /// warm, so "0" and the first frame are the same moment.
    public func start(_ configuration: RecordingConfiguration, countdown: Int = 3) async {
        guard !state.isBusy else {
            state = .failed(.alreadyRecording)
            return
        }
        state = .preparing
        diskWarning = nil
        self.configuration = configuration

        do {
            try await prepare(configuration)
        } catch let error as RecordingError {
            fail(error)
            return
        } catch {
            fail(.contentUnavailable(error.localizedDescription))
            return
        }

        // Cancelled while getting ready. `cancel()` ran before any of the above existed,
        // so the writer and the stream that arrived after it are still here and still
        // holding a file — they have to go the same way, or the app keeps an encoder open
        // that nothing can reach. Worth guarding now that the bar offers a Cancel during
        // the countdown: before, nothing could interrupt this window.
        guard case .preparing = state else {
            await discard()
            return
        }

        for remaining in stride(from: countdown, to: 0, by: -1) {
            state = .countdown(remaining: remaining)
            try? await Task.sleep(for: .seconds(1))
            // "Is this still my countdown?" rather than a list of the states that mean
            // stop: a state added later would not be on such a list, and the cost of
            // missing one here is a bar that counts down, reports itself as recording and
            // writes nothing. A cancel has already discarded the package by this point,
            // so returning is the whole of the work.
            guard state.countdownRemaining == remaining else { return }
        }

        do {
            try await screen?.start(systemAudio: configuration.systemAudio)
        } catch let error as RecordingError {
            fail(error)
            return
        } catch {
            fail(.contentUnavailable(error.localizedDescription))
            return
        }
        microphone?.start()
        cursor?.start()
        focus?.start()
        watchDisk()

        startedAt = .now
        state = .recording(startedAt: .now)
        Self.log.notice("Recording started into \(self.package?.url.lastPathComponent ?? "?", privacy: .public)")
    }

    /// Everything that can fail, before the countdown gives the user a reason to expect
    /// it to work.
    private func prepare(_ configuration: RecordingConfiguration) async throws {
        let shareable = try await content.content()
        let filter = try content.filter(for: configuration.target, in: shareable)
        let streamConfiguration = configuration.streamConfiguration(for: filter)
        pixelSize = CGSize(width: streamConfiguration.width, height: streamConfiguration.height)
        displayScale = Double(filter.pointPixelScale)

        let package = try RecordingPackage.create(named: configuration.name, in: configuration.destination)
        self.package = package

        if case .stop(let bytes) = disk.verdict(for: package.url) {
            package.discard()
            throw RecordingError.lowDiskSpace(bytesAvailable: bytes)
        }

        clock = RecordingClock()
        // Resolved now rather than when the request was made: a microphone unplugged in
        // between has to fail here, where the user is still watching a countdown.
        let microphoneDevice = try configuration.microphoneID.map { id throws(RecordingError) -> AVCaptureDevice in
            guard let device = AVCaptureDevice(uniqueID: id) else { throw RecordingError.deviceLost(id) }
            return device
        }
        let writer = try SessionWriter(url: package.mediaFolder.appendingPathComponent("screen.mov"),
                                       pixelSize: pixelSize,
                                       codec: configuration.codec.resolved,
                                       bitrate: configuration.quality.bitrate(forPixels: Int(pixelSize.width * pixelSize.height)),
                                       frameRate: configuration.frameRate,
                                       systemAudio: configuration.systemAudio,
                                       microphone: microphoneDevice != nil,
                                       clock: clock,
                                       queue: queue)
        self.writer = writer

        screen = ScreenRecorder(filter: filter,
                                configuration: streamConfiguration,
                                writer: writer) { [weak self] error in
            Task { @MainActor in self?.interrupted(by: error) }
        }

        if let microphoneDevice {
            microphone = try MicrophoneRecorder(device: microphoneDevice, writer: writer) { [weak self] error in
                Task { @MainActor in self?.interrupted(by: error) }
            }
        }

        startTelemetry(for: configuration, filter: filter, package: package)
    }

    private func startTelemetry(for configuration: RecordingConfiguration,
                                filter: SCContentFilter,
                                package: RecordingPackage) {
        let cursorWriter = JSONLWriter(url: package.telemetryFolder.appendingPathComponent("cursor.jsonl"), queue: queue)
        let inputWriter = configuration.capturesClicks
            ? JSONLWriter(url: package.telemetryFolder.appendingPathComponent("input.jsonl"), queue: queue)
            : nil
        let focusWriter = configuration.capturesFocus
            ? JSONLWriter(url: package.telemetryFolder.appendingPathComponent("focus.jsonl"), queue: queue)
            : nil
        queue.sync {
            try? cursorWriter.open()
            try? inputWriter?.open()
            try? focusWriter?.open()
        }
        self.cursorWriter = cursorWriter
        self.inputWriter = inputWriter
        self.focusWriter = focusWriter

        // Where the recorded area starts on screen, so a pointer position becomes a
        // position inside the frame.
        var origin = filter.contentRect.origin
        if case .area(_, let rect) = configuration.target {
            origin.x += rect.origin.x
            origin.y += rect.origin.y
        }
        let mapper = CursorMapper(origin: origin)
        cursor = CursorTracker(cursorWriter: cursorWriter,
                               inputWriter: inputWriter,
                               queue: queue,
                               clock: clock,
                               mapper: mapper,
                               sampleRate: configuration.cursorSampleRate,
                               capturesKeystrokes: configuration.capturesKeystrokes)
        if let focusWriter {
            focus = FocusTracker(writer: focusWriter,
                                 queue: queue,
                                 clock: clock,
                                 mapper: mapper,
                                 tracksFields: configuration.capturesKeystrokes)
        }
    }

    // MARK: - Stopping

    /// Stops, writes the manifest, and hands back the package.
    /// Holds the recording without ending it.
    ///
    /// The stream keeps running — restarting it would cost a second of black — but the
    /// writer stops accepting buffers and remembers how long the hold lasted, so the
    /// paused stretch is absent from the file rather than frozen in it.
    public func pause() {
        guard let held = state.held(at: .now), let writer else { return }
        queue.async { writer.setPaused(true) }
        cursor?.stop()
        focus?.stop()
        state = held
        Self.log.notice("Paused")
    }

    public func resume() {
        guard let released = state.released(at: .now), let writer else { return }
        queue.async { writer.setPaused(false) }
        cursor?.start()
        focus?.start()
        state = released
        Self.log.notice("Resumed")
    }

    public var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    @discardableResult
    public func stop() async -> Result<URL, RecordingError> {
        // A paused take is stopped by letting it go first: the file is still open, so
        // finishing it keeps every recorded second. This is the behaviour the bar promises
        // and `isTaking` is what both of them ask, so neither can be stricter than the
        // other.
        guard state.isTaking else { return .failure(.notRecording) }
        resume()
        guard case .recording = state, let writer, let package, let configuration else {
            return .failure(.notRecording)
        }
        state = .finishing
        await teardown()

        do {
            let duration = try await writer.finish()
            let manifest = manifest(for: configuration, package: package, duration: duration.seconds)
            try package.write(manifest)
            state = .finished(package.url)
            Self.log.notice("Finished \(package.url.lastPathComponent, privacy: .public) (\(duration.seconds, format: .fixed(precision: 1))s)")
            reset()
            return .success(package.url)
        } catch let error as RecordingError {
            fail(error)
            return .failure(error)
        } catch {
            let failure = RecordingError.writerFailed(error.localizedDescription)
            fail(failure)
            return .failure(failure)
        }
    }

    /// Throws the recording away — a cancelled countdown, or a take the user does not
    /// want kept.
    public func cancel() async {
        guard state.isBusy else { return }
        await discard()
        state = .idle
    }

    /// Tears the apparatus down and throws the file away, whatever state we are in.
    ///
    /// Split out of `cancel()` so `start()` can undo a half-built recording whose state
    /// has already been reset out from under it — `cancel()`'s own guard would refuse that
    /// case, which is the one that leaks an encoder.
    private func discard() async {
        await teardown()
        writer?.cancel()
        package?.discard()
        reset()
    }

    /// Puts a reported failure away.
    ///
    /// `.failed` is terminal, and a bar that draws it — which it now does — needs a way
    /// back to offering a take. Nothing else changes: the apparatus was already torn down
    /// by whoever failed, so this only clears what is on screen.
    public func acknowledgeFailure() {
        guard case .failed = state else { return }
        state = .idle
    }

    /// Something stopped on its own. What is recorded so far is worth keeping, so this
    /// finishes the file rather than discarding it.
    private func interrupted(by error: RecordingError) {
        guard state.isBusy else { return }
        Self.log.error("Interrupted: \(error.localizedDescription ?? "unknown", privacy: .public)")
        Task {
            // The same predicate as the bar's Stop button, for the same reason: a take
            // interrupted while it was paused is still a take with seconds in it, and
            // matching `.recording` alone here threw those away — the opposite of what the
            // comment above promises.
            if state.isTaking {
                _ = await stop()
            } else {
                await cancel()
            }
            state = .failed(error)
        }
    }

    private func teardown() async {
        diskTimer?.invalidate()
        diskTimer = nil
        cursor?.stop()
        focus?.stop()
        microphone?.stop()
        await screen?.stop()
        // The result comes back out of the closure rather than being assigned inside
        // it: `queue.sync` runs its body on the capture queue, and this object is on the
        // main actor.
        focusTrackWritten = queue.sync { [focusWriter, cursorWriter, inputWriter] in
            _ = cursorWriter?.close()
            _ = inputWriter?.close()
            return focusWriter?.close() ?? false
        }
    }

    /// Whether the focus track ended up with anything in it. An empty sidecar is
    /// deleted on close, so the manifest must not point at it.
    private var focusTrackWritten = false

    private func reset() {
        writer = nil
        screen = nil
        microphone = nil
        cursor = nil
        focus = nil
        focusTrackWritten = false
        package = nil
        configuration = nil
        startedAt = nil
    }

    private func fail(_ error: RecordingError) {
        Self.log.error("Failed: \(error.localizedDescription ?? "unknown", privacy: .public)")
        package?.discard()
        reset()
        state = .failed(error)
    }

    // MARK: - Manifest

    private func manifest(for configuration: RecordingConfiguration,
                          package: RecordingPackage,
                          duration: Double) -> RecordingManifest {
        var tracks: [RecordingManifest.Track] = [
            .init(kind: .screen,
                  path: "media/screen.mov",
                  pixelSize: pixelSize,
                  frameRate: configuration.frameRate,
                  codec: configuration.codec.resolved.rawValue),
        ]
        // The screen file carries the audio tracks; naming them here saves the editor
        // from opening the asset to find out whether there is any.
        if configuration.systemAudio {
            tracks.append(.init(kind: .systemAudio, path: "media/screen.mov"))
        }
        if configuration.microphoneID != nil {
            tracks.append(.init(kind: .microphone, path: "media/screen.mov"))
        }

        var sourceRect: CGRect?
        if case .area(_, let rect) = configuration.target { sourceRect = rect }

        return RecordingManifest(name: configuration.name,
                                 createdAt: startedAt ?? .now,
                                 duration: duration,
                                 displayScale: displayScale,
                                 sourceRect: sourceRect,
                                 tracks: tracks,
                                 telemetry: .init(cursor: "telemetry/cursor.jsonl",
                                                  input: configuration.capturesClicks ? "telemetry/input.jsonl" : nil,
                                                  focus: focusTrackWritten ? "telemetry/focus.jsonl" : nil))
    }

    // MARK: - Disk

    /// Checks every few seconds rather than per frame: the volume's free space does not
    /// change meaningfully between frames, and a `stat` per frame is a real cost.
    private func watchDisk() {
        guard let package else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.disk.verdict(for: package.url) {
                case .fine:
                    self.diskWarning = nil
                case .low(let bytes):
                    self.diskWarning = "\(ByteCountFormatStyle(style: .file).format(bytes)) left on disk."
                case .stop(let bytes):
                    self.interrupted(by: .lowDiskSpace(bytesAvailable: bytes))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diskTimer = timer
    }
}
