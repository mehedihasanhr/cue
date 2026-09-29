import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Transitions at a cut: where they fall, how long they are allowed to be, and that adding
/// one moves nothing.
struct ClipTransitionTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func twoClips() -> Timeline {
        var timeline = Timeline(sourceDuration: time(20))
        ClipSequence.split(&timeline, at: time(10))
        return timeline
    }

    @Test func aTransitionIsCentredOnTheCut() throws {
        var timeline = twoClips()
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id, to: ClipTransition(.crossfade))

        #expect(timeline.transition(at: time(9.7)) == nil, "before it starts")
        let start = try #require(timeline.transition(at: time(9.8)))
        #expect(start.progress == 0)
        #expect(start.cut == time(10))
        #expect(start.outgoing == 0 && start.incoming == 1)
        let middle = try #require(timeline.transition(at: time(10)))
        #expect(middle.progress == 0.5)
        #expect(middle.isAfterCut)
        #expect(middle.dip == 1)
        #expect(timeline.transition(at: time(10.2)) == nil, "and over at the far end")
    }

    /// The whole point of centring it: nothing else has to move.
    @Test func addingATransitionChangesNoTimeAnywhere() {
        var timeline = twoClips()
        timeline.zooms = [ZoomRegion(start: time(12), duration: time(2))]
        let before = timeline
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id, to: ClipTransition(.dipToBlack))
        #expect(timeline.duration == before.duration)
        #expect(timeline.zooms == before.zooms)
        #expect(timeline.sourceTime(at: time(10.1)) == before.sourceTime(at: time(10.1)))
    }

    @Test func theFirstClipHasNothingToArriveFrom() {
        var timeline = twoClips()
        let before = timeline
        #expect(!ClipSequence.setTransition(&timeline, clipID: timeline.clips[0].id, to: ClipTransition(.crossfade)))
        #expect(timeline == before)
    }

    /// Held to the shorter clip, so each half is at most half of its clip and two
    /// transitions on one short clip never overlap.
    @Test func aTransitionIsHeldInsideBothClips() throws {
        var timeline = Timeline(sourceDuration: time(20))
        ClipSequence.split(&timeline, at: time(10))
        ClipSequence.split(&timeline, at: time(10.5))                        // a half-second clip
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id,
                                   to: ClipTransition(.crossfade, duration: time(2)))
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[2].id,
                                   to: ClipTransition(.crossfade, duration: time(2)))
        let into = try #require(timeline.transition(into: 1))
        #expect(into.duration == time(0.5))
        let out = try #require(timeline.transition(into: 2))
        #expect(out.duration == time(0.5))
        // The first ends at 10.25 and the second begins there.
        #expect(timeline.transition(at: time(10.24))?.incoming == 1)
        #expect(timeline.transition(at: time(10.25))?.incoming == 2)
    }

    @Test func theLengthIsHeldToSomethingSensible() {
        #expect(ClipTransition(.crossfade, duration: time(30)).duration == ClipTransition.maximumDuration)
        #expect(ClipTransition(.crossfade, duration: .zero).duration == ClipTransition.minimumDuration)
        #expect(ClipTransition(.crossfade).duration == time(0.4))
    }

    @Test func noTransitionsAnswersNothing() {
        let timeline = twoClips()
        #expect(timeline.transition(at: time(10)) == nil)
        #expect(timeline.transitions.isEmpty)
    }

    @Test func theListHasEveryCutWithOne() {
        var timeline = twoClips()
        ClipSequence.split(&timeline, at: time(15))
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[2].id, to: ClipTransition(.dipToBackground))
        #expect(timeline.transitions.map(\.cut) == [time(15)])
        #expect(timeline.transitions.map(\.style) == [.dipToBackground])
    }

    /// A split opens a new cut, and a new cut is a plain one; the half that keeps the
    /// clip's identity keeps its entrance.
    @Test func splittingKeepsTheEntranceOnTheFirstHalf() {
        var timeline = twoClips()
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id, to: ClipTransition(.crossfade))
        ClipSequence.split(&timeline, at: time(15))
        #expect(timeline.clips[1].transition?.style == .crossfade)
        #expect(timeline.clips[2].transition == nil)
    }

    @Test func theSoundsSignatureKnowsAboutTransitions() {
        var timeline = twoClips()
        let before = timeline.audioSignature
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id, to: ClipTransition(.crossfade))
        #expect(timeline.audioSignature != before)
    }

    @Test func theCommandsNameSaysWhatItDid() {
        let id = UUID()
        #expect(Commands.SetTransition(clipID: id, ClipTransition(.crossfade)).name == "Transition")
        #expect(Commands.SetTransition(clipID: id, nil).name == "Remove Transition")
    }

    // MARK: - Reading it back

    @Test func aTransitionRoundTrips() throws {
        var timeline = twoClips()
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id,
                                   to: ClipTransition(.dipToBackground, duration: time(0.8)))
        let back = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(back == timeline)
    }

    /// A style from a newer build makes that cut a plain one, and keeps the clip.
    @Test func anUnknownStyleIsAPlainCut() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sourceStart":{"value":0,"timescale":600},
         "sourceDuration":{"value":6000,"timescale":600},"speed":1,
         "transition":{"style":"spin","duration":{"value":240,"timescale":600}}}
        """
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(clip.transition == nil)
        #expect(clip.duration == time(10))
    }
}
