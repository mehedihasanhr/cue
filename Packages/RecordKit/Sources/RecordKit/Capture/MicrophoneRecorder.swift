import AVFoundation
import Foundation
import os

/// The microphone, into the writer.
///
/// `AVCaptureSession` rather than `AVAudioEngine`: capture hands over `CMSampleBuffer`s
/// on a queue of our choosing, which is the writer's, so microphone audio reaches the
/// encoder the same way screen audio does — no format conversion, no second clock, and
/// nothing non-`Sendable` crossing a boundary.
public final class MicrophoneRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let writer: SessionWriter
    private let deviceName: String
    private let onLoss: @Sendable (RecordingError) -> Void

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "microphone")

    public init(device: AVCaptureDevice,
                writer: SessionWriter,
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

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput buffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        writer.append(microphone: buffer)
    }

    @objc private func sessionFailed(_ notification: Notification) {
        Self.log.error("Microphone session failed: \(self.deviceName, privacy: .public)")
        onLoss(.deviceLost(deviceName))
    }
}
