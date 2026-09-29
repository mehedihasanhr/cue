// `@preconcurrency`: `AVCaptureSession` is not marked `Sendable`, and starting one off the
// queue the encoder runs on is what Apple's own documentation says to do.
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

/// The camera, into its own writer.
///
/// Built to the same shape as `MicrophoneRecorder` — an `AVCaptureSession` whose output
/// delivers on the writer's queue — and for the same reason: a `CMSampleBuffer` goes
/// straight from AVFoundation into the encoder with no hop, no copy and nothing
/// non-`Sendable` crossing an isolation boundary.
///
/// **What is deliberately absent: any way to look at the camera before recording it.**
/// There is no preview, no "test your camera" affordance, and no session that exists for
/// any reason other than a take the user has asked for. An `AVCaptureSession` running
/// against a real device lights the camera's indicator, and a light that comes on because
/// somebody opened a settings pane is the app claiming to be recording when it is not.
/// So this object is constructed when a take is being prepared, `start()` is called when
/// that take's first frame is due, and `stop()` is called when the take ends — the same
/// lifecycle the microphone has, and no wider one.
public final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let writer: SessionWriter
    private let deviceName: String
    private let onLoss: @Sendable (RecordingError) -> Void

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "webcam")

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

        // BGRA, like the screen stream asks ScreenCaptureKit for, so both video tracks
        // reach the encoder in one pixel format and neither pays for a conversion.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // A frame the encoder is too busy for is thrown away rather than queued. The
        // alternative is an ever-growing backlog of faces from several seconds ago, which is
        // worse than a dropped frame: the writer's pacer fills the hole with the last one.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: writer.queue)
        session.addOutput(output)

        NotificationCenter.default.addObserver(self, selector: #selector(sessionFailed(_:)),
                                               name: .AVCaptureSessionRuntimeError, object: session)
    }

    /// Whether the user has already said yes. Asking is the caller's job, because only it
    /// knows whether now is a good moment for a dialog — and, for a camera, whether the
    /// user has just asked for one.
    public static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Whether the refusal is final. A `.notDetermined` camera can still be asked;
    /// `.denied` and `.restricted` can only be changed in System Settings, which is a
    /// different sentence to say to the user.
    public static var isDenied: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: true
        case .authorized, .notDetermined: false
        @unknown default: false
        }
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public static var defaultDevice: AVCaptureDevice? {
        AVCaptureDevice.default(for: .video)
    }

    /// Every camera the Mac can see, built-in and plugged in.
    ///
    /// Read rather than remembered, because the answer changes when somebody plugs in a
    /// webcam or closes their laptop lid — and because a list held from launch is a list
    /// that offers a device which is no longer there.
    public static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video,
                                         position: .unspecified).devices
    }

    /// The camera's picture size in pixels, for the writer and for the manifest.
    ///
    /// Read off the device's active format rather than guessed: a writer told the wrong
    /// size encodes a stretched face, and only in the file.
    public static func pixelSize(of device: AVCaptureDevice) -> CGSize {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        guard width > 1, height > 1 else { return CGSize(width: 1_280, height: 720) }
        // Both encoders reject an odd dimension, and they reject it at write time, which is
        // much later than here.
        return CGSize(width: width - width % 2, height: height - height % 2)
    }

    public func start() {
        // `startRunning` blocks while the camera warms up — a second or more on some
        // devices — and doing that on the queue the encoder runs on would drop screen
        // frames while the camera opens its shutter.
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    /// Stops the session and lets go of the device.
    ///
    /// Called from `RecordingSession.teardown()`, which runs on every path out of a take —
    /// stop, cancel, and an interruption. That matters more here than it does for the
    /// microphone: a camera session left running is a camera light left on.
    public func stop() {
        session.stopRunning()
        NotificationCenter.default.removeObserver(self)
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput buffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        writer.append(video: buffer)
    }

    @objc private func sessionFailed(_ notification: Notification) {
        Self.log.error("Camera session failed: \(self.deviceName, privacy: .public)")
        onLoss(.deviceLost(deviceName))
    }
}
