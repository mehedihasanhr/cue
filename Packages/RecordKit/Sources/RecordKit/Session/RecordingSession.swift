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
    /// The camera, and the file it writes.
    ///
    /// Both `nil` unless this take asked for a camera. They are the whole of the apparatus
    /// that can light the camera's indicator, so they are built in `prepare`, started with
    /// everything else at the end of the countdown, and torn down by `teardown()` — which
    /// runs on every path out of a take, including the ones nobody plans for.
    private var webcam: WebcamRecorder?
    private var webcamWriter: SessionWriter?
    /// What the camera's file holds, for the manifest. `nil` when there is no camera.
    private var webcamPixelSize: CGSize?
    private var webcamFrameRate: Int?
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
        // After the screen, deliberately. The camera's writer takes its time zero from the
        // clock the screen's first frame starts, so a camera that opened first would simply
        // drop frames until the screen caught up — starting it here wastes none.
        webcam?.start()
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

        try await prepareWebcam(configuration, package: package, clock: clock)
        startTelemetry(for: configuration, filter: filter, package: package)
    }

    /// The camera, when this take asked for one — and nothing at all when it did not.
    ///
    /// `configuration.webcamID == nil` returns before touching AVFoundation, before asking
    /// about permission, and before creating a file. That early return is the privacy
    /// guarantee in one line: no camera is opened, and no camera indicator lights, for a
    /// take that did not ask for a camera.
    ///
    /// Permission is asked *here*, during `preparing`, rather than at the end of the
    /// countdown: the user is still looking at the bar, a dialog is expected, and a refusal
    /// becomes `.cameraDenied` — which the bar already knows how to draw, with a button to
    /// the right pane of System Settings. Refusing at the end of the countdown would mean a
    /// dialog over a screen that is about to be recorded.
    ///
    /// A camera that cannot be prepared fails the whole take rather than quietly recording
    /// the screen alone. Somebody who turned the camera on is making a video with their
    /// face in it, and handing them one without it — twenty minutes later, on export — is
    /// worse than saying so now, while they can turn the camera off and go again.
    private func prepareWebcam(_ configuration: RecordingConfiguration,
                               package: RecordingPackage,
                               clock: RecordingClock) async throws {
        guard let webcamID = configuration.webcamID else { return }

        if !WebcamRecorder.isAuthorized {
            // `.denied` is not worth a second dialog the system will refuse to show; it
            // needs System Settings, which is what the error says.
            guard !WebcamRecorder.isDenied, await WebcamRecorder.requestAccess() else {
                throw RecordingError.cameraDenied
            }
        }
        guard let device = AVCaptureDevice(uniqueID: webcamID) else {
            throw RecordingError.deviceLost(webcamID)
        }

        let pixelSize = WebcamRecorder.pixelSize(of: device)
        // Capped at 30. Almost no camera delivers more, and a 60 fps encoder fed 30 real
        // frames has the writer's pacer duplicate every one of them — twice the bytes for
        // the same picture. The bubble is a small part of the frame; it does not need them.
        let frameRate = min(configuration.frameRate, 30)
        let writer = try SessionWriter(url: package.mediaFolder.appendingPathComponent("webcam.mov"),
                                       pixelSize: pixelSize,
                                       codec: configuration.codec.resolved,
                                       bitrate: configuration.quality.bitrate(forPixels: Int(pixelSize.width * pixelSize.height)),
                                       frameRate: frameRate,
                                       systemAudio: false,
                                       microphone: false,
                                       clock: clock,
                                       // The screen says when the recording began; this
                                       // file adopts that moment. See `SessionWriter.Origin`.
                                       origin: .sharedClock,
                                       queue: queue)
        webcamWriter = writer
        webcamPixelSize = pixelSize
        webcamFrameRate = frameRate
        webcam = try WebcamRecorder(device: device, writer: writer) { [weak self] error in
            Task { @MainActor in self?.interrupted(by: error) }
        }
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
        // Both writers, in one hop onto the queue. Pausing one and not the other would take
        // the held stretch out of the screen's file and leave it in the camera's, which is
        // the two drifting apart by however long the pause lasted.
        let webcamWriter = webcamWriter
        queue.async {
            writer.setPaused(true)
            webcamWriter?.setPaused(true)
        }
        cursor?.stop()
        focus?.stop()
        state = held
        Self.log.notice("Paused")
    }

    public func resume() {
        guard let released = state.released(at: .now), let writer else { return }
        let webcamWriter = webcamWriter
        queue.async {
            writer.setPaused(false)
            webcamWriter?.setPaused(false)
        }
        cursor?.start()
        focus?.start()
        state = released
        Self.log.notice("Resumed")
    }

    public var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    /// Whether a camera is open for the take that is running.
    ///
    /// Read off the apparatus rather than off any preference, and that distinction is the
    /// whole reason it exists: the bar draws an indicator from this, and a preference can
    /// say yes for a take that a host's request turned the camera off for. An indicator
    /// about a camera that is right most of the time is worse than none — it is the app
    /// claiming to be filming somebody when it is not, which teaches the user to stop
    /// believing it in the case that matters.
    public var isRecordingCamera: Bool { webcam != nil }

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
            // The camera's file is closed first, and its failure is not the take's failure.
            // The screen is the recording; a camera file that would not finish costs a
            // bubble, and throwing the screen away over it would be absurd. `hasWebcam`
            // then keeps the manifest honest about what is actually on disk.
            var hasWebcam = false
            if let webcamWriter {
                do {
                    _ = try await webcamWriter.finish()
                    hasWebcam = true
                } catch {
                    Self.log.error("The camera's file wouldn't finish; keeping the screen without it.")
                    webcamWriter.cancel()
                }
            }
            let duration = try await writer.finish()
            let manifest = manifest(for: configuration, package: package,
                                    duration: duration.seconds, webcam: hasWebcam)
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
        webcamWriter?.cancel()
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
        // Before the screen, and unconditionally. A camera session left running is a camera
        // light left on, so it is the first thing let go of on every path out of a take.
        webcam?.stop()
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
        webcam = nil
        webcamWriter = nil
        webcamPixelSize = nil
        webcamFrameRate = nil
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
                          duration: Double,
                          webcam hasWebcam: Bool = false) -> RecordingManifest {
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
        // Its own file, unlike the two audio tracks: everything that reads a recording asks
        // for the first video track of the file it is pointed at, so a second video track
        // inside `screen.mov` would make "the recording" mean whichever one AVFoundation
        // happened to list first. Named only when the file was actually finished — a
        // manifest that points at media which is not there reads as a corrupt recording.
        if hasWebcam {
            tracks.append(.init(kind: .webcam,
                                path: "media/webcam.mov",
                                pixelSize: webcamPixelSize,
                                frameRate: webcamFrameRate,
                                codec: configuration.codec.resolved.rawValue))
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
