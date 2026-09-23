import Foundation

/// Watches the volume a recording is being written to.
///
/// ScreenCaptureKit stops without an error when the disk fills, and an `AVAssetWriter`
/// that runs out of room fails at `finishWriting` — after the take. Both read to a user
/// as "the app lost my recording". Knowing early means the session can stop cleanly and
/// say why, with the file it has so far intact.
public struct DiskSpaceMonitor: Sendable {
    /// Below this, stop: what is on disk is worth more than the rest of the take.
    public let stopBelow: Int64
    /// Below this, warn.
    public let warnBelow: Int64

    public init(stopBelow: Int64 = 250 * 1_000_000, warnBelow: Int64 = 1_000 * 1_000_000) {
        self.stopBelow = stopBelow
        self.warnBelow = warnBelow
    }

    public enum Verdict: Equatable, Sendable {
        case fine
        case low(bytesAvailable: Int64)
        case stop(bytesAvailable: Int64)
    }

    public func verdict(bytesAvailable: Int64) -> Verdict {
        if bytesAvailable < stopBelow { return .stop(bytesAvailable: bytesAvailable) }
        if bytesAvailable < warnBelow { return .low(bytesAvailable: bytesAvailable) }
        return .fine
    }

    /// What the volume holding `url` has left for something the user asked for.
    ///
    /// `volumeAvailableCapacityForImportantUsage` rather than the raw free space: it is
    /// what macOS will actually give up, purgeable caches included.
    public func availableBytes(for url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public func verdict(for url: URL) -> Verdict {
        guard let bytes = availableBytes(for: url) else { return .fine }
        return verdict(bytesAvailable: bytes)
    }
}
