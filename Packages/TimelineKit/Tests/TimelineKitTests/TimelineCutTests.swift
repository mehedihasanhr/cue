import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

/// Cutting an edit down to a range, for exporting part of a video.
///
/// The promise under test: a moment of the excerpt is the same moment of the whole
/// video — same footage, same sound, same camera — with the clock started at zero.
struct TimelineCutTests {
    /// A minute of recording cut into three pieces, the middle one at double speed, with
    /// something on every lane.
    private func timeline() -> Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        ClipSequence.split(&timeline, at: time(20))
        ClipSequence.split(&timeline, at: time(40))
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(20), end: time(40)), speed: 2)
        // 0…20 plays source 0…20, 20…30 plays source 20…40 at 2×, 30…50 plays source 40…60.
        timeline.zooms = [ZoomRegion(start: time(5), duration: time(10), scale: 3, easing: .linear,
                                     transition: time(2), followsCursor: false),
                          ZoomRegion(start: time(28), duration: time(4), scale: 2, followsCursor: false)]
        timeline.blurs = [BlurRegion(start: time(2), duration: time(3), rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
                          BlurRegion(start: time(8), duration: time(30), rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))]
        timeline.annotations = [AnnotationItem(start: time(9), duration: time(4), kind: .rectangle,
                                               rect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2))]
        timeline.captions = [CaptionCue(start: time(1), duration: time(2), text: "before"),
                             CaptionCue(start: time(9), duration: time(3), text: "across the start"),
                             CaptionCue(start: time(15), duration: time(2), text: "inside"),
                             CaptionCue(start: time(24), duration: time(4), text: "across the end"),
                             CaptionCue(start: time(40), duration: time(2), text: "after")]
        timeline.audio = [AudioRegion(start: time(8), duration: time(10), path: "Audio/song.m4a",
                                      gain: 0.5, sourceStart: time(3))]
        timeline.cursorRegions = [CursorRegion(start: time(12), duration: time(6))]
        return timeline
    }

    private let range = CMTimeRange(start: time(10), end: time(25))

    // MARK: - Footage

    @Test func theClipsAreCutAtBothEndsAndStartAtZero() {
        let cut = timeline().cut(to: range)
        #expect(cut.duration == time(15))
        #expect(cut.clips.count == 2, "one piece from each clip the range touched")
        #expect(cut.clips[0].sourceStart == time(10))
        #expect(cut.clips[0].sourceDuration == time(10))
        #expect(cut.clips[1].sourceStart == time(20), "the second clip from its own in-point")
        #expect(cut.clips[1].speed == 2)
        #expect(cut.clips[1].sourceDuration == time(10), "five seconds of timeline at double speed")
    }

    /// The footage under every moment of the excerpt is the footage under the same
    /// moment of the whole.
    @Test func everyMomentShowsTheSameFootage() {
        let whole = timeline()
        let cut = whole.cut(to: range)
        for step in 0...150 {
            let at = time(Double(step) / 10)
            #expect(cut.sourceTime(at: at) == whole.sourceTime(at: at + range.start), "at \(at.seconds)")
        }
    }

    @Test func aCutCanLandInsideAClipHoweverCloseToItsEdge() {
        let cut = timeline().cut(to: CMTimeRange(start: time(19.95), end: time(20.02)))
        #expect(cut.clips.count == 2)
        #expect(abs(cut.duration.seconds - 0.07) < 0.002)
    }

    @Test func anEmptyRangeGivesTheEditBack() {
        let whole = timeline()
        #expect(whole.cut(to: CMTimeRange(start: time(10), duration: .zero)) == whole)
        #expect(whole.cut(to: CMTimeRange(start: time(70), duration: time(5))) == whole, "and so does one past the end")
    }

    // MARK: - Regions

    @Test func regionsOutsideTheRangeAreDropped() {
        let cut = timeline().cut(to: range)
        #expect(cut.captions.map(\.text) == ["across the start", "inside", "across the end"])
        #expect(cut.blurs.count == 1)
        #expect(cut.cursorRegions.count == 1)
    }

    @Test func regionsMoveOntoTheExcerptsClock() {
        let cut = timeline().cut(to: range)
        #expect(cut.captions[1].start == time(5), "was at 15")
        #expect(cut.cursorRegions[0].start == time(2), "was at 12")
        #expect(cut.annotations[0].start == time(-1), "began a second before the excerpt, and still does")
    }

    /// Straddlers keep their timing so what was on screen at the first frame is on
    /// screen at the first frame, rather than fading in again.
    @Test func aRegionStraddlingAnEdgeKeepsItsTiming() {
        let cut = timeline().cut(to: range)
        let across = cut.captions[0]
        #expect(across.start == time(-1))
        #expect(across.end == time(2))
        #expect(across.contains(.zero), "on screen from the first frame")
        let late = cut.captions[2]
        #expect(late.start == time(14))
        #expect(late.end == time(18), "runs past the last frame, as it did")
    }

    // MARK: - Zooms

    /// The one the feature is really about: cut the excerpt to begin in the middle of a
    /// zoom's ramp in, and the camera at the excerpt's first frame is exactly where the
    /// whole video had it, and carries on ramping from there.
    @Test func aZoomCutInTheMiddleOfItsRampStillRampsFromWhereItWas() {
        let whole = timeline()
        // The zoom ramps in over 5…7; cut in at 6, halfway up.
        let cut = whole.cut(to: CMTimeRange(start: time(6), end: time(20)))
        let zoom = cut.zooms[0]
        #expect(zoom.start == time(-1), "kept whole, a second before zero")
        #expect(abs(zoom.scale(at: .zero) - 2) < 1e-9, "halfway up a linear ramp from 1 to 3")
        for step in 0...40 {
            let at = time(Double(step) / 20)
            #expect(abs(zoom.scale(at: at) - whole.zooms[0].scale(at: at + time(6))) < 1e-9, "at \(at.seconds)")
        }
    }

    @Test func aZoomCutInItsRampOutStillRampsOutFromWhereItWas() {
        let whole = timeline()
        // The zoom ramps out over 13…15; cut out at 14.
        let cut = whole.cut(to: CMTimeRange(start: time(2), end: time(14)))
        let zoom = cut.zooms[0]
        #expect(zoom.end == time(13), "ends a second after the excerpt does")
        #expect(abs(zoom.scale(at: cut.duration - time(0.01)) - whole.zooms[0].scale(at: time(13.99))) < 1e-9)
    }

    /// Every zoom stays on the lane, because the camera between two zooms depends on both
    /// — see `Timeline.cut(to:)`.
    @Test func zoomsAreKeptWholeAndMoved() {
        let cut = timeline().cut(to: range)
        #expect(cut.zooms.count == 2)
        #expect(cut.zooms[0].start == time(-5))
        #expect(cut.zooms[1].start == time(18))
        #expect(cut.zooms[1].duration == time(4))
    }

    // MARK: - Sound

    /// An imported sound goes on playing the same second of its file at the same moment
    /// of the picture — which is what "in step" means.
    @Test func anImportedSoundIsCutInStep() {
        let cut = timeline().cut(to: range)
        let sound = cut.audio[0]
        #expect(sound.start == .zero, "began two seconds before the excerpt")
        #expect(sound.duration == time(8), "and ran until 18, so eight seconds of it survive")
        #expect(sound.sourceStart == time(5), "three seconds in, plus the two that were cut off")
        #expect(sound.gain == 0.5)
    }

    @Test func anImportedSoundOutsideTheRangeIsDropped() {
        #expect(timeline().cut(to: CMTimeRange(start: time(20), end: time(30))).audio.isEmpty)
    }

    @Test func aDetachedSoundLaneIsCutInStep() {
        var whole = timeline()
        ClipSequence.detachSound(&whole)
        // Slide the second run half a second later, an edit the excerpt has to keep.
        var runs = whole.detachedSound!
        runs[1].start = runs[1].start + time(0.5)
        whole.detachedSound = runs

        let cut = whole.cut(to: range)
        let kept = cut.detachedSound!
        #expect(kept.count == 2)
        #expect(kept[0].start == .zero)
        #expect(kept[0].duration == time(10))
        #expect(kept[0].sourceStart == time(10), "ten seconds into the recording, where the excerpt begins")
        #expect(kept[1].start == time(10.5), "the slide survives")
        #expect(kept[1].sourceStart == time(20))
        #expect(kept[1].speed == 2)
        #expect(kept[1].duration == time(4.5))
    }

    @Test func anAttachedSoundLaneFollowsTheCutClips() {
        let cut = timeline().cut(to: range)
        #expect(cut.detachedSound == nil)
        #expect(cut.soundRunsFollowingClips.map(\.sourceStart) == [time(10), time(20)])
    }

    /// The whole thing, cut to the whole thing, is the whole thing.
    @Test func cuttingToTheWholeEditChangesNothing() {
        let whole = timeline()
        let cut = whole.cut(to: CMTimeRange(start: .zero, duration: whole.duration))
        #expect(cut.duration == whole.duration)
        #expect(cut.clips.map(\.sourceStart) == whole.clips.map(\.sourceStart))
        #expect(cut.zooms == whole.zooms)
        #expect(cut.captions == whole.captions)
        #expect(cut.audio == whole.audio)
    }
}
