import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// What happens to a suggested zoom somebody has framed by hand.
///
/// Auto-zoom's contract is that a later run replaces the previous run's output, which is
/// right until the moment the user drags one of those suggestions to where they actually
/// wanted it. Before `isEdited` existed, pressing the button again threw that work away
/// with nothing said — the single most valuable edit anybody makes on the second pass, and
/// the one the feature quietly undid.
struct ZoomCustomisationTests {
    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    private func suggested(at start: Double, source: ZoomRegion.Source = .click) -> ZoomRegion {
        ZoomRegion(start: seconds(start), duration: seconds(2), source: source)
    }

    @Test func afreshSuggestionIsTheRunsToReplace() {
        #expect(ZoomLane.isSuggestion(suggested(at: 1)))
    }

    @Test func aSuggestionSomebodyFramedIsTheirs() {
        var zoom = suggested(at: 1)
        zoom.isEdited = true
        #expect(!ZoomLane.isSuggestion(zoom))
    }

    /// The whole point, end to end: run, frame one of them, run again, and the framed one
    /// is still there with the framing it was given.
    @Test func regeneratingKeepsAZoomThatWasFramedByHand() {
        var framed = suggested(at: 1)
        framed.scale = 4.5
        framed.center = CGPoint(x: 0.2, y: 0.8)
        framed.followsCursor = false
        framed.isEdited = true

        let lane = [framed, suggested(at: 5)]
        let rerun = [suggested(at: 1), suggested(at: 5), suggested(at: 9)]
        let after = ZoomLane.reconciled(rerun, with: lane, duration: seconds(20))

        let kept = after.first { $0.id == framed.id }
        #expect(kept != nil, "the framed zoom survived the run")
        #expect(kept?.scale == 4.5)
        #expect(kept?.center == CGPoint(x: 0.2, y: 0.8))
        // And the run's own suggestion for that stretch was dropped rather than stacked on
        // top of it, which is what `reconciled` does for every zoom that is the user's.
        #expect(after.filter { $0.start == seconds(1) }.count == 1)
        #expect(after.count == 3, "the untouched one was replaced and the new one added")
    }

    /// Tuning is not framing. A zoom somebody dragged the Scale slider on but never aimed
    /// is still the run's to replace — the mark is set by direct manipulation, because that
    /// is the edit that carries a judgement about *where* the shot goes.
    @Test func tuningASliderDoesNotClaimASuggestion() {
        var tuned = suggested(at: 1)
        tuned.scale = 3
        #expect(ZoomLane.isSuggestion(tuned), "a scale is not an aim")
    }

    // MARK: - Persistence

    @Test func aFramedZoomIsStillFramedAfterASaveAndAReopen() throws {
        var timeline = Timeline(sourceDuration: seconds(30))
        var framed = suggested(at: 1)
        framed.scale = 3.25
        framed.center = CGPoint(x: 0.18, y: 0.62)
        framed.followsCursor = false
        framed.isEdited = true
        timeline.zooms = [framed, suggested(at: 6)]

        let read = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        let kept = try #require(read.zooms.first { $0.id == framed.id })
        #expect(kept.isEdited)
        #expect(kept.scale == 3.25)
        #expect(kept.center == CGPoint(x: 0.18, y: 0.62))
        #expect(!kept.followsCursor)
        #expect(read.zooms.last?.isEdited == false, "and an untouched one stays untouched")
    }

    /// A project written before the flag existed reads as untouched, and — the thing the
    /// lenient decoder is actually for — every other field it did have survives the new key.
    @Test func anOlderProjectsZoomsDecodeAsUntouched() throws {
        let old = #"""
        {"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
         "start":{"value":600,"timescale":600,"flags":1,"epoch":0},
         "duration":{"value":1200,"timescale":600,"flags":1,"epoch":0},
         "scale":3.5,"center":[0.25,0.75],"easing":"spring",
         "transition":{"value":1,"timescale":2,"flags":1,"epoch":0},
         "followsCursor":false,"source":"click","isLocked":false,"isEnabled":true}
        """#
        let zoom = try JSONDecoder().decode(ZoomRegion.self, from: Data(old.utf8))
        #expect(!zoom.isEdited)
        #expect(zoom.scale == 3.5)
        #expect(zoom.center == CGPoint(x: 0.25, y: 0.75))
        #expect(zoom.source == .click)
        #expect(ZoomLane.isSuggestion(zoom), "which means the next run may still replace it")
    }

    /// Resetting the framing gives the zoom back to auto-zoom, because a zoom whose framing
    /// is the default again has no hand-made framing left to protect.
    @Test func resettingTheFramingHandsAZoomBack() {
        var zoom = suggested(at: 1)
        zoom.isEdited = true
        zoom.isEdited = false
        zoom.scale = ZoomRegion.defaultScale
        zoom.center = CGPoint(x: 0.5, y: 0.5)
        #expect(ZoomLane.isSuggestion(zoom))
    }

    /// A locked zoom was already safe, and still is: the two guards are independent, so
    /// unlocking a zoom somebody framed does not expose the framing.
    @Test func lockingAndFramingGuardSeparately() {
        var locked = suggested(at: 1)
        locked.isLocked = true
        #expect(!ZoomLane.isSuggestion(locked))

        var both = locked
        both.isEdited = true
        both.isLocked = false
        #expect(!ZoomLane.isSuggestion(both), "unlocking does not un-frame")
    }
}
