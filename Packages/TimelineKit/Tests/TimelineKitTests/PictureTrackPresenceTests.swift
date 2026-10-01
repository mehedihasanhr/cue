import RecordKit
import Testing
@testable import TimelineKit

/// The stretches a window recording's window was behind another, read back.
struct PictureTrackPresenceTests {
    @Test func behindUntilInFrontAgainIsHidden() {
        let track = PictureTrack(presence: [PresenceSample(t: 0, front: true),
                                            PresenceSample(t: 4, front: false),
                                            PresenceSample(t: 6.5, front: true),
                                            PresenceSample(t: 10, front: false)])
        #expect(!track.isHidden(at: 3.9))
        #expect(track.isHidden(at: 4))
        #expect(track.isHidden(at: 6))
        #expect(!track.isHidden(at: 7))
        // Still behind when the take ended.
        #expect(track.isHidden(at: 12))
        // Hiding is not a crop: the picture's own track stays empty.
        #expect(track.isEmpty)
    }

    @Test func noPresenceHidesNothing() {
        let track = PictureTrack()
        #expect(track.hidden.isEmpty)
        #expect(!track.isHidden(at: 5))
    }

    /// Two "behind"s in a row are one stretch, from the first.
    @Test func repeatedBehindIsOneStretch() {
        let track = PictureTrack(presence: [PresenceSample(t: 2, front: false),
                                            PresenceSample(t: 3, front: false),
                                            PresenceSample(t: 5, front: true)])
        #expect(track.hidden == [2...5])
    }
}
