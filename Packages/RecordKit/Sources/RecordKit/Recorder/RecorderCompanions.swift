import Foundation

/// When the things beside the bar may open a device: the microphone meter and the camera
/// preview.
///
/// Written as rules over plain values because what they guard is a microphone or a camera
/// being opened, and "which state opens it" is the one thing here worth proving without
/// either.
public enum RecorderCompanions {
    /// Where the microphone meter reads its level from.
    public enum MeterSource: Equatable, Sendable {
        /// Nothing is listened to.
        case none
        /// The chosen microphone, opened by the meter itself.
        case device(String)
        /// The take's own microphone, which is already open.
        case take
    }

    /// - Parameters:
    ///   - deviceID: the microphone the user turned on and allowed, or `nil`.
    ///   - isBarVisible: whether the bar is on screen. Hidden, nothing is listened to.
    public static func meterSource(deviceID: String?,
                                   isBarVisible: Bool,
                                   state: RecordingSession.State) -> MeterSource {
        guard isBarVisible, let deviceID else { return .none }
        switch state {
        case .recording, .paused: return .take
        case .idle, .preparing, .countdown, .failed, .finished: return .device(deviceID)
        // The take's microphone is being let go of; a meter now would open it again.
        case .finishing: return .none
        }
    }

    /// Whether the camera preview is up.
    ///
    /// Before a take only, unless asked to stay: once Record is pressed, the countdown is
    /// for getting out of the way rather than for framing.
    public static func showsCameraPreview(isEnabled: Bool,
                                          keepsWhileRecording: Bool,
                                          hasCamera: Bool,
                                          isBarVisible: Bool,
                                          state: RecordingSession.State) -> Bool {
        guard isEnabled, hasCamera, isBarVisible else { return false }
        switch state {
        case .idle, .finished, .failed: return true
        case .preparing, .countdown, .recording, .paused: return keepsWhileRecording
        case .finishing: return false
        }
    }
}
