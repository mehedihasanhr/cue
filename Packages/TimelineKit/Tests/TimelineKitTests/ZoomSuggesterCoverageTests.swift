import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// Every click gets looked at.
///
/// The hole these exist for: clicks were gathered into moments by *time alone*, and a
/// moment whose clicks turned out to be spread across the screen was then thrown away
/// whole. So a click on the left of the screen and one on the right two seconds later
/// produced no zoom at all — and the further apart they were, the more certain it was that
/// neither would be seen. "Some events happen but no zoom is added" is exactly that.
struct ZoomSuggesterCoverageTests {
    private let frame = CGSize(width: 1_440, height: 900)

    private func suggester(_ tuning: ZoomSuggester.Tuning = .init()) -> ZoomSuggester {
        ZoomSuggester(frameSize: frame, tuning: tuning)
    }

    private func click(_ t: Double, _ x: Double, _ y: Double) -> InputSample {
        .mouseDown(t: t, button: 0, x: x, y: y)
    }

    private func zooms(_ input: [InputSample], seconds: Double = 60) -> [ZoomRegion] {
        suggester().suggestions(cursor: [], input: input,
                                duration: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Whether some zoom is in force at a moment.
    private func covered(_ zooms: [ZoomRegion], at seconds: Double) -> Bool {
        let at = CMTime(seconds: seconds, preferredTimescale: 600)
        return zooms.contains { $0.contains(at) }
    }

    // MARK: - Nothing is dropped

    /// The bug, as a test: two clicks at opposite ends of the screen, close in time.
    @Test func twoClicksFarApartAreTwoMomentsRatherThanNone() {
        let zooms = zooms([click(5, 120, 450), click(7, 1_320, 450)])

        #expect(zooms.count == 2, "each click is its own moment")
        #expect(covered(zooms, at: 5), "the first click is in shot")
        #expect(covered(zooms, at: 7), "and so is the second")
        // Which half of the screen each is about. Not the click's own position: a shot
        // around a click near an edge is pulled inside the picture, so the centre sits
        // further in than the click did. See `ZoomEdgeFramingTests`.
        #expect(zooms[0].center.x < 0.5, "the first is pointed at the left")
        #expect(zooms[1].center.x > 0.5, "and the second at the right")
    }

    /// Clicks that wander across the screen, each soon after the last, are not one long
    /// zoom.
    ///
    /// From a real take: eight clicks over nine seconds, from one side of the screen to the
    /// other, each under the gap that joins clicks into one moment. They all joined one
    /// 11-second zoom that dragged itself after them — the limit on how far a moment could
    /// spread was 900 points, wider than a 1.8× shot and taller than the whole screen.
    @Test func clicksWanderingAcrossTheScreenAreNotOneLongZoom() {
        let clicks = [click(22.4, 1_274, 668), click(23.9, 700, 478), click(24.7, 878, 409),
                      click(27.1, 526, 475), click(27.8, 549, 570), click(28.3, 563, 652),
                      click(29.3, 906, 772), click(31.0, 117, 409)]
        let zooms = zooms(clicks)
        #expect(zooms.count > 1, "one zoom for all of them")
        #expect(zooms.allSatisfy { $0.duration.seconds <= 7 },
                "a zoom of \(zooms.map(\.duration.seconds).max() ?? 0) s")
        for click in clicks {
            guard case .mouseDown(let t, _, _, _) = click else { continue }
            #expect(covered(zooms, at: t), "the click at \(t) s is in shot")
        }
    }

    /// A steady run of clicks along one line of text is several zooms, not one.
    ///
    /// From a real take: eleven clicks over eleven seconds, about one a second, all on the
    /// same line. Each was under the old 2.5-second gap from the last, and the zooms they
    /// did make overlapped and were merged back together — one 13.6-second zoom.
    @Test func aSteadyRunOfClicksIsSeveralZoomsNotOne() {
        let clicks = [click(3.2, 868, 352), click(3.61, 933, 337), click(4.84, 653, 383),
                      click(5.87, 400, 383), click(7.64, 523, 362), click(8.23, 523, 351),
                      click(8.94, 560, 350), click(10.39, 564, 352), click(11.19, 644, 345),
                      click(12.72, 586, 349), click(14.17, 485, 356)]
        let zooms = zooms(clicks)
        #expect(zooms.count > 1)
        #expect(zooms.allSatisfy { $0.duration.seconds <= ZoomSuggester.Tuning().longestMerge + 0.001 },
                "a zoom of \(zooms.map(\.duration.seconds).max() ?? 0) s")
        for click in clicks {
            guard case .mouseDown(let t, _, _, _) = click else { continue }
            #expect(covered(zooms, at: t), "the click at \(t) s is in shot")
        }
    }

    /// Every gap auto-zoom leaves between two zooms is one the camera is zoomed out in, and
    /// a pause in the work is such a gap.
    ///
    /// From a real take: thirteen zooms in a minute, nearly all closer together than the
    /// camera would go out and back in for, so it glided from one to the next and the
    /// picture was zoomed in where the timeline showed a gap between zooms.
    @Test func autoZoomLeavesNoGapTheCameraStaysZoomedThrough() {
        var clicks: [InputSample] = []
        var t = 2.0
        var step = 0
        while t < 58 {
            let x = [300.0, 900, 520, 1_200, 700][step % 5]
            clicks.append(click(t, x, 300 + Double(step % 3) * 150))
            // Bursts of three clicks, then a pause.
            t += step % 3 == 2 ? 3.5 : 0.8
            step += 1
        }
        let zooms = suggester().smartSuggestions(cursor: [], input: clicks, focus: [],
                                                 duration: CMTime(seconds: 60, preferredTimescale: 600))
        var outside = 0.0
        for (a, b) in zip(zooms, zooms.dropFirst()) {
            let gap = (b.start - a.end).seconds
            #expect(gap == 0 || gap >= ZoomGlide.longestGlidedGap,
                    "a \(gap) s gap at \(a.end.seconds) s, which the camera would stay zoomed through")
            outside += gap
        }
        #expect(outside > 10, "zoomed out for only \(outside) s of 60")
        for click in clicks {
            guard case .mouseDown(let t, _, _, _) = click else { continue }
            #expect(covered(zooms, at: t), "the click at \(t) s is in shot")
        }
    }

    /// Every click of a real take is zoomed, and zoomed all the way in when it lands —
    /// not caught by a zoom still on its way in or already on its way out.
    @Test func everyClickLandsWhileItsZoomIsAllTheWayIn() {
        let clicks = [click(2.0, 186, 238), click(7.0, 576, 524), click(11.53, 1_069, 215), click(12.42, 1_128, 216),
                      click(13.6, 985, 217), click(15.45, 1_198, 219), click(16.3, 1_260, 218), click(17.18, 1_312, 219),
                      click(18.51, 1_356, 212), click(19.11, 1_429, 212), click(20.07, 1_405, 211), click(22.65, 1_094, 214),
                      click(25.47, 251, 270), click(28.28, 495, 271), click(29.19, 594, 272), click(32.36, 551, 334),
                      click(36.49, 1_393, 844), click(40.31, 189, 420), click(42.85, 511, 436), click(43.77, 522, 509),
                      click(44.45, 524, 435), click(45.07, 524, 459)]
        let zooms = suggester().smartSuggestions(cursor: [], input: clicks, focus: [],
                                                 duration: CMTime(seconds: 47, preferredTimescale: 600))
        for click in clicks {
            guard case .mouseDown(let t, _, _, _) = click else { continue }
            let at = CMTime(seconds: t, preferredTimescale: 600)
            // In, at full depth: either inside a zoom's held part, or where one zoom glides
            // on to the next touching it, which stays in.
            let full = zooms.contains { zoom in
                let held = zoom.start + zoom.transition <= at && at <= zoom.end - zoom.transition
                let gliding = zoom.contains(at) && zooms.contains { $0.start == zoom.end || $0.end == zoom.start }
                return held || gliding
            }
            #expect(full, "the click at \(t) s is not zoomed all the way in")
        }
    }

    /// Busy clicks are not left out because a neighbouring zoom touches theirs.
    ///
    /// From a real take: a run of work split into zooms that touch, so each piece shut out
    /// the next — four clicks on one form went unzoomed beside a zoom with as many.
    @Test func busyClicksAreNotDroppedForTouchingANeighbour() {
        let clicks = [click(1.42, 671, 711), click(3.79, 654, 584), click(5.54, 538, 393), click(6.83, 705, 582),
                      click(9.13, 791, 159), click(10.16, 903, 165), click(11.09, 586, 636), click(11.77, 538, 603),
                      click(12.83, 554, 596), click(14.0, 1_072, 478), click(16.74, 1_219, 417), click(18.2, 727, 622),
                      click(18.75, 837, 621), click(19.5, 672, 621), click(20.1, 621, 620), click(20.69, 546, 625),
                      click(23.7, 224, 492), click(29.66, 196, 534), click(35.34, 204, 548), click(39.43, 536, 261),
                      click(40.32, 637, 251), click(43.36, 601, 532), click(44.5, 439, 520), click(47.96, 170, 636),
                      click(50.34, 154, 541)]
        let zooms = suggester().smartSuggestions(cursor: [], input: clicks, focus: [],
                                                 duration: CMTime(seconds: 52.3, preferredTimescale: 600))
        let inShot = clicks.filter { click in
            guard case .mouseDown(let t, _, _, _) = click else { return false }
            return covered(zooms, at: t)
        }.count
        #expect(inShot == clicks.count, "only \(inShot) of \(clicks.count) clicks zoomed")
    }

    /// Clicks in one place for longer than a zoom may last are all in shot, rather than
    /// the zoom being cut off at its longest before the last of them.
    @Test func aLongRunOfClicksInOnePlaceIsNotCutShort() {
        let clicks = stride(from: 5.0, through: 25, by: 1.5).map { click($0, 700, 450) }
        let zooms = zooms(clicks)
        for click in clicks {
            guard case .mouseDown(let t, _, _, _) = click else { continue }
            #expect(covered(zooms, at: t), "the click at \(t) s is in shot")
        }
    }

    /// Clicks on the same thing are still one moment, not one zoom each. That was always
    /// right and must stay right.
    @Test func clicksOnTheSameThingAreStillOneMoment() {
        let zooms = zooms([click(5, 600, 400), click(5.4, 615, 410), click(6, 590, 395)])
        #expect(zooms.count == 1)
        #expect(covered(zooms, at: 5) && covered(zooms, at: 6))
    }

    /// A double-click is one moment, obviously, and must not produce two overlapping zooms
    /// fighting over the same instant.
    @Test func aDoubleClickIsOneMoment() {
        let zooms = zooms([click(3, 700, 300), click(3.15, 700, 300)])
        #expect(zooms.count == 1)
    }

    /// The case that used to fail worst: a run of clicks walking across the screen. Every
    /// one of them used to be lost, because the cluster kept growing past the spread limit
    /// and was discarded at the end.
    @Test func aRunOfClicksAcrossTheScreenIsCoveredEndToEnd() {
        let walk = (0..<6).map { click(4 + Double($0) * 1.5, 120 + Double($0) * 240, 450) }
        let zooms = zooms(walk)

        #expect(!zooms.isEmpty)
        for (index, _) in walk.enumerated() {
            #expect(covered(zooms, at: 4 + Double(index) * 1.5), "click \(index) was not covered")
        }
    }

    /// And every click in a long session lands in some zoom, whatever the shape of it.
    @Test func everyClickInAMessySessionIsCovered() {
        var input: [InputSample] = []
        var times: [Double] = []
        var generator = SeededGenerator(seed: 20_260_926)
        var t = 2.0
        while t < 55 {
            let x = Double.random(in: 40...1_400, using: &generator)
            let y = Double.random(in: 40...860, using: &generator)
            input.append(click(t, x, y))
            times.append(t)
            t += Double.random(in: 0.2...3.5, using: &generator)
        }

        let zooms = zooms(input)
        let missed = times.filter { !covered(zooms, at: $0) }
        #expect(missed.isEmpty, "\(missed.count) of \(times.count) clicks got no zoom: \(missed.prefix(5))")
    }

    // MARK: - Two places stay two places

    /// Overlapping moments in different places are not averaged into a point nobody
    /// clicked. The camera has to frame one of them, not the midpoint of both.
    @Test func overlappingMomentsInDifferentPlacesAreNotAveraged() {
        let zooms = zooms([click(5, 120, 450), click(7, 1_320, 450)])
        #expect(zooms.count == 2)
        // Each is about one side or the other, rather than the midpoint of both.
        #expect(zooms[0].center.x < 0.5 && zooms[1].center.x > 0.5,
                "a zoom landed between the two clicks")
    }

    /// Too close together to be split into anything watchable, they stay one moment —
    /// aimed at the later of them, because the midpoint of two opposite corners is a point
    /// nobody clicked.
    @Test func momentsTooCloseToSplitBecomeOneAimedAtTheLater() {
        let zooms = zooms([click(5, 120, 450), click(6.2, 1_320, 450)])
        #expect(zooms.count == 1)
        #expect((zooms.first?.center.x ?? 0) > 0.6, "pointed where the clicking ended")
    }

    /// And they still do not overlap, so the camera never has two answers at one moment.
    @Test func theSuggestionsNeverOverlap() {
        let walk = (0..<8).map { click(3 + Double($0) * 1.1, 100 + Double($0) * 180, 400) }
        let zooms = zooms(walk).sorted { $0.start < $1.start }
        for (a, b) in zip(zooms, zooms.dropFirst()) {
            #expect(a.end <= b.start, "\(a.end.seconds) runs into \(b.start.seconds)")
        }
    }

    /// Clicks on the same thing *are* averaged, which is what makes a cluster a cluster.
    @Test func momentsInTheSamePlaceAreStillMergedTogether() {
        let zooms = zooms([click(5, 600, 400), click(6.2, 640, 420)])
        #expect(zooms.count == 1, "one place, one zoom")
    }
}

/// A repeatable random sequence, so "a messy session" is the same mess every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Edge-aware framing: a zoom is aimed at something that is actually in the picture.
///
/// A click near an edge gave a centre near that edge, and a shot around it reaches past
/// the frame — so the zoom was partly aimed at nothing. The renderer refused to go there,
/// clamping the camera at the last moment, but the zoom on the timeline still *said* it
/// pointed off the edge: the inspector showed that centre and the framing box on the
/// preview was drawn hanging off the picture.
struct ZoomEdgeFramingTests {
    private let frame = CGSize(width: 1_440, height: 900)

    private func click(_ t: Double, _ x: Double, _ y: Double) -> InputSample {
        .mouseDown(t: t, button: 0, x: x, y: y)
    }

    private func zooms(_ input: [InputSample]) -> [ZoomRegion] {
        ZoomSuggester(frameSize: frame).suggestions(
            cursor: [], input: input, duration: CMTime(seconds: 60, preferredTimescale: 600))
    }

    /// The shot a zoom describes, in the frame's own coordinates.
    private func area(_ zoom: ZoomRegion) -> CGRect {
        let half = 0.5 / max(1, zoom.scale)
        return CGRect(x: zoom.center.x - half, y: zoom.center.y - half,
                      width: half * 2, height: half * 2)
    }

    @Test(arguments: [
        CGPoint(x: 8, y: 8),            // top left
        CGPoint(x: 1_432, y: 8),        // top right
        CGPoint(x: 8, y: 892),          // bottom left
        CGPoint(x: 1_432, y: 892),      // bottom right
        CGPoint(x: 720, y: 2),          // hard against the top
    ])
    func aClickAtTheEdgeIsFramedInsideThePicture(_ at: CGPoint) {
        let zooms = zooms([click(5, at.x, at.y)])
        let zoom = try? #require(zooms.first)
        let area = area(zoom ?? ZoomRegion(start: .zero, duration: .zero))

        #expect(area.minX >= -0.0001, "reaches \(area.minX) off the left")
        #expect(area.minY >= -0.0001, "reaches \(area.minY) off the top")
        #expect(area.maxX <= 1.0001, "reaches \(area.maxX) off the right")
        #expect(area.maxY <= 1.0001, "reaches \(area.maxY) off the bottom")
    }

    /// And it is still pointed at that corner rather than being dragged to the middle:
    /// clamped by exactly as much as it had to be, and no more.
    @Test func aCornerClickStillShowsTheCorner() {
        let zoom = try? #require(zooms([click(5, 8, 8)]).first)
        let area = area(zoom ?? ZoomRegion(start: .zero, duration: .zero))
        #expect(abs(area.minX) < 0.0001, "flush against the left edge")
        #expect(abs(area.minY) < 0.0001, "flush against the top edge")
    }

    /// A click in the middle is untouched — the clamp only binds where it must.
    @Test func aClickInTheMiddleIsLeftAlone() {
        let zoom = try? #require(zooms([click(5, 720, 450)]).first)
        #expect(abs((zoom?.center.x ?? 0) - 0.5) < 0.01)
        #expect(abs((zoom?.center.y ?? 0) - 0.5) < 0.01)
    }
}
