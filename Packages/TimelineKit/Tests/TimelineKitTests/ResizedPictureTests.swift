import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// What else is measured in the frame's points or fractions, once a window's picture has
/// moved: masks, the clicks that are heard, and the sensitive-text checks against the crop.
///
/// A 1000 × 500 frame whose window was resized at five seconds to half the size, into the
/// top-left corner — the content now drawn at half scale in the top-left quarter.
struct ResizedPictureTests {
    private let frame = CGSize(width: 1_000, height: 500)
    private let picture = PictureTrack(samples: [PictureSample(t: 5, rect: CGRect(x: 0, y: 0, width: 500, height: 250))])

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9
            && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    // MARK: - Masks

    /// Drawn before the resize over some content, a still mask is on the same content after
    /// it: moved into the corner and shrunk by half with it.
    @Test func aStillMaskFollowsThePictureThroughTheResize() {
        let drawn = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let stored = BlurRegion.stillRect(covering: drawn, source: 2, picture: picture, frame: frame)
        #expect(stored == drawn, "before the resize the picture is the whole frame")
        let mask = BlurRegion(start: time(0), duration: time(10), rect: stored)
        #expect(isClose(mask.recordingRect(at: time(2), source: 2, picture: picture, frame: frame), drawn))
        #expect(isClose(mask.recordingRect(at: time(6), source: 6, picture: picture, frame: frame),
                        CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)))
    }

    /// Drawn after the resize over the smaller content, it is stored as a fraction of the
    /// picture — and so covers the same content at full size before the resize.
    @Test func aMaskDrawnAfterTheResizeIsStoredAgainstThePicture() {
        let drawn = CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
        let stored = BlurRegion.stillRect(covering: drawn, source: 6, picture: picture, frame: frame)
        #expect(isClose(stored, CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)))
        let mask = BlurRegion(start: time(0), duration: time(10), rect: stored)
        // Moving it on the canvas goes through the same conversion.
        #expect(isClose(mask.shownRect(covering: drawn, source: 6, picture: picture, frame: frame), stored))
    }

    /// A following mask's path was measured off the recording's own frames, so it already
    /// moves with the content: it is not carried a second time. Nor is anything over an
    /// imported clip, or in a recording that was never resized.
    @Test func followingMasksImportedFootageAndOrdinaryTakesAreLeftAlone() {
        let rect = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let following = BlurRegion(start: time(0), duration: time(10), rect: rect,
                                   path: MaskPath(keys: [MaskPath.Key(time: 0, offset: .zero),
                                                         MaskPath.Key(time: 10, offset: .zero)]))
        #expect(following.follows)
        #expect(following.recordingRect(at: time(6), source: 6, picture: picture, frame: frame) == rect)
        let still = BlurRegion(start: time(0), duration: time(10), rect: rect)
        #expect(still.recordingRect(at: time(6), source: nil, picture: picture, frame: frame) == rect)
        #expect(still.recordingRect(at: time(6), source: 6, picture: PictureTrack(), frame: frame) == rect)
    }

    /// Stopping a following mask leaves a still one where it was — which, after the resize,
    /// means storing it as a fraction of the picture.
    @Test func stoppingFollowingStoresThePlaceAgainstThePicture() {
        var timeline = Timeline(sourceDuration: time(20))
        let id = UUID()
        let path = MaskPath(keys: [MaskPath.Key(time: 0, offset: .zero), MaskPath.Key(time: 10, offset: .zero)])
        timeline.blurs = [BlurRegion(id: id, start: time(0), duration: time(10),
                                     rect: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), path: path)]
        #expect(Commands.StopFollowing(id: id, at: time(6), picture: picture, frame: frame).apply(to: &timeline))
        let stopped = timeline.blurs[0]
        #expect(!stopped.follows)
        #expect(isClose(stopped.recordingRect(at: time(6), source: 6, picture: picture, frame: frame),
                        CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)), "still over the same place")
    }

    // MARK: - Clicks

    /// After the resize, a click in the black the smaller picture left is not drawn, so it
    /// is not heard; the same place before the resize was picture, and is.
    @Test func aClickInTheBlackAResizeLeftIsNotHeard() {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.cursor.clickSound = true
        let clicks = [CursorTrack.Click(t: 2, point: CGPoint(x: 600, y: 100), isSecondary: false),
                      CursorTrack.Click(t: 6, point: CGPoint(x: 600, y: 100), isSecondary: false),
                      CursorTrack.Click(t: 7, point: CGPoint(x: 100, y: 100), isSecondary: false)]
        #expect(timeline.visibleClicks(clicks, frame: frame, picture: picture).map(\.t) == [2, 7])
        #expect(timeline.visibleClicks(clicks, frame: frame).count == 3, "without the track, as before")
    }

    // MARK: - Sensitive text

    /// The crop is a crop of the picture as shown. After the resize the right half of the
    /// picture is the right half of the corner it shrank into — so text read there is in
    /// the crop, though it is in the left half of the frame.
    @Test func aSightingIsTestedAgainstTheCropOfThePictureAtItsMoment() {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.style.crop = CropRect(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let sighting = CGRect(x: 0.3, y: 0.1, width: 0.05, height: 0.05)
        let finding = SensitiveFinding(kind: .secret, text: "hunter2", start: 6, end: 8,
                                       sightings: [SensitiveSighting(time: 6, rect: sighting)], rect: sighting)
        #expect(finding.isShown(in: timeline, picture: picture, frame: frame))
        #expect(!finding.isShown(in: timeline), "measured against the whole frame, it looked cropped away")
    }

    /// A still mask over that text, stored against the picture, is counted as hiding it;
    /// and the masks a finding makes are stored against the picture, so they draw over it.
    @Test func aStillMaskHidesTextWhereThePictureMovedIt() {
        let timeline = Timeline(sourceDuration: time(20))
        let sighting = CGRect(x: 0.32, y: 0.12, width: 0.05, height: 0.05)
        let finding = SensitiveFinding(kind: .secret, text: "hunter2", start: 6, end: 8,
                                       sightings: [SensitiveSighting(time: 6, rect: sighting)], rect: sighting)
        let mask = BlurRegion(start: time(0), duration: time(10), rect: CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.2),
                              style: .cover)
        #expect(finding.isHidden(by: [mask], in: timeline, picture: picture, frame: frame))
        #expect(!finding.isHidden(by: [mask], in: timeline))

        let made = finding.masks(in: timeline, padding: 0, videoSize: CGSize(width: 2_000, height: 1_000),
                                 style: .cover, picture: picture, frame: frame)
        #expect(made.count == 1)
        #expect(made.first.map { isClose($0.recordingRect(at: time(6), source: 6, picture: picture, frame: frame),
                                         sighting) } == true)
    }
}
