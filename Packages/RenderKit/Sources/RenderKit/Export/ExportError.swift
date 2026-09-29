import Foundation

/// What can go wrong on the way to a file.
///
/// A typed error at the layer boundary, matching `RecordingError`: the UI switches over
/// these to say something useful, rather than showing whatever string AVFoundation
/// happened to produce.
public enum ExportError: Error, Equatable, Sendable {
    case noVideoTrack
    case unreadableSource(String)
    case destinationNotWritable(String)
    case writerFailed(String)
    case emptyTimeline
    case cancelled

    public var localizedDescription: String {
        switch self {
        case .noVideoTrack:
            "This recording has no picture in it."
        case .unreadableSource(let detail):
            "The recording couldn't be read. \(detail)"
        case .destinationNotWritable(let detail):
            "That file couldn't be created. \(detail)"
        case .writerFailed(let detail):
            "The export stopped. \(detail)"
        case .emptyTimeline:
            "There's nothing on the timeline to export."
        case .cancelled:
            "Export cancelled."
        }
    }
}

/// How far along an export is.
public struct ExportProgress: Sendable, Equatable {
    public var framesWritten: Int
    public var totalFrames: Int
    /// Seconds since the export started, for the estimate.
    public var elapsed: Double

    public init(framesWritten: Int, totalFrames: Int, elapsed: Double) {
        self.framesWritten = framesWritten
        self.totalFrames = totalFrames
        self.elapsed = elapsed
    }

    public var fraction: Double {
        guard totalFrames > 0 else { return 0 }
        return min(1, Double(framesWritten) / Double(totalFrames))
    }

    /// Seconds left, from the rate so far.
    ///
    /// `nil` until enough frames are done for the figure to mean anything — an estimate
    /// from the first two frames is a number that jumps from four hours to nine seconds
    /// while someone reads it.
    public var remaining: Double? {
        guard framesWritten > 24, elapsed > 0, totalFrames > framesWritten else { return nil }
        let rate = Double(framesWritten) / elapsed
        guard rate > 0 else { return nil }
        return Double(totalFrames - framesWritten) / rate
    }
}
