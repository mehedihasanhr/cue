// `@preconcurrency`: `AVCaptureSession` is not marked `Sendable`, and starting one off the
// queue the encoder runs on is what Apple's own documentation says to do.
@preconcurrency import AVFoundation
import Foundation
import os

/// One microphone, into a file of its own.
///
/// `AVCaptureSession` rather than `AVAudioEngine`: capture hands over `CMSampleBuffer`s
/// on a queue of our choosing, which is the writer's, so microphone audio reaches the
/// encoder the same way screen audio does — no format conversion, no second clock, and
/// nothing non-`Sendable` crossing a boundary.
///
/// One of these per microphone, each with its own `AudioTrackWriter`. They share the
/// recording's queue and its clock, so two microphones and the screen line up to the
/// sample; what they do not share is a file, which is what lets the editor set a level on
/// one voice without touching the other.
public final class MicrophoneRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let writer: AudioTrackWriter
    /// What the editor calls this microphone. Read here, while the device is in hand,
    /// because by the time a project is opened the device may be long unplugged.
    public let deviceName: String
    private let onLoss: @Sendable (RecordingError) -> Void

    private static let log = Logger(subsystem: "com.stackrover.cue.studio", category: "microphone")

    public init(device: AVCaptureDevice,
                writer: AudioTrackWriter,
                onLoss: @escaping @Sendable (RecordingError) -> Void) throws(RecordingError) {
        self.writer = writer
        self.onLoss = onLoss
        deviceName = device.localizedName
        super.init()

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw .deviceLost(device.localizedName)
        }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw .deviceLost(device.localizedName)
        }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: writer.queue)
        session.addOutput(output)

        NotificationCenter.default.addObserver(self, selector: #selector(sessionFailed(_:)),
                                               name: .AVCaptureSessionRuntimeError, object: session)
    }

    /// Whether the user has already said yes. Asking is the caller's job, because only
    /// it knows whether now is a good moment for a dialog.
    public static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static var defaultDevice: AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio)
    }

    /// Every microphone the Mac can currently see, in the order the system lists them.
    ///
    /// Here rather than in the app because the recorder is what has to resolve these
    /// `uniqueID`s again when a take starts, and a list built from a different query than
    /// the one that resolves it is a list with devices on it that cannot be recorded.
    public static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio,
                                         position: .unspecified).devices
    }

    public func start() {
        // `startRunning` blocks while the device warms up, which is long enough to drop
        // frames if it happens on the queue the encoder runs on.
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    public func stop() {
        session.stopRunning()
        NotificationCenter.default.removeObserver(self)
    }

    /// How loud this microphone is right now, in decibels below full scale — the loudest
    /// of its channels. Read off the take's own capture rather than a second session on
    /// the same device, so the bar's meter shows exactly what is being written.
    public var power: Float? { MicrophoneLevelMonitor.power(of: output) }

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput buffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        writer.append(buffer)
    }

    @objc private func sessionFailed(_ notification: Notification) {
        Self.log.error("Microphone session failed: \(self.deviceName, privacy: .public)")
        onLoss(.deviceLost(deviceName))
    }
}
