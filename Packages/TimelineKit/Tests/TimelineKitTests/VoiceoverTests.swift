import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Where narration lands, and what the edit does with the words that come after it ends.
///
/// The recorder cannot be tested — it needs a microphone and a person — but this can, and
/// this is the part that lies quietly: a region a fraction of a second out sounds fine
/// while you record it and wrong the moment you play it back.
struct VoiceoverTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func timeline() -> Timeline { Timeline(sourceDuration: time(60)) }

    // MARK: - Punching in

    @Test func aTakeStartsWhereItWasPunchedIn() throws {
        let placement = try #require(timeline().voiceoverPlacement(punchedInAt: time(12.5), recorded: time(4)))
        #expect(placement.start == time(12.5))
        #expect(placement.duration == time(4))
        #expect(!placement.wasTrimmed)
    }

    /// The whole point of the feature: the region begins at the playhead, not at zero.
    @Test func aTakeIsNotLaidAtTheStartOfTheEdit() throws {
        let placement = try #require(timeline().voiceoverPlacement(punchedInAt: time(30), recorded: time(5)))
        #expect(placement.start != .zero)
        #expect(placement.range == CMTimeRange(start: time(30), duration: time(5)))
    }

    @Test(arguments: [0.0, 1.0, 17.25, 59.0])
    func everyPunchInPointSurvivesTheRoundTrip(_ seconds: Double) throws {
        let placement = try #require(timeline().voiceoverPlacement(punchedInAt: time(seconds), recorded: time(0.5)))
        #expect(placement.start == time(seconds))
    }

    // MARK: - Talking past the end

    @Test func aTakeThatOutrunsTheEditIsCutOffAtIt() throws {
        let timeline = timeline()
        let placement = try #require(timeline.voiceoverPlacement(punchedInAt: time(55), recorded: time(20)))
        #expect(placement.end == timeline.duration)
        #expect(placement.duration == time(5))
        #expect(placement.wasTrimmed)
    }

    /// Overrunning must not make the video longer — a recording does not grow because
    /// somebody was slow to press Stop.
    @Test func overrunningDoesNotLengthenTheEdit() {
        var timeline = timeline()
        let before = timeline.duration
        guard let placement = timeline.voiceoverPlacement(punchedInAt: time(59), recorded: time(600)) else {
            Issue.record("There was a second of room; the take should have fitted.")
            return
        }
        timeline.audio.append(AudioRegion(start: placement.start,
                                          duration: placement.duration,
                                          path: "Audio/voice.m4a"))
        #expect(timeline.duration == before)
        #expect(placement.end <= before)
    }

    @Test func thereIsNowhereToPutATakePunchedInAtTheVeryEnd() {
        let timeline = timeline()
        #expect(timeline.voiceoverPlacement(punchedInAt: timeline.duration, recorded: time(4)) == nil)
        #expect(timeline.voiceoverPlacement(punchedInAt: time(59.99), recorded: time(4)) == nil)
    }

    @Test func aTakeWithNothingInItIsNotAPlacement() {
        #expect(timeline().voiceoverPlacement(punchedInAt: .zero, recorded: .zero) == nil)
    }

    /// A punch-in beyond the edit — a playhead left past the end by a shortened clip —
    /// is pulled back rather than producing a region hanging off the end.
    @Test func aPunchInPastTheEndIsPulledBackIntoTheEdit() {
        let timeline = timeline()
        let placement = timeline.voiceoverPlacement(punchedInAt: time(120), recorded: time(4))
        #expect(placement == nil)
        #expect(timeline.voiceoverPlacement(punchedInAt: time(-3), recorded: time(4))?.start == .zero)
    }

    // MARK: - The editor has to hear it

    /// A voiceover that did not change the signature would be laid on the lane, drawn,
    /// saved — and silent, because the player would go on playing the sound of the edit
    /// as it was before the take.
    @Test func aVoiceoverChangesWhatTheEditSoundsLike() throws {
        var timeline = timeline()
        let before = timeline.audioSignature
        let placement = try #require(timeline.voiceoverPlacement(punchedInAt: time(10), recorded: time(3)))
        timeline.audio.append(AudioRegion(start: placement.start,
                                          duration: placement.duration,
                                          path: "Audio/voice.m4a"))
        #expect(timeline.audioSignature != before)
    }

    /// Two takes are two regions. A re-take that reused the previous one's path or
    /// identity would sound identical to the editor and would quietly replace it.
    @Test func aRetakeIsAnotherRegionRatherThanAReplacement() throws {
        var timeline = timeline()
        let first = try #require(timeline.voiceoverPlacement(punchedInAt: time(10), recorded: time(3)))
        timeline.audio.append(AudioRegion(start: first.start, duration: first.duration, path: "Audio/one.m4a"))
        let afterFirst = timeline.audioSignature

        let second = try #require(timeline.voiceoverPlacement(punchedInAt: time(10), recorded: time(3)))
        timeline.audio.append(AudioRegion(start: second.start, duration: second.duration, path: "Audio/two.m4a"))
        #expect(timeline.audio.count == 2)
        #expect(timeline.audioSignature != afterFirst)
    }
}
