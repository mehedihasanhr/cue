import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// What may and may not send the editor off to rebuild the sound.
///
/// The cost of getting this wrong runs both ways: too eager and every drag of the corner
/// radius decodes the recording's audio again; too lazy and you cut the take but go on
/// hearing the uncut version.
struct AudioSignatureTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func timeline() -> Timeline { Timeline(sourceDuration: time(60)) }

    // MARK: - Things you cannot hear

    @Test func theLookOfTheFrameIsNotAudible() {
        let plain = timeline()
        var styled = plain
        styled.style.padding = 120
        styled.style.cornerRadius = 40
        styled.style.background = .color(ColorValue(r: 1, g: 0, b: 0))
        styled.camera.follow = 0.25
        styled.cursor.scale = 2.5
        #expect(styled.audioSignature == plain.audioSignature)
    }

    @Test func regionsThatDrawRatherThanSoundAreNotAudible() {
        let plain = timeline()
        var marked = plain
        marked.zooms = [ZoomRegion(start: time(2), duration: time(4))]
        marked.blurs = [BlurRegion(start: time(1), duration: time(2), rect: .init(x: 0, y: 0, width: 1, height: 1))]
        marked.captions = [CaptionCue(start: time(0), duration: time(1), text: "hello")]
        #expect(marked.audioSignature == plain.audioSignature)
    }

    // MARK: - Things you can

    @Test func aCutChangesTheSound() {
        var timeline = timeline()
        let before = timeline.audioSignature
        ClipSequence.split(&timeline, at: time(30))
        #expect(timeline.audioSignature != before)
    }

    @Test func aSpeedChangeChangesTheSound() {
        var timeline = timeline()
        let before = timeline.audioSignature
        timeline.clips[0].speed = 2
        #expect(timeline.audioSignature != before)
    }

    @Test func trimmingChangesTheSound() {
        var timeline = timeline()
        let before = timeline.audioSignature
        timeline.clips[0].sourceStart = time(5)
        #expect(timeline.audioSignature != before)
    }

    @Test func anAddedSoundChangesTheSound() {
        var timeline = timeline()
        let before = timeline.audioSignature
        timeline.audio = [AudioRegion(start: .zero, duration: time(10), path: "audio/music.m4a")]
        #expect(timeline.audioSignature != before)
    }

    @Test func aLevelChangeChangesTheSound() {
        var timeline = timeline()
        timeline.audio = [AudioRegion(start: .zero, duration: time(10), path: "audio/music.m4a")]
        let before = timeline.audioSignature
        timeline.audio[0].gain = 0.3
        #expect(timeline.audioSignature != before)
    }

    /// Two timelines cut the same way sound the same, whatever order the edits arrived
    /// in and whatever identities the clips ended up with.
    @Test func theSameCutsSoundTheSameRegardlessOfIdentity() {
        var one = timeline()
        ClipSequence.split(&one, at: time(20))
        var two = timeline()
        ClipSequence.split(&two, at: time(20))
        #expect(one.clips.map(\.id) != two.clips.map(\.id))
        #expect(one.audioSignature == two.audioSignature)
    }
}
