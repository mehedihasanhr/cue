// `@preconcurrency`: `AVCaptureSession` and `AVCaptureDevice` are not marked `Sendable`,
// and starting a session off the queue the encoder runs on is what Apple's own
// documentation says to do.
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

/// A connected iPhone or iPad, into the take's picture and its own sound.
///
/// The device's screen is the recording here, the way the Mac's screen is for every other
/// target: its frames go into `screen.mov` through the same `SessionWriter`, which starts
/// the recording's clock with the first of them, and its sound goes into a file of its own
/// through an `AudioTrackWriter`, as the Mac's system audio does. Picture and sound come
/// from the one capture device — it is *muxed* — through two outputs of one session.
///
/// Built to the shape of `WebcamRecorder`, with one difference that matters: the session is
/// opened *before* the countdown, not at the end of it. A device's picture size is not
/// known until it sends a frame — its capture format describes the stream, not the screen
/// — and the file cannot be made until its size is. So `open()` starts the session while
/// the bar is still counting down, waits for the first frame, and reports its size; frames
/// are only written once `start()` says the take has begun. That also means the device is
/// awake by the time the countdown reaches zero, which is the whole point of a countdown.
///
/// A picture that changes shape during the take — the device turned over — is fitted into
/// the file by `DeviceFrameFit`, which explains the choice.
public final class DeviceRecorder: NSObject,
                                   AVCaptureVideoDataOutputSampleBufferDelegate,
                                   AVCaptureAudioDataOutputSampleBufferDelegate,
                                   @unchecked Sendable {
    private let session = AVCaptureSession()
    private let video = AVCaptureVideoDataOutput()
    private let sound = AVCaptureAudioDataOutput()
    private let device: AVCaptureDevice
    /// The queue every frame and sample arrives on, and the only one that touches the
    /// writers — the recording's own queue, so nothing hops between capture and encoder.
    public let queue: DispatchQueue
    /// What the device calls itself, read while it is in hand.
    public let deviceName: String
    public let deviceID: String
    private let onLoss: @Sendable (RecordingError) -> Void

    // Confined to `queue`.
    private var writer: SessionWriter?
    private var audio: AudioTrackWriter?
    private var fitter: DeviceFrameFitter?
    private var isWriting = false
    /// The last picture size seen, so a turn is logged once rather than per frame.
    private var lastSize: CGSize?
    private var turns = 0
    /// The most recent frame, held through the countdown — see `start()`.
    private var latest: CMSampleBuffer?

    /// The first frame's size, for `open()`. Set once, from the capture queue.
    private let firstSize = OSAllocatedUnfairLock<FirstSize>(initialState: FirstSize())
    private struct FirstSize {
        var size: CGSize?
        var isSettled = false
        var waiting: CheckedContinuation<CGSize?, Never>?
    }

    private var observers: [any NSObjectProtocol] = []

    private static let log = Logger(subsystem: "com.stackrover.cue.studio", category: "device")

    public init(device: AVCaptureDevice,
                queue: DispatchQueue,
                onLoss: @escaping @Sendable (RecordingError) -> Void) throws(RecordingError) {
        self.device = device
        self.queue = queue
        self.onLoss = onLoss
        deviceName = device.localizedName
        deviceID = device.uniqueID
        super.init()

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw .deviceLost(device.localizedName)
        }
        guard session.canAddInput(input), session.canAddOutput(video) else {
            throw .deviceLost(device.localizedName)
        }
        session.beginConfiguration()
        session.addInput(input)
        // BGRA, as the screen stream and the camera deliver it, so the encoder sees one
        // pixel format whatever is being recorded — and so the fitter can clear a buffer
        // to black by writing words rather than planes.
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // Late frames thrown away rather than queued, for the camera's reason: the pacer
        // repeats the last picture into a hole, and a backlog is only ever stale.
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(video)
        // The device's own sound. A device that has none — or a session that will not take
        // a second output — records its picture silently rather than not at all.
        if session.canAddOutput(sound) {
            sound.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(sound)
        }
        session.commitConfiguration()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session,
                                            queue: nil) { [weak self] _ in self?.lost() })
        // Unplugged, or locked hard enough that it drops off the bus.
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device,
                                            queue: nil) { [weak self] _ in self?.lost() })
    }

    /// Whether the device has any sound to give, for the session to decide whether to open
    /// a file for it.
    public var hasSound: Bool { session.outputs.contains(sound) }

    /// Starts the session and waits for the device's first frame, which says how big the
    /// file has to be. `nil` when no frame came in time — a locked device sends nothing.
    ///
    /// The session is left running either way; `stop()` is what closes it.
    public func open(timeout: Duration = .seconds(4)) async -> CGSize? {
        let session = session
        // `startRunning` blocks while the device wakes, which must not be on the capture
        // queue or the main actor.
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        let size: CGSize? = await withCheckedContinuation { continuation in
            let settled = firstSize.withLock { state -> CGSize?? in
                if state.isSettled { return .some(state.size) }
                state.waiting = continuation
                return nil
            }
            if let settled { continuation.resume(returning: settled); return }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.settle(nil)
            }
        }
        return size
    }

    /// Where the frames and the sound go once the take begins. Called once, after `open()`
    /// and before `start()`.
    public func attach(writer: SessionWriter, audio: AudioTrackWriter?, canvas: CGSize) {
        queue.sync {
            self.writer = writer
            self.audio = audio
            fitter = DeviceFrameFitter(canvas: canvas)
        }
    }

    /// The countdown is over: from here on, everything is written.
    ///
    /// A device sends a frame when its screen changes, not on a schedule, so a phone
    /// sitting on its home screen at the end of the countdown might send nothing for
    /// seconds — and the first frame written is what starts the recording's clock, so
    /// every sound and the camera would wait with it. The picture it is showing is the one
    /// it sent last, so that frame is written now, stamped now: the take begins at "0",
    /// with what the device is actually showing.
    public func start() {
        queue.async {
            self.isWriting = true
            guard let latest = self.latest, let writer = self.writer,
                  let now = try? CMSampleBuffer(copying: latest, withNewTiming: [
                      CMSampleTimingInfo(duration: latest.duration, presentationTimeStamp: RecordingClock.now,
                                         decodeTimeStamp: .invalid),
                  ]),
                  let fitted = self.fitter?.fit(now) else { return }
            writer.append(video: fitted)
        }
    }

    /// Stops the session and lets go of the device, on every path out of a take.
    public func stop() {
        // Read on the queue, where it is written.
        let turns = queue.sync {
            isWriting = false
            latest = nil
            return self.turns
        }
        session.stopRunning()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        settle(nil)
        if turns > 0 {
            Self.log.notice("\(self.deviceName, privacy: .public) changed shape \(turns) times during the take")
        }
    }

    // MARK: - Capture

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput buffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        if output === sound {
            if isWriting { audio?.append(buffer) }
            return
        }
        guard let image = buffer.imageBuffer else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        if lastSize == nil { settle(size) }
        if let lastSize, lastSize != size {
            turns += 1
            Self.log.notice("\(self.deviceName, privacy: .public) now sends \(Int(size.width))×\(Int(size.height))")
        }
        lastSize = size
        guard isWriting else {
            latest = buffer
            return
        }
        latest = nil
        guard let writer, let fitter, let fitted = fitter.fit(buffer) else { return }
        writer.append(video: fitted)
    }

    /// Once: the first frame's size, or `nil` for a timeout or a stop that came first.
    private func settle(_ size: CGSize?) {
        let waiting = firstSize.withLock { state -> CheckedContinuation<CGSize?, Never>? in
            guard !state.isSettled else { return nil }
            state.isSettled = true
            state.size = size
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(returning: size)
    }

    private func lost() {
        Self.log.error("Lost the device: \(self.deviceName, privacy: .public)")
        onLoss(.deviceLost(deviceName))
    }
}
