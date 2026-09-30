import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

@Suite("Bug hunt 2 (2026-09-30)")
struct BugHunt2Tests {
    /// A window shrunk to its left half at 2 s. The renderer crops the black band away and
    /// scales the half up, so a click out in the band is never drawn — and must not be heard.
    @Test("A click on the black a resized window left is not heard, as it is not drawn")
    func clickSoundsFollowThePictureTrack() {
        let frame = CGSize(width: 1_000, height: 500)
        let picture = PictureTrack(samples: [PictureSample(t: 2, rect: CGRect(x: 0, y: 0, width: 500, height: 250))])
        let timeline = Timeline(sourceDuration: t(10))
        let clicks = [
            // Before the resize: the whole frame is picture.
            CursorTrack.Click(t: 1, point: CGPoint(x: 700, y: 100), isSecondary: false),
            // After it: on the picture, and out on the black.
            CursorTrack.Click(t: 3, point: CGPoint(x: 250, y: 125), isSecondary: false),
            CursorTrack.Click(t: 4, point: CGPoint(x: 700, y: 100), isSecondary: false),
        ]
        let heard = timeline.visibleClicks(clicks, frame: frame, picture: picture)
        #expect(heard.map(\.t) == [1, 3])
        // With no track, nothing changes.
        #expect(timeline.visibleClicks(clicks, frame: frame).count == 3)
    }
}
