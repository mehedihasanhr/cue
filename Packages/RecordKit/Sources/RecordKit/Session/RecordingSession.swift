import AppKit
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
    /// The chosen apps' sound, when the take records only some apps — `nil` for a take that
    /// hears everything, or nothing. See `SystemAudioRoute`.
    private var appAudio: AppAudioRecorder?
    /// One per microphone this take was asked for, in the order they were asked for.
    private var microphones: [MicrophoneRecorder] = []
    /// Every sound this take is writing, each into its own file.
    ///
    /// The screen's own sound is one of these too, rather than a special case beside them:
    /// it is captured differently but it is edited identically, and every part of this
    /// class that touches sound — pausing it, finishing it, naming it in the manifest —
    /// wants to say the same thing to all of them.
    private var audioLanes: [AudioLane] = []
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
    /// The iPhone or iPad, for a take of one — see `DeviceRecorder`. `nil` for every take of
    /// the Mac's own screen, which is when `screen` is the one that is set instead.
    private var device: DeviceRecorder?
    /// What the manifest will say about that device.
    private var recordedDevice: RecordedDevice?
    private var cursor: CursorTracker?
    private var cursorArtwork: CursorArtworkWriter?
    /// The keyboard, when this take asked for it. `nil` is the state in which no key
    /// monitor is ever installed — the same bargain `webcam` makes with the camera.
    private var keys: KeyTracker?
    /// How the keyboard is reached: the real grant and monitor, or a test's stand-in.
    private let keyEnvironment: KeyTracker.Environment
    private var focus: FocusTracker?
    private var cursorWriter: JSONLWriter?
    private var inputWriter: JSONLWriter?
    private var focusWriter: JSONLWriter?
    /// Where a window's picture sat in its frame — see `PictureTracker`. `nil` for a
    /// display or an area, whose picture fills the frame by construction.
    private var pictureWriter: JSONLWriter?
    private var diskTimer: Timer?
    private var startedAt: Date?
    private var pixelSize: CGSize = .zero
    private var displayScale: Double = 2

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "session")

    /// One audio source being written, and what the manifest will say about it.
    private struct AudioLane {
        let kind: RecordingManifest.Track.Kind
        /// Relative to the package, because that is what the manifest carries.
        let path: String
        let name: String?
        let deviceID: String?
        let writer: AudioTrackWriter
    }

    /// - Parameter keys: how the keyboard is watched. The default is the real Mac; a test
    ///   hands in one that neither asks macOS for a grant nor installs a monitor.
    public init(keys: KeyTracker.Environment = .system) {
        keyEnvironment = keys
    }

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

        // A device has been running since `prepare`, so it only has to be told to write.
        // Before the screen would have started: it is the recording's first frame, and so
        // its clock, exactly as the screen's is for every other take.
        device?.start()
        do {
            try await screen?.start()
        } catch {
            // `start()` throws `RecordingError` and nothing else, so there is one arm here
            // rather than the two this used to have: the second was unreachable, and an
            // unreachable arm is a place a future reader looks for behaviour that is not
            // there.
            fail(error)
            return
        }
        // After the screen, whose first frame starts the clock every sound is timed from.
        // A failure here costs the take its chosen apps' sound and not the take: the
        // screen is already recording, and the lane simply ends up empty and unlisted.
        do {
            try await appAudio?.start()
        } catch {
            Self.log.error("Couldn't listen to the chosen apps: \(String(describing: error), privacy: .public)")
            appAudio = nil
        }
        watchAppLaunches()
        for microphone in microphones { microphone.start() }
        // After the screen, deliberately. The camera's writer takes its time zero from the
        // clock the screen's first frame starts, so a camera that opened first would simply
        // drop frames until the screen caught up — starting it here wastes none.
        webcam?.start()
        cursor?.start()
        keys?.start()
        focus?.start()
        watchDisk()
        watchDesktopIcons(configuration)

        startedAt = .now
        state = .recording(startedAt: .now)
        Self.log.notice("Recording started into \(self.package?.url.lastPathComponent ?? "?", privacy: .public)")
    }

    /// Everything that can fail, before the countdown gives the user a reason to expect
    /// it to work.
    private func prepare(_ configuration: RecordingConfiguration) async throws {
        // A device is not on this Mac's screen, so none of what follows — ScreenCaptureKit,
        // its grant, the pointer, the Mac's own sound — has anything to do with it.
        if let deviceID = configuration.target.deviceID {
            try await prepareDevice(deviceID, configuration: configuration)
            return
        }
        let shareable = try await content.content()
        let filter = try content.filter(for: configuration.target, in: shareable,
                                        hidingDesktopIcons: configuration.hidesDesktopIcons)
        let package = try RecordingPackage.create(named: configuration.name, in: configuration.destination)
        self.package = package

        if case .stop(let bytes) = disk.verdict(for: package.url) {
            package.discard()
            throw RecordingError.lowDiskSpace(bytesAvailable: bytes)
        }

        clock = RecordingClock()
        // Resolved now rather than when the request was made: a microphone unplugged in
        // between has to fail here, where the user is still watching a countdown.
        let microphoneDevices = try Self.microphones(for: configuration)
        // No audio at all in `screen.mov` any more. Each source is its own file beside it,
        // for the reason `AudioTrackWriter` gives: tracks inside one file cannot be told
        // apart afterwards with any certainty, and telling them apart is the whole feature.
        var lanes: [AudioLane] = []
        var systemAudioWriter: AudioTrackWriter?
        // Everything, some apps, or nothing — decided against what is running now, because
        // an app can only be listened to if it exists when the filter is made.
        let route = SystemAudioRoute.plan(systemAudio: configuration.systemAudio,
                                          chosen: configuration.systemAudioApps,
                                          running: shareable.applications.map(\.bundleIdentifier),
                                          ownBundleIDs: content.excludedBundleIDs)
        if route == .nothingRunning {
            Self.log.notice("None of the apps chosen for system audio is running; listening for one to launch")
        }
        if route.recordsAudio || route.listensForLaunches {
            let lane = try audioLane(kind: .systemAudio,
                                     file: "system-audio.m4a",
                                     name: "System Audio",
                                     deviceID: nil,
                                     package: package)
            lanes.append(lane)
            if route.listensForLaunches {
                // With no filter when nothing chosen is running yet: it waits for a launch.
                var filter: SCContentFilter?
                if case .applications(let bundleIDs) = route {
                    filter = try content.audioFilter(including: bundleIDs, near: configuration.target, in: shareable)
                }
                appAudio = AppAudioRecorder(filter: filter,
                                            configuration: RecordingConfiguration.audioOnlyStreamConfiguration(),
                                            writer: lane.writer)
            } else {
                systemAudioWriter = lane.writer
            }
        }

        try await makeScreen(filter: filter, configuration: configuration, package: package, audio: systemAudioWriter)

        lanes += try microphoneLanes(for: microphoneDevices, package: package)
        audioLanes = lanes

        try await prepareWebcam(configuration, package: package, clock: clock)
        startTelemetry(for: configuration, shareable: shareable, package: package)
        try markInProgress(configuration, package: package)
    }

    /// Resolves the microphones a take asked for. Resolved when the take is prepared rather
    /// than when the request was made: a microphone unplugged in between has to fail here,
    /// where the user is still watching a countdown.
    private static func microphones(for configuration: RecordingConfiguration) throws(RecordingError) -> [AVCaptureDevice] {
        try configuration.microphoneIDs.map { id throws(RecordingError) -> AVCaptureDevice in
            guard let device = AVCaptureDevice(uniqueID: id) else { throw RecordingError.deviceLost(id) }
            return device
        }
    }

    /// A file and a recorder for each microphone, in the order they were chosen.
    private func microphoneLanes(for devices: [AVCaptureDevice], package: RecordingPackage) throws(RecordingError) -> [AudioLane] {
        var lanes: [AudioLane] = []
        for (index, device) in devices.enumerated() {
            let lane = try audioLane(kind: .microphone,
                                     file: "microphone-\(index + 1).m4a",
                                     name: device.localizedName,
                                     deviceID: device.uniqueID,
                                     package: package)
            lanes.append(lane)
            microphones.append(try MicrophoneRecorder(device: device, writer: lane.writer) { [weak self] error in
                Task { @MainActor in self?.interrupted(by: error) }
            })
        }
        return lanes
    }

    // MARK: - A connected iPhone or iPad

    /// Everything a take of a connected device needs, before the countdown.
    ///
    /// The device's screen takes the place the Mac's screen has in every other take: its
    /// frames are `screen.mov`, and its first frame starts the clock. Its sound is a lane of
    /// its own, `device-audio.m4a`, written as the Mac's system audio would be and listed
    /// under the same kind — it *is* that device's system audio, and an editor that knows
    /// how to mix system audio needs to learn nothing to mix it. The Mac's own sound is not
    /// recorded: the take is of the device, and a notification chime from the Mac under a
    /// phone demo is never what was wanted. Microphones, the camera and markers work
    /// exactly as they do for the screen.
    ///
    /// No pointer, clicks, keys or focus are recorded — there is no pointer on a phone, and
    /// the Mac's would be of another screen entirely. The manifest says so by leaving those
    /// sidecars out and naming the device instead (`RecordingManifest.device`).
    ///
    /// Opening a device needs the camera grant — it is a capture device like any camera —
    /// and not the Screen Recording one. A refusal is `.cameraDenied`, which the bar
    /// already knows how to explain.
    private func prepareDevice(_ deviceID: String, configuration: RecordingConfiguration) async throws {
        if !WebcamRecorder.isAuthorized {
            guard !WebcamRecorder.isDenied, await WebcamRecorder.requestAccess() else {
                throw RecordingError.cameraDenied
            }
        }
        DeviceScreens.allow()
        guard let captureDevice = AVCaptureDevice(uniqueID: deviceID) else {
            throw RecordingError.deviceLost("The iPhone or iPad")
        }
        let microphoneDevices = try Self.microphones(for: configuration)

        let recorder = try DeviceRecorder(device: captureDevice, queue: queue) { [weak self] error in
            Task { @MainActor in self?.interrupted(by: error) }
        }
        // Kept before anything can fail, so that `fail` — through `reset` — closes it: from
        // here on the device is open, and a device left open is a camera light left on.
        device = recorder
        guard let first = await recorder.open() else {
            throw RecordingError.deviceSilent(recorder.deviceName)
        }

        let package = try RecordingPackage.create(named: configuration.name, in: configuration.destination)
        self.package = package
        if case .stop(let bytes) = disk.verdict(for: package.url) {
            package.discard()
            throw RecordingError.lowDiskSpace(bytesAvailable: bytes)
        }

        clock = RecordingClock()
        let canvas = DeviceFrameFit.canvas(for: first)
        let family = RecordedDevice.Family.guess(name: recorder.deviceName, pixelSize: first)
        recordedDevice = RecordedDevice(name: recorder.deviceName, family: family, deviceID: recorder.deviceID)
        pixelSize = canvas
        displayScale = family.displayScale
        pointerLatency = 0
        // No faster than a device's screen refreshes, which for every current one is 60 or
        // 120 — and the encoder gains nothing from being asked for frames that never come.
        let frameRate = min(configuration.frameRate, 60)
        let writer = try SessionWriter(url: package.mediaFolder.appendingPathComponent("screen.mov"),
                                       pixelSize: canvas,
                                       codec: configuration.codec.resolved,
                                       bitrate: configuration.quality.bitrate(forPixels: Int(canvas.width * canvas.height), frameRate: frameRate),
                                       frameRate: frameRate,
                                       systemAudio: false,
                                       microphone: false,
                                       clock: clock,
                                       queue: queue)
        self.writer = writer
        writer.onFailure = { [weak self] error in
            Task { @MainActor in self?.writerFailed(error) }
        }
        Self.log.notice("\(recorder.deviceName, privacy: .public) (\(family.rawValue, privacy: .public)) sends \(Int(first.width))×\(Int(first.height)); recording at \(Int(canvas.width))×\(Int(canvas.height))")

        var lanes: [AudioLane] = []
        if recorder.hasSound {
            lanes.append(try audioLane(kind: .systemAudio,
                                       file: "device-audio.m4a",
                                       name: recorder.deviceName,
                                       deviceID: recorder.deviceID,
                                       package: package))
        }
        recorder.attach(writer: writer, audio: lanes.first?.writer, canvas: canvas)
        lanes += try microphoneLanes(for: microphoneDevices, package: package)
        audioLanes = lanes

        try await prepareWebcam(configuration, package: package, clock: clock)
        startMarkers(package: package)
        try markInProgress(configuration, package: package)
    }

    /// The screen's file and the stream that fills it.
    ///
    /// A window is measured first, from a frame of it: what it reports can be less than
    /// what is captured, and a file sized from the report records the difference as a
    /// black band down one side. See `WindowPicture`.
    private func makeScreen(filter: SCContentFilter,
                            configuration: RecordingConfiguration,
                            package: RecordingPackage,
                            audio systemAudioWriter: AudioTrackWriter?) async throws(RecordingError) {
        var streamConfiguration = configuration.streamConfiguration(for: filter)
        if case .window = configuration.target,
           let measured = await WindowPicture.size(of: filter, configuration: streamConfiguration),
           abs(measured.width - filter.contentRect.width) > 1 || abs(measured.height - filter.contentRect.height) > 1 {
            Self.log.notice("Window's picture is \(measured.debugDescription, privacy: .public), not \(filter.contentRect.size.debugDescription, privacy: .public): sized to the picture")
            streamConfiguration = configuration.streamConfiguration(for: filter, pictureSize: measured)
        }
        pixelSize = CGSize(width: streamConfiguration.width, height: streamConfiguration.height)
        displayScale = Double(filter.pointPixelScale)
        let writer = try SessionWriter(url: package.mediaFolder.appendingPathComponent("screen.mov"),
                                       pixelSize: pixelSize,
                                       codec: configuration.codec.resolved,
                                       bitrate: configuration.quality.bitrate(forPixels: Int(pixelSize.width * pixelSize.height), frameRate: configuration.frameRate),
                                       frameRate: configuration.frameRate,
                                       systemAudio: false,
                                       microphone: false,
                                       clock: clock,
                                       queue: queue)
        self.writer = writer
        writer.onFailure = { [weak self] error in
            Task { @MainActor in self?.writerFailed(error) }
        }
        screen = ScreenRecorder(filter: filter,
                                configuration: streamConfiguration,
                                writer: writer,
                                audio: systemAudioWriter) { [weak self] error in
            Task { @MainActor in self?.interrupted(by: error) }
        }
    }

    /// A file for one sound, and the manifest entry that will point at it.
    private func audioLane(kind: RecordingManifest.Track.Kind,
                           file: String,
                           name: String?,
                           deviceID: String?,
                           package: RecordingPackage) throws(RecordingError) -> AudioLane {
        let url = package.mediaFolder.appendingPathComponent(file)
        return AudioLane(kind: kind,
                         path: "media/\(file)",
                         name: name,
                         deviceID: deviceID,
                         // Every sound in the package takes its time zero from the clock the
                         // screen's first frame starts, which is what keeps two microphones
                         // and the screen on one timeline.
                         writer: try AudioTrackWriter(url: url, clock: clock, queue: queue))
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
                                       bitrate: configuration.quality.bitrate(forPixels: Int(pixelSize.width * pixelSize.height), frameRate: frameRate),
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
                                shareable: SCShareableContent,
                                package: RecordingPackage) {
        let cursorWriter = JSONLWriter(url: package.telemetryFolder.appendingPathComponent("cursor.jsonl"), queue: queue)
        // One file for the mouse and the keyboard: they interleave in time, and reading
        // them back in order is what the editor wants. Opened for either.
        let inputWriter = configuration.capturesClicks || configuration.capturesKeystrokes
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
        startMarkers(package: package)
        self.cursorWriter = cursorWriter
        self.inputWriter = inputWriter
        self.focusWriter = focusWriter

        // Where the recorded area starts on screen, so a pointer position becomes a
        // position inside the frame. Asked of the target rather than of the filter — see
        // `ShareableContentStore.origin(of:in:)` for what the filter answers and why it is
        // the wrong number.
        //
        // A window is followed while it is recorded: the picture does not move when
        // somebody drags the window, but the pointer's global position does, so an origin
        // fixed at the start would drift by exactly the length of the drag.
        var followedWindow: CGWindowID?
        if case .window(let id) = configuration.target { followedWindow = id }
        let mapper = CursorMapper(origin: content.origin(of: configuration.target, in: shareable),
                                  following: followedWindow,
                                  outputScale: CGFloat(displayScale))
        // A window's frames say where it is and how much it was scaled to fit; a display's
        // and an area's never move or scale, and their origin is already exact.
        if followedWindow != nil { screen?.cursorMapper = mapper }
        // And, from the same frames, where in the file the window's picture landed. The
        // file's size is settled now and cannot follow the window if it is resized, so the
        // part it no longer covers is black; this is what lets the editor crop that away.
        // Only for a window: a display and an area fill their frame by construction.
        if followedWindow != nil, let screen {
            let pictureWriter = JSONLWriter(url: package.telemetryFolder.appendingPathComponent("picture.jsonl"),
                                            queue: queue)
            queue.sync { try? pictureWriter.open() }
            self.pictureWriter = pictureWriter
            let scale = max(displayScale, 0.01)
            screen.pictureTracker = PictureTracker(writer: pictureWriter,
                                                   clock: clock,
                                                   frameSize: CGSize(width: pixelSize.width / scale,
                                                                     height: pixelSize.height / scale),
                                                   outputScale: CGFloat(scale))
        }
        // Only when the pointer is being recorded as data. A take that burns the system
        // cursor into the video already has the real artwork in the pixels, and saving it
        // twice would be saving it for nobody.
        let artwork = configuration.capturesCursorArtwork && !configuration.capturesCursorInVideo
            ? CursorArtworkWriter(folder: package.telemetryFolder.appendingPathComponent("cursors",
                                                                                         isDirectory: true),
                                  relativeFolder: "telemetry/cursors")
            : nil
        cursorArtwork = artwork
        // Which display the picture is of, for how long that display takes to show the
        // pointer. A window is wherever its corner is.
        let display = configuration.target.displayID
            ?? Self.display(containing: content.origin(of: configuration.target, in: shareable))
        pointerLatency = PointerLatency.seconds(for: display)
        cursor = CursorTracker(cursorWriter: cursorWriter,
                               // The file may be open for the keyboard alone, in which
                               // case the mouse must not write into it.
                               inputWriter: configuration.capturesClicks ? inputWriter : nil,
                               queue: queue,
                               clock: clock,
                               mapper: mapper,
                               sampleRate: configuration.cursorSampleRate,
                               latency: pointerLatency,
                               artwork: artwork)
        // Only when asked for. The tracker checks the grant itself and records nothing
        // without it; the manifest says which of the two happened.
        if configuration.capturesKeystrokes, let inputWriter {
            keys = KeyTracker(writer: inputWriter,
                              queue: queue,
                              clock: clock,
                              latency: pointerLatency,
                              environment: keyEnvironment)
        }
        if let focusWriter {
            focus = FocusTracker(writer: focusWriter,
                                 queue: queue,
                                 clock: clock,
                                 mapper: mapper,
                                 tracksFields: Self.tracksTextFields(for: configuration))
        }
    }

    /// The markers sidecar, which every take has whatever it is a recording of.
    ///
    /// Always opened: a marker can be dropped in any take, and a log nobody wrote to is
    /// deleted when it closes, so the manifest only names one that has markers in it.
    private func startMarkers(package: RecordingPackage) {
        let markerWriter = JSONLWriter(url: package.url.appendingPathComponent(MarkerLog.path), queue: queue)
        queue.sync { try? markerWriter.open() }
        self.markerWriter = markerWriter
        markerLog = MarkerLog(writer: markerWriter, queue: queue, clock: clock)
    }

    /// Whether a take's focus tracker watches text fields: when focus is recorded and
    /// fields were asked for, whatever the keyboard switch says. See
    /// `RecordingConfiguration.capturesFieldFocus`.
    nonisolated static func tracksTextFields(for configuration: RecordingConfiguration) -> Bool {
        configuration.capturesFocus && configuration.capturesFieldFocus
    }

    /// How far every pointer sample in this take was moved to meet the picture.
    private var pointerLatency: Double = 0

    /// The display a point on the desk is on, in the space the pointer is read in.
    private static func display(containing point: CGPoint) -> CGDirectDisplayID? {
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return nil }
        return display
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
        let audioWriters = audioLanes.map(\.writer)
        // The clock first, and once: it is what every file and every sample takes the
        // length of the hold from, so none of them can disagree about it.
        clock.hold()
        queue.async {
            writer.setPaused(true)
            webcamWriter?.setPaused(true)
            for audio in audioWriters { audio.setPaused(true) }
        }
        cursor?.stop()
        keys?.stop()
        focus?.stop()
        state = held
        Self.log.notice("Paused")
    }

    public func resume() {
        guard let released = state.released(at: .now), let writer else { return }
        let webcamWriter = webcamWriter
        let audioWriters = audioLanes.map(\.writer)
        clock.release()
        queue.async {
            writer.setPaused(false)
            webcamWriter?.setPaused(false)
            for audio in audioWriters { audio.setPaused(false) }
        }
        cursor?.start()
        keys?.start()
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

    /// The package this take is being written into, while there is one — so the library
    /// can leave the take being recorded out of its interrupted ones.
    public var packageURL: URL? { package?.url }

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
                    // Not deleted: a file that would not close still plays up to its last
                    // fragment, and a camera that stopped short beats no camera.
                    hasWebcam = await TakeRecovery.isPlayable(webcamWriter.videoURL, kind: .webcam)
                    Self.log.error("The camera's file wouldn't finish; \(hasWebcam ? "kept as it was" : "left out", privacy: .public).")
                }
            }
            // Each sound's own file, closed before the picture's. A sound file that will
            // not finish costs that one lane and nothing else — the same bargain the camera
            // gets — so a failure here is logged and the take goes on.
            for lane in audioLanes {
                do {
                    guard try await lane.writer.finish() else { continue }
                    recordedAudio.append(.init(kind: lane.kind,
                                               path: lane.path,
                                               name: lane.name,
                                               deviceID: lane.deviceID))
                } catch {
                    // Kept for the reason the camera's is.
                    guard await TakeRecovery.isPlayable(lane.writer.url, kind: lane.kind) else {
                        Self.log.error("\(lane.path, privacy: .public) wouldn't finish; keeping the take without it.")
                        continue
                    }
                    recordedAudio.append(.init(kind: lane.kind, path: lane.path, name: lane.name, deviceID: lane.deviceID))
                }
            }

            let duration = try await writer.finish()
            let manifest = manifest(for: configuration, package: package,
                                    duration: duration.seconds, webcam: hasWebcam)
            try package.write(manifest)
            package.removeMarker()
            state = .finished(package.url)
            Self.log.notice("Finished \(package.url.lastPathComponent, privacy: .public) (\(duration.seconds, format: .fixed(precision: 1))s)")
            reset()
            return .success(package.url)
        } catch {
            // The take happened; it is the closing that failed. The package stays, marker
            // and all, for Recordings to recover — it used to be deleted here, which on a
            // full disk was every second of the take.
            let reason = if case .writerFailed(let reason)? = error as? RecordingError { reason } else { error.localizedDescription }
            let failure = RecordingError.unfinished(reason)
            fail(failure, keepingPackage: true)
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
        for lane in audioLanes { lane.writer.cancel() }
        // The cancels above run on the capture queue. Waiting for it to drain means no
        // writer is left holding a file inside the package when it is deleted, so nothing
        // can put a folder back afterwards — a restart must not leave the old take behind.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
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
        Self.log.error("Interrupted: \(error.localizedDescription, privacy: .public)")
        Task {
            // The same predicate as the bar's Stop button, for the same reason: a take
            // interrupted while it was paused is still a take with seconds in it, and
            // matching `.recording` alone here threw those away — the opposite of what the
            // comment above promises.
            if state.isTaking {
                // A take that could not even be closed says so itself, and that is the
                // more useful thing to show: where to find what was kept.
                if case .failure(.unfinished) = await stop() { return }
            } else {
                await cancel()
            }
            state = .failed(error)
        }
    }

    private func teardown() async {
        diskTimer?.invalidate()
        diskTimer = nil
        desktopIcons?.stop()
        desktopIcons = nil
        cursor?.stop()
        keys?.stop()
        focus?.stop()
        for microphone in microphones { microphone.stop() }
        // Before the screen, and unconditionally. A camera session left running is a camera
        // light left on, so it is the first thing let go of on every path out of a take.
        webcam?.stop()
        // The same bargain for a device: it is a capture device like the camera, and one
        // left open keeps its indicator lit and its screen streaming to nobody.
        device?.stop()
        if let appLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appLaunchObserver)
            self.appLaunchObserver = nil
        }
        await appAudio?.stop()
        await screen?.stop()
        // The result comes back out of the closure rather than being assigned inside
        // it: `queue.sync` runs its body on the capture queue, and this object is on the
        // main actor.
        // Written at the end rather than as each shape appears: it is an index of what was
        // collected, and what was collected is not known until collecting stops.
        cursorArtworkPath = cursorArtwork?.writeIndex(
            to: package?.telemetryFolder.appendingPathComponent("cursors.json")
                ?? URL(fileURLWithPath: "/dev/null"),
            relativePath: "telemetry/cursors.json")
        focusTrackWritten = queue.sync { [focusWriter, cursorWriter, inputWriter] in
            _ = cursorWriter?.close()
            _ = inputWriter?.close()
            return focusWriter?.close() ?? false
        }
        markersWritten = queue.sync { [markerWriter] in markerWriter?.close() ?? false }
        // Empty — and so deleted — for a window that was never resized, which is most.
        pictureTrackWritten = queue.sync { [pictureWriter] in pictureWriter?.close() ?? false }
    }

    /// The audio files that ended up with sound in them, as the manifest will name them.
    ///
    /// Filled in by `stop()` when the files are closed rather than in `prepare` when they
    /// are opened, for the same reason `focusTrackWritten` exists: a microphone that was
    /// asked for and delivered nothing — muted in hardware, claimed by another app, a
    /// headset that never woke — must not be named in the manifest, or the editor shows a
    /// lane for a sound that is not there.
    private var recordedAudio: [RecordingManifest.Track] = []

    /// Where the index of the real pointer artwork went, or `nil` when none was kept.
    private var cursorArtworkPath: String?

    /// Whether the focus track ended up with anything in it. An empty sidecar is
    /// deleted on close, so the manifest must not point at it.
    private var focusTrackWritten = false

    /// Whether the picture ever left the frame it was sized for, so that the sidecar saying
    /// where it went has anything in it. See `focusTrackWritten`.
    private var pictureTrackWritten = false

    private func reset() {
        takeSync?.stop()
        takeSync = nil
        writer = nil
        screen = nil
        appAudio = nil
        microphones = []
        audioLanes = []
        recordedAudio = []
        webcam = nil
        webcamWriter = nil
        webcamPixelSize = nil
        webcamFrameRate = nil
        // Stopped here as well as in `teardown`, because a device is opened in `prepare` —
        // before the countdown — and a take that fails before it starts is reset without
        // ever being torn down. Stopping twice is harmless; not stopping is a lit light.
        device?.stop()
        device = nil
        recordedDevice = nil
        cursor = nil
        cursorArtwork = nil
        cursorArtworkPath = nil
        keys = nil
        focus = nil
        // Let go of rather than left for the next take to overwrite: a take of a device opens
        // none of them, and one left over from the take before would have its old file
        // named in the new manifest.
        cursorWriter = nil
        inputWriter = nil
        focusWriter = nil
        focusTrackWritten = false
        pictureWriter = nil
        pictureTrackWritten = false
        markerWriter = nil
        markerLog = nil
        markersWritten = false
        markerCount = 0
        package = nil
        configuration = nil
        startedAt = nil
    }

    private func fail(_ error: RecordingError, keepingPackage: Bool = false) {
        Self.log.error("Failed: \(error.localizedDescription, privacy: .public)")
        if !keepingPackage { package?.discard() }
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
        // Each sound in its own file, named only if something was actually written to it.
        // Built from what the writers reported rather than from the configuration, so the
        // manifest describes the recording that happened rather than the one that was asked
        // for.
        tracks += recordedAudio
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

        var manifest = RecordingManifest(name: configuration.name,
                                 createdAt: startedAt ?? .now,
                                 duration: duration,
                                 displayScale: displayScale,
                                 sourceRect: sourceRect,
                                 tracks: tracks,
                                 // Named for the sidecars that were opened, which for a
                                 // device take is none of the pointer's: a manifest that
                                 // names a pointer track there was never going to be reads
                                 // as a take whose pointer file went missing.
                                 telemetry: .init(cursor: cursorWriter != nil ? "telemetry/cursor.jsonl" : nil,
                                                  input: inputWriter != nil ? "telemetry/input.jsonl" : nil,
                                                  focus: focusTrackWritten ? "telemetry/focus.jsonl" : nil,
                                                  cursorArtwork: cursorArtworkPath,
                                                  pointerLatency: pointerLatency,
                                                  // What actually happened, read off the
                                                  // tracker: asked for and watched, asked
                                                  // for and refused, or not asked for.
                                                  keys: keys?.capture,
                                                  markers: markersWritten ? MarkerLog.path : nil,
                                                  picture: pictureTrackWritten ? "telemetry/picture.jsonl" : nil))
        manifest.device = recordedDevice
        return manifest
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

    // MARK: - Surviving a crash

    /// Flushes this take's files to the disk while it records. See `TakeSync`.
    private var takeSync: TakeSync?

    /// Says, inside the package, that this take is being recorded and what it will be.
    ///
    /// Before the countdown, so there is never a moment with frames on disk and no marker
    /// beside them. The manifest it carries is the one `stop()` would write, with every
    /// sound it was asked for rather than the ones that turned out to have samples —
    /// recovery checks each file for itself.
    private func markInProgress(_ configuration: RecordingConfiguration, package: RecordingPackage) throws {
        var draft = manifest(for: configuration, package: package, duration: 0, webcam: webcamWriter != nil)
        draft.tracks.insert(contentsOf: audioLanes.map {
            RecordingManifest.Track(kind: $0.kind, path: $0.path, name: $0.name, deviceID: $0.deviceID)
        }, at: 1)
        if focusWriter != nil { draft.telemetry.focus = "telemetry/focus.jsonl" }
        if markerWriter != nil { draft.telemetry.markers = MarkerLog.path }
        if pictureWriter != nil { draft.telemetry.picture = "telemetry/picture.jsonl" }
        do {
            try package.writeMarker(TakeMarker(manifest: draft))
        } catch {
            // A package that will not take a small file will not take a video either.
            throw RecordingError.writerFailed(error.localizedDescription)
        }

        let sync = TakeSync(folders: [package.mediaFolder, package.telemetryFolder])
        sync.start()
        takeSync = sync
    }

    /// The screen's file stopped taking frames. A full disk is said as one, because it is
    /// the one the user can do something about.
    private func writerFailed(_ error: any Error) {
        guard state.isTaking, let package else { return }
        if case .stop(let bytes) = disk.verdict(for: package.url) {
            interrupted(by: .lowDiskSpace(bytesAvailable: bytes))
        } else {
            interrupted(by: .unfinished(error.localizedDescription))
        }
    }

    // MARK: - Markers

    /// The markers sidecar and what writes into it. See `MarkerLog`.
    private var markerWriter: JSONLWriter?
    private var markerLog: MarkerLog?
    /// Whether any marker reached the file, so the manifest names it only then.
    private var markersWritten = false

    /// How many markers this take has, for the bar to count.
    public private(set) var markerCount = 0

    /// Drops a marker at this moment of the take — on the recording's clock, so a marker
    /// dropped while paused lands where the pause began. `nil` when there is no take, or
    /// the last marker was a moment ago.
    @discardableResult
    public func addMarker() -> MarkerSample? {
        guard state.isTaking, let sample = markerLog?.add() else { return nil }
        markerCount += 1
        Self.log.notice("Marker at \(sample.t, format: .fixed(precision: 2))s")
        return sample
    }

    // MARK: - Desktop icons

    /// Rebuilds the filter when a Finder window comes or goes, while the desktop's icons
    /// are being left out. See `CaptureExclusion` for why that needs doing at all.
    private var desktopIcons: DesktopIconsWatcher?

    private func watchDesktopIcons(_ configuration: RecordingConfiguration) {
        guard configuration.hidesDesktopIcons, configuration.target.displayID != nil else { return }
        desktopIcons = DesktopIconsWatcher { [weak self] in await self?.refreshDesktopFilter() }
    }

    // MARK: - Apps launched during a take

    /// The observer for app launches, while a take that hears only some apps is running.
    private var appLaunchObserver: NSObjectProtocol?

    /// Listens for the chosen apps being opened during the take.
    ///
    /// ScreenCaptureKit hears the apps a filter names, and a filter can only name apps that
    /// are running when it is made — so an app opened after the take started was never
    /// heard. A launch of a chosen app rebuilds the audio stream's filter from what is
    /// running now (`SystemAudioRoute.launchChangesFilter`), which also catches an app
    /// quit and reopened: the filter held the old process.
    private func watchAppLaunches() {
        // Only a take with an app audio stream, which is only made when the route listens
        // for launches.
        guard appAudio != nil, appLaunchObserver == nil else { return }
        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let configuration = self.configuration,
                      SystemAudioRoute.launchChangesFilter(launched: bundleID,
                                                           chosen: configuration.systemAudioApps,
                                                           ownBundleIDs: self.content.excludedBundleIDs)
                else { return }
                Task { await self.relistenToChosenApps(after: bundleID) }
            }
        }
    }

    /// Rebuilds the audio stream's filter once the launched app shows up in
    /// ScreenCaptureKit's list, which lags the launch notification by a moment. Asked a
    /// few times, a second apart; an app that never shows up is logged and left out.
    private func relistenToChosenApps(after bundleID: String?) async {
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            guard state.isTaking, appAudio != nil, let configuration else { return }
            switch await chosenAppsFilter(for: configuration, waitingFor: bundleID) {
            case .notYet:
                continue
            case .none:
                return
            case .some(let filter, let bundleIDs):
                await appAudio?.listen(to: filter)
                Self.log.notice("Now hearing \(bundleIDs.joined(separator: ", "), privacy: .public)")
                return
            }
        }
        Self.log.notice("\(bundleID ?? "?", privacy: .public) launched but never became capturable")
    }

    private enum ChosenAppsFilter {
        case notYet
        case none
        case some(SCContentFilter, [String])
    }

    /// The filter that hears the chosen apps running now, once `bundleID` is among them.
    nonisolated private func chosenAppsFilter(for configuration: RecordingConfiguration,
                                              waitingFor bundleID: String?) async -> sending ChosenAppsFilter {
        guard let shareable = try? await content.content() else { return .notYet }
        let running = shareable.applications.map(\.bundleIdentifier)
        if let bundleID, !running.contains(bundleID) { return .notYet }
        let route = SystemAudioRoute.plan(systemAudio: configuration.systemAudio,
                                          chosen: configuration.systemAudioApps,
                                          running: running, ownBundleIDs: content.excludedBundleIDs)
        guard case .applications(let bundleIDs) = route,
              let filter = try? content.audioFilter(including: bundleIDs, near: configuration.target, in: shareable)
        else { return .none }
        return .some(filter, bundleIDs)
    }

    private func refreshDesktopFilter() async {
        guard state.isTaking, let target = configuration?.target, let screen,
              let shareable = try? await content.content(),
              let filter = try? content.filter(for: target, in: shareable, hidingDesktopIcons: true)
        else { return }
        await screen.update(filter)
    }

    // MARK: - Microphone level

    /// How loud the first microphone of the take is right now, in decibels, for the bar's
    /// meter. Read off the take's own capture; `nil` without a microphone.
    public var microphonePower: Float? { microphones.first?.power }
}
