import Foundation

/// Why a recording did not happen, or stopped happening.
///
/// One case per thing a user can do something about, plus one for everything else. The
/// distinctions are the point: "grant the permission", "pick another window" and "free
/// up disk" are three different actions, and a single "recording failed" would hide all
/// three.
public enum RecordingError: Error, LocalizedError, Equatable, Sendable {
    case permissionDenied
    case microphoneDenied
    /// The camera was asked for and refused. Its own case rather than a shared
    /// `.microphoneDenied`, for the reason the whole enum exists: microphone and camera are
    /// two separate lists in System Settings, and sending somebody to the wrong one sends
    /// them to a switch that is already on.
    case cameraDenied
    case contentUnavailable(String)
    case targetDisappeared
    case lowDiskSpace(bytesAvailable: Int64)
    case deviceLost(String)
    case writerFailed(String)
    case alreadyRecording
    case notRecording
    case cancelled
    /// The take started and could not be finished — the file stopped taking frames, or
    /// would not close. What reached the disk is kept, with its marker, for Recordings to
    /// recover. Not `.writerFailed`, which is a take that never started and has nothing to
    /// keep.
    case unfinished(String)
    /// An iPhone or iPad was opened and sent no picture. Almost always a locked device, or
    /// one that has not been told to trust this Mac — both of which are on the device, not
    /// the Mac, so it is its own case with its own sentence rather than a lost device.
    case deviceSilent(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Cue Studio doesn't have Screen Recording permission."
        case .microphoneDenied:
            "Cue Studio doesn't have Microphone permission."
        case .cameraDenied:
            "Cue Studio doesn't have Camera permission."
        case .contentUnavailable(let reason):
            "Cue Studio couldn't see what's on screen (\(reason))."
        case .targetDisappeared:
            "What was being recorded is gone."
        case .lowDiskSpace(let bytes):
            "There's only \(ByteCountFormatStyle(style: .file).format(bytes)) left on disk."
        case .deviceLost(let name):
            "\(name) stopped responding."
        case .writerFailed(let reason):
            "The recording couldn't be written (\(reason))."
        case .alreadyRecording:
            "A recording is already running."
        case .notRecording:
            "Nothing is recording."
        case .cancelled:
            "The recording was cancelled."
        case .unfinished(let reason):
            "The recording stopped before it could be saved (\(reason))."
        case .deviceSilent(let name):
            "\(name) didn\u{2019}t send a picture."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            "Turn on Cue Studio in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        case .microphoneDenied:
            "Turn on Cue Studio in System Settings › Privacy & Security › Microphone, then try again."
        case .cameraDenied:
            "Turn on Cue Studio in System Settings › Privacy & Security › Camera, or turn the camera off in the bar and record without it."
        case .lowDiskSpace:
            "The part that was recorded has been kept."
        case .unfinished:
            "What was recorded is kept. Open Recordings to recover it."
        case .deviceSilent:
            "Unlock it, tap Trust if it asks about this Mac, and try again."
        default:
            nil
        }
    }
}
