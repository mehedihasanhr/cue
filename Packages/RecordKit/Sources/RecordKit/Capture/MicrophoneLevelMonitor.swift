@preconcurrency import AVFoundation
import Foundation
import os

/// Listens to a microphone without recording it, so the bar can show that it works.
///
/// Built only for a microphone somebody has already chosen and already allowed: nothing
/// here asks for permission, and `start` refuses a device the grant does not cover — a
/// meter is not the moment for a system dialog. It writes nothing and keeps nothing; the
/// buffers are thrown away as they arrive, and the only thing read is the level the
/// capture connection measures anyway.
public final class MicrophoneLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.stackrover.cue.studio.meter", qos: .utility)
    public let deviceID: String

    private static let log = Logger(subsystem: "com.stackrover.cue.studio", category: "meter")

    /// `nil` when the device is gone or has not been allowed.
    public init?(deviceID: String) {
        guard MicrophoneRecorder.isAuthorized,
              let device = AVCaptureDevice(uniqueID: deviceID),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        self.deviceID = deviceID
        super.init()
        guard session.canAddInput(input), session.canAddOutput(output) else { return nil }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
    }

    public func start() {
        let session = session
        // Off the main thread: `startRunning` blocks while the device wakes.
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    public func stop() {
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    /// How loud the microphone is right now, in decibels below full scale.
    public var power: Float? { Self.power(of: output) }

    /// The loudest channel of an output's connection, or `nil` before anything arrived.
    ///
    /// `AVCaptureAudioChannel` measures this for every connection whether anybody reads it
    /// or not, which is why a meter costs nothing beyond the session it reads from.
    static func power(of output: AVCaptureAudioDataOutput) -> Float? {
        let channels = output.connections.first?.audioChannels ?? []
        return channels.map(\.averagePowerLevel).max()
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput buffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {}
}
