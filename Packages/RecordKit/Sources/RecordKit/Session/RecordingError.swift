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
    case contentUnavailable(String)
    case targetDisappeared
    case lowDiskSpace(bytesAvailable: Int64)
    case deviceLost(String)
    case writerFailed(String)
    case alreadyRecording
    case notRecording
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Klik Studio doesn't have Screen Recording permission."
        case .microphoneDenied:
            "Klik Studio doesn't have Microphone permission."
        case .contentUnavailable(let reason):
            "Klik Studio couldn't see what's on screen (\(reason))."
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
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            "Turn on Klik Studio in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        case .microphoneDenied:
            "Turn on Klik Studio in System Settings › Privacy & Security › Microphone, then try again."
        case .lowDiskSpace:
            "The part that was recorded has been kept."
        default:
            nil
        }
    }
}
