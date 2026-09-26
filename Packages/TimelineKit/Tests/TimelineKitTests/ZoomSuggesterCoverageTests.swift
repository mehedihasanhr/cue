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
        #expect(zooms[0].center.x < 0.25, "the first is pointed at the left")
        #expect(zooms[1].center.x > 0.75, "and the second at the right")
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
        for zoom in zooms {
            #expect(zoom.center.x < 0.25 || zoom.center.x > 0.75,
                    "a zoom landed at \(zoom.center.x), between the two clicks")
        }
    }

    /// Too close together to be split into anything watchable, they stay one moment —
    /// aimed at the later of them, because the midpoint of two opposite corners is a point
    /// nobody clicked.
    @Test func momentsTooCloseToSplitBecomeOneAimedAtTheLater() {
        let zooms = zooms([click(5, 120, 450), click(6.2, 1_320, 450)])
        #expect(zooms.count == 1)
        #expect((zooms.first?.center.x ?? 0) > 0.75, "pointed where the clicking ended")
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
