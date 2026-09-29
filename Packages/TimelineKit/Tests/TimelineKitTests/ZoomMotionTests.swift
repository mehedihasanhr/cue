import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

/// A zoom that cuts rather than moves.
struct InstantZoomTests {
    private func zoom(start: Double, duration: Double, scale: Double = 3,
                      ramp: Double = 0.5, instant: Bool = true) -> ZoomRegion {
        ZoomRegion(start: time(start), duration: time(duration), scale: scale,
                   easing: .easeInOut, transition: time(ramp), isInstant: instant)
    }

    /// The frame the region begins on is already all the way in; the frame after its
    /// last is all the way out. Sampled on a 60 fps grid, which is what an export walks.
    @Test func fullyInOnItsFirstFrameAndOutOnTheFrameAfterItsLast() {
        let region = zoom(start: 2, duration: 4)
        let frame = { (index: Int) in CMTime(value: CMTimeValue(index), timescale: 60) }
        #expect(region.scale(at: frame(119)) == 1, "the frame before it is untouched")
        #expect(region.scale(at: frame(120)) == 3, "the first frame it covers is all the way in")
        #expect(region.scale(at: frame(359)) == 3, "and so is the last")
        #expect(region.scale(at: frame(360)) == 1, "the frame after it is all the way out")
    }

    /// A start that falls between two frames is in on the first frame after it.
    @Test func aStartBetweenFramesIsInOnTheNextFrame() {
        let region = zoom(start: 2.005, duration: 4)
        let frame = { (index: Int) in CMTime(value: CMTimeValue(index), timescale: 60) }
        #expect(region.scale(at: frame(120)) == 1)
        #expect(region.scale(at: frame(121)) == 3)
    }

    @Test func theRampIsKeptUnderneathForSwitchingBack() {
        var region = zoom(start: 2, duration: 4, ramp: 0.5)
        #expect(region.ramps.in == .zero && region.ramps.out == .zero)
        region.isInstant = false
        #expect(region.ramps.in == time(0.5) && region.ramps.out == time(0.5))
        #expect(region.scale(at: time(2)) == 1, "and the movement is back exactly")
    }

    // MARK: - Old projects

    /// A zoom written before the field existed is a movement, because that is what it was.
    @Test func aZoomFromAnOlderProjectIsSmooth() throws {
        let json = #"{"id":"\#(UUID().uuidString)","start":{"value":0,"timescale":600},"duration":{"value":600,"timescale":600},"scale":2}"#
        let read = try JSONDecoder().decode(ZoomRegion.self, from: Data(json.utf8))
        #expect(read.isInstant == false)
    }

    @Test func beingInstantSurvivesSavingAndReopening() throws {
        let region = zoom(start: 1, duration: 2)
        let read = try JSONDecoder().decode(ZoomRegion.self, from: JSONEncoder().encode(region))
        #expect(read.isInstant)
    }

    // MARK: - The zoom verbs

    @Test func splittingKeepsBothHalvesInstant() throws {
        let (first, second) = try #require(ZoomLane.split(zoom(start: 2, duration: 4), at: time(4)))
        #expect(first.isInstant && second.isInstant)
    }

    @Test func mergingTakesTheLongerZoomsAnswer() throws {
        let short = zoom(start: 2, duration: 1, instant: true)
        let long = zoom(start: 4, duration: 5, instant: false)
        let merged = try #require(ZoomLane.merge(short, long))
        #expect(merged.isInstant == false, "the longer one's look wins, as it does for scale")
    }

    @Test func resettingTheRampMakesItSmoothAgain() {
        #expect(ZoomLane.reset(zoom(start: 2, duration: 4)).isInstant == false)
    }
}

/// The camera travelling straight between two zooms that are close together.
struct ZoomGlideTests {
    private func zoom(start: Double, duration: Double, scale: Double = 2,
                      ramp: Double = 0.5, easing: Easing = .easeInOut,
                      center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> ZoomRegion {
        ZoomRegion(start: time(start), duration: time(duration), scale: scale,
                   center: center, easing: easing, transition: time(ramp), followsCursor: false)
    }

    // MARK: - When two zooms glide

    @Test func touchingZoomsGlide() throws {
        let glide = try #require(ZoomLane.glides(in: [zoom(start: 2, duration: 4), zoom(start: 6, duration: 4)]).first)
        #expect(glide.start == time(5.5), "leaves where the first would have started pulling back")
        #expect(glide.end == time(6.5), "arrives where the second would have finished pushing in")
    }

    @Test func aGapShorterThanTheTwoRampsGlides() {
        let glides = ZoomLane.glides(in: [zoom(start: 2, duration: 4), zoom(start: 6.9, duration: 4)])
        #expect(glides.count == 1)
        #expect(glides.first?.start == time(5.5))
        #expect(glides.first?.end == time(7.4))
    }

    /// A gap as long as the ramps is a pause, and the camera pulls back through it.
    @Test func aGapAsLongAsTheTwoRampsDoesNot() {
        #expect(ZoomLane.glides(in: [zoom(start: 2, duration: 4), zoom(start: 7, duration: 4)]).isEmpty)
        #expect(ZoomLane.glides(in: [zoom(start: 2, duration: 4), zoom(start: 12, duration: 4)]).isEmpty)
    }

    /// Ramps of different lengths: the gap is measured against the two that meet in it.
    @Test func theRampsThatMeetInTheGapDecide() {
        let first = zoom(start: 2, duration: 4, ramp: 0.2)
        let second = zoom(start: 6.5, duration: 4, ramp: 0.6)
        #expect(ZoomLane.glides(in: [first, second]).count == 1, "0.5 is under 0.8")
        let farther = zoom(start: 6.9, duration: 4, ramp: 0.6)
        #expect(ZoomLane.glides(in: [first, farther]).isEmpty, "0.9 is not")
    }

    @Test func overlappingZoomsDoNotGlide() {
        #expect(ZoomLane.glides(in: [zoom(start: 2, duration: 4), zoom(start: 5.5, duration: 4)]).isEmpty)
    }

    @Test func anInstantZoomNeverGlides() {
        var cut = zoom(start: 6, duration: 4)
        cut.isInstant = true
        #expect(ZoomLane.glides(in: [zoom(start: 2, duration: 4), cut]).isEmpty)
        #expect(ZoomLane.glides(in: [cut, zoom(start: 10, duration: 4)]).isEmpty)
    }

    @Test func aSwitchedOffZoomIsLookedStraightPast() {
        var off = zoom(start: 6.1, duration: 0.3)
        off.isEnabled = false
        let glides = ZoomLane.glides(in: [zoom(start: 2, duration: 4), off, zoom(start: 6.5, duration: 4)])
        #expect(glides.count == 1)
        #expect(glides.first?.from.start == time(2))
        #expect(glides.first?.to.start == time(6.5))
        #expect(glides.first?.end == time(7))
    }

    /// The seam a split leaves — two zooms touching with no ramp at all — stays the cut
    /// it was: there is no movement to turn into another.
    @Test func aSeamlessSplitIsStillACut() {
        var first = zoom(start: 2, duration: 4)
        first.transitionOut = .zero
        var second = zoom(start: 6, duration: 4)
        second.transitionIn = .zero
        #expect(ZoomLane.glides(in: [first, second]).isEmpty)
    }

    /// Three in a row glide twice, and the two moves never overlap: the move into the
    /// middle one is over before the move out of it begins.
    @Test func aChainGlidesAtEveryJoinWithoutTheMovesOverlapping() {
        let lane = [zoom(start: 2, duration: 4), zoom(start: 6, duration: 1), zoom(start: 7, duration: 4)]
        let glides = ZoomLane.glides(in: lane)
        #expect(glides.count == 2)
        #expect(glides[0].end <= glides[1].start)
    }

    /// A long zoom in force behind a pair is deciding the shot; the pair cannot be
    /// travelling at the same time.
    @Test func aThirdZoomInForceDuringTheMoveRefusesIt() {
        let lane = [zoom(start: 0, duration: 20, scale: 1.5), zoom(start: 2, duration: 4), zoom(start: 6, duration: 4)]
        #expect(ZoomLane.glides(in: lane).isEmpty)
    }

    @Test func theLaneNeedNotBeInOrder() {
        let glides = ZoomLane.glides(in: [zoom(start: 6, duration: 4), zoom(start: 2, duration: 4)])
        #expect(glides.count == 1)
        #expect(glides.first?.from.start == time(2))
    }

    // MARK: - The move

    @Test func theScaleStaysBetweenTheTwoZooms() throws {
        let glide = try #require(ZoomLane.glides(in: [zoom(start: 2, duration: 4, scale: 3, easing: .spring),
                                                      zoom(start: 6, duration: 4, scale: 2, easing: .spring)]).first)
        for step in 0...200 {
            let at = glide.start + CMTime(seconds: Double(step) / 200, preferredTimescale: 600)
            let scale = glide.scale(at: at)
            #expect(scale >= 2 - 1e-9 && scale <= 3 + 1e-9, "outside the two at \(at.seconds)")
        }
        #expect(abs(glide.scale(at: glide.start) - 3) < 1e-9)
        #expect(abs(glide.scale(at: glide.end) - 2) < 1e-9)
    }

    @Test func theMoveIsEasedTheWayTheArrivingZoomAsks() throws {
        let glide = try #require(ZoomLane.glides(in: [zoom(start: 2, duration: 4, easing: .linear),
                                                      zoom(start: 6, duration: 4, easing: .easeInOut)]).first)
        let midway = glide.start + CMTime(seconds: 0.5, preferredTimescale: 600)
        #expect(abs(glide.progress(at: midway) - 0.5) < 1e-9)
        let quarter = glide.start + CMTime(seconds: 0.25, preferredTimescale: 600)
        #expect(abs(glide.progress(at: quarter) - Easing.easeInOut.apply(0.25)) < 1e-9)
    }

    @Test func theMoveInForceIsFoundByTime() {
        let lane = [zoom(start: 2, duration: 4), zoom(start: 6, duration: 4)]
        #expect(ZoomLane.glide(at: time(5.4), in: lane) == nil, "still held")
        #expect(ZoomLane.glide(at: time(5.5), in: lane) != nil, "leaving")
        #expect(ZoomLane.glide(at: time(6.4), in: lane) != nil, "arriving")
        #expect(ZoomLane.glide(at: time(6.5), in: lane) == nil, "arrived")
    }

    // MARK: - The project switch

    @Test func theSwitchDecidesWhetherATimelineGlidesAtAll() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.zooms = [zoom(start: 2, duration: 4), zoom(start: 6, duration: 4)]
        #expect(timeline.camera.glidesBetweenZooms, "on for a new project")
        #expect(timeline.zoomGlide(at: time(6)) != nil)
        timeline.camera.glidesBetweenZooms = false
        #expect(timeline.zoomGlide(at: time(6)) == nil)
    }

    /// A project saved before the switch existed was watched with the camera pulling
    /// back between its zooms, and opens looking the same.
    @Test func aProjectSavedBeforeTheSwitchExistedHasItOff() throws {
        let camera = try JSONDecoder().decode(CameraStyle.self, from: Data(#"{"steadiness":0.7,"follow":1,"safeArea":0.85}"#.utf8))
        #expect(camera.glidesBetweenZooms == false)
        #expect(camera.steadiness == 0.7, "and the rest of it is what it was")

        let json = """
        {"sourceDuration": {"value": 18000, "timescale": 600, "flags": 1, "epoch": 0}, "clips": []}
        """
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
        #expect(timeline.camera.glidesBetweenZooms == false, "a project with no camera at all predates it too")
    }

    @Test func theSwitchSurvivesSavingAndReopening() throws {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.camera.glidesBetweenZooms = false
        let read = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(read.camera.glidesBetweenZooms == false)
        timeline.camera.glidesBetweenZooms = true
        let again = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(again.camera.glidesBetweenZooms == true)
    }

    // MARK: - Extend to Next Zoom

    @Test func extendingMakesAZoomEndWhereTheNextBegins() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.zooms = [zoom(start: 2, duration: 3), zoom(start: 8, duration: 4)]
        let id = timeline.zooms[0].id
        #expect(Commands.ExtendZoomToNext(id: id).apply(to: &timeline))
        #expect(timeline.zooms[0].end == time(8))
        #expect(timeline.zooms[0].start == time(2), "where it starts is left alone")
        #expect(ZoomLane.glides(in: timeline.zooms).count == 1, "and the two now glide")
    }

    @Test func extendingIsRefusedWithNothingToExtendTo() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.zooms = [zoom(start: 2, duration: 3)]
        let before = timeline
        #expect(!Commands.ExtendZoomToNext(id: timeline.zooms[0].id).apply(to: &timeline))
        #expect(timeline == before)
    }

    @Test func extendingIsRefusedWhenItAlreadyReachesTheNext() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.zooms = [zoom(start: 2, duration: 6), zoom(start: 8, duration: 4)]
        #expect(!Commands.ExtendZoomToNext(id: timeline.zooms[0].id).apply(to: &timeline), "touching")
        timeline.zooms[0].duration = time(7)
        #expect(!Commands.ExtendZoomToNext(id: timeline.zooms[0].id).apply(to: &timeline), "overlapping: extend never shortens")
    }

    @Test func extendingWorksOnALockedZoom() {
        var timeline = Timeline(sourceDuration: time(30))
        var locked = zoom(start: 2, duration: 3)
        locked.isLocked = true
        timeline.zooms = [locked, zoom(start: 8, duration: 4)]
        #expect(Commands.ExtendZoomToNext(id: locked.id).apply(to: &timeline))
        #expect(timeline.zooms[0].end == time(8))
    }

    @Test func theNextZoomIsTheNextAlongTheLane() {
        let lane = [zoom(start: 8, duration: 4), zoom(start: 2, duration: 3), zoom(start: 20, duration: 1)]
        #expect(ZoomLane.zoomAfter(lane[1].id, in: lane)?.start == time(8))
        #expect(ZoomLane.zoomAfter(lane[0].id, in: lane)?.start == time(20))
        #expect(ZoomLane.zoomAfter(lane[2].id, in: lane) == nil)
    }
}
