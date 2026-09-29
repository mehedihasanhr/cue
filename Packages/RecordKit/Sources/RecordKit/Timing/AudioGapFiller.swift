import CoreMedia
import Foundation

/// Works out how much silence a missing stretch of audio needs.
///
/// A device that is unplugged, a stream that stalls, a system that sleeps: audio stops
/// arriving and then resumes with a later timestamp. Appending the new buffer as if
/// nothing happened slides every following sample earlier than the picture it belongs
/// to, and the recording goes out of sync for good. Inserting exactly the missing
/// duration as silence keeps sound and picture on the same clock.
public struct AudioGapFiller: Sendable {
    /// Gaps shorter than this are normal buffer jitter, not a hole.
    public let tolerance: CMTime
    /// The longest silence to synthesise in one go.
    public let maximumGap: CMTime

    public init(tolerance: CMTime = CMTime(value: 1, timescale: 20),
                maximumGap: CMTime = CMTime(seconds: 30, preferredTimescale: 600)) {
        self.tolerance = tolerance
        self.maximumGap = maximumGap
    }

    /// How much silence belongs between the end of what has been written and the buffer
    /// that just arrived. `nil` when nothing is missing.
    ///
    /// A gap longer than `maximumGap` is clamped rather than refused: the recording is
    /// already odd, and a capped silence keeps the rest of it usable.
    public func silence(writtenThrough written: CMTime?, next: CMTime) -> CMTime? {
        guard let written, next > written else { return nil }
        let gap = next - written
        guard gap > tolerance else { return nil }
        return min(gap, maximumGap)
    }
}
