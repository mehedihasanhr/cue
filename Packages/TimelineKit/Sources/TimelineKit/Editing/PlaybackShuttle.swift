import Foundation

/// The J, K and L keys: which way to play, and how fast.
///
/// A rate is a signed number — forwards is positive, backwards negative, and 1 is the
/// speed the recording was made at. The keys change it in the way every editor's keys
/// do: the forward key plays forwards, and pressed again while already playing forwards
/// goes faster, up to a limit; the backward key is its mirror; the stop key stops. What
/// each press means is decided here rather than in the editor, so it can be checked
/// without a window and read as a table.
public enum PlaybackShuttle {
    public enum Key: Sendable, Equatable {
        case backward, stop, forward
    }

    /// As fast as the keys go. Beyond this the picture is a slide show, because every
    /// frame shown is a seek and the decoder cannot keep up with sixteen times real time.
    public static let fastest = 4.0

    /// Normal speed, which is also what the rate goes back to on stopping.
    public static let normal = 1.0

    /// The rate after `key`, given the rate playback is running at — `nil` when stopped.
    ///
    /// `nil` back means stop. Pressing a direction key while playing the other way does not
    /// slow down first; it turns round at normal speed, because the person has just said
    /// which way they want to go and a press that only slowed the wrong direction would
    /// look like nothing happened.
    public static func rate(after key: Key, running current: Double?) -> Double? {
        switch key {
        case .stop:
            return nil
        case .forward:
            guard let current, current > 0 else { return normal }
            return min(fastest, current * 2)
        case .backward:
            guard let current, current < 0 else { return -normal }
            return max(-fastest, current * 2)
        }
    }
}
