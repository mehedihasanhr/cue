import Foundation
import Testing
@testable import TimelineKit

/// The sums behind the studio's hand-drawn sliders and segmented rows.
///
/// Each of these is a way a custom control feels wrong in the hand without anything
/// visibly breaking: a knob that jumps when grabbed, a stepped slider that never reaches
/// its maximum, a segmented row that squeezes its titles instead of wrapping.
struct ControlMathTests {
    // MARK: - Fractions and positions

    @Test func fractionIsClampedAndSafeForAnEmptyRange() {
        #expect(SliderMath.fraction(of: 5, in: 0...10) == 0.5)
        #expect(SliderMath.fraction(of: -3, in: 0...10) == 0)
        #expect(SliderMath.fraction(of: 30, in: 0...10) == 1)
        #expect(SliderMath.fraction(of: 4, in: 4...4) == 0)
        #expect(SliderMath.fraction(of: .nan, in: 0...1) == 0)
    }

    @Test func pointerOnTheKnobCentreLeavesTheValueAlone() {
        // A 112-point track with a 12-point knob travels 100 points.
        let offset = SliderMath.knobOffset(fraction: 0.3, trackLength: 112, knob: 12)
        #expect(offset == 30)
        let centre = offset + 6
        #expect(abs(SliderMath.fraction(atPointer: centre, trackLength: 112, knob: 12) - 0.3) < 1e-9)
    }

    @Test func pointerPastEitherEndPinsToThatEnd() {
        #expect(SliderMath.fraction(atPointer: -40, trackLength: 112, knob: 12) == 0)
        #expect(SliderMath.fraction(atPointer: 500, trackLength: 112, knob: 12) == 1)
        #expect(SliderMath.fraction(atPointer: 5, trackLength: 10, knob: 12) == 0)
    }

    // MARK: - Steps

    @Test func stepsCountFromTheLowerBound() {
        #expect(SliderMath.snapped(4.2, in: 1...10, step: 2) == 5)
        #expect(SliderMath.snapped(3.9, in: 1...10, step: 2) == 3)
    }

    @Test func theUpperBoundIsReachableWhenTheStepDoesNotDivideTheSpan() {
        #expect(SliderMath.value(atFraction: 1, in: 1...10, step: 2) == 10)
        #expect(SliderMath.snapped(9.99, in: 1...10, step: 2) == 9)
        #expect(SliderMath.nudged(9, direction: 1, in: 1...10, step: 2) == 10)
    }

    @Test func noStepMeansAnyValue() {
        #expect(SliderMath.value(atFraction: 0.25, in: 0...2, step: nil) == 0.5)
        #expect(SliderMath.snapped(.infinity, in: 0...2, step: nil) == 0)
    }

    @Test func arrowKeysMoveAHundredthOrAStep() {
        #expect(SliderMath.increment(in: 0...200, step: nil, large: false) == 2)
        #expect(SliderMath.increment(in: 0...200, step: nil, large: true) == 20)
        #expect(SliderMath.increment(in: 0...10, step: 0.5, large: false) == 0.5)
        // A tenth is one step here, so the large increment is one step and on the grid.
        #expect(SliderMath.increment(in: 0...10, step: 1, large: true) == 1)
        // A tenth of 0...10 is 1, which is three steps of 0.4 rounded up: 1.2.
        #expect(abs(SliderMath.increment(in: 0...10, step: 0.4, large: true) - 1.2) < 1e-9)
    }

    @Test func nudgingStopsAtTheEnds() {
        #expect(SliderMath.nudged(0, direction: -1, in: 0...1, step: nil) == 0)
        #expect(SliderMath.nudged(1, direction: 1, in: 0...1, step: nil) == 1)
        #expect(abs(SliderMath.nudged(0.5, direction: 1, in: 0...1, step: nil) - 0.51) < 1e-9)
    }

    // MARK: - Two thumbs

    @Test func thePressTakesTheNearerThumb() {
        #expect(RangeSliderMath.nearestThumb(to: 2, lower: 3, upper: 8) == .lower)
        #expect(RangeSliderMath.nearestThumb(to: 9, lower: 3, upper: 8) == .upper)
        #expect(RangeSliderMath.nearestThumb(to: 4, lower: 3, upper: 8) == .lower)
        #expect(RangeSliderMath.nearestThumb(to: 7, lower: 3, upper: 8) == .upper)
    }

    @Test func aSqueezedRangeOpensTowardsThePress() {
        #expect(RangeSliderMath.nearestThumb(to: 4, lower: 5, upper: 5) == .lower)
        #expect(RangeSliderMath.nearestThumb(to: 6, lower: 5, upper: 5) == .upper)
    }

    @Test func aThumbStopsAtTheOtherRatherThanCrossingIt() {
        let lowered = RangeSliderMath.moving(.lower, to: 9, lower: 2, upper: 6, in: 0...10)
        #expect(lowered.lower == 6 && lowered.upper == 6)
        let raised = RangeSliderMath.moving(.upper, to: 1, lower: 2, upper: 6, in: 0...10, minimumSpan: 1)
        #expect(raised.lower == 2 && raised.upper == 3)
        let outside = RangeSliderMath.moving(.lower, to: -4, lower: 2, upper: 6, in: 0...10)
        #expect(outside.lower == 0)
    }

    @Test func aRangeThumbLandsOnTheStepGrid() {
        let moved = RangeSliderMath.moving(.upper, to: 7.3, lower: 0, upper: 10, in: 0...10, step: 0.5)
        #expect(moved.upper == 7.5)
    }

    // MARK: - Segments

    @Test func segmentsTakeOneLineWhenTheyFit() {
        #expect(SegmentGrid.perRow(count: 4, widest: 50, available: 300, spacing: 2) == 4)
    }

    @Test func segmentsBreakIntoBalancedLinesRatherThanShrinking() {
        // Six at 60 need 370; three to a line need 184.
        #expect(SegmentGrid.perRow(count: 6, widest: 60, available: 250, spacing: 2) == 3)
        #expect(SegmentGrid.perRow(count: 6, widest: 60, available: 100, spacing: 2) == 1)
        #expect(SegmentGrid.perRow(count: 1, widest: 400, available: 100, spacing: 2) == 1)
    }

    // MARK: - Hex

    @Test func hexReadsEveryCommonSpelling() {
        #expect(HexColor.parse("#0E4FEC") == HexColor.RGBA(red: 14 / 255, green: 79 / 255, blue: 236 / 255))
        #expect(HexColor.parse(" fff ") == HexColor.RGBA(red: 1, green: 1, blue: 1))
        #expect(HexColor.parse("#00000080")?.alpha == 128.0 / 255)
        #expect(HexColor.parse("#f008")?.alpha == 136.0 / 255)
    }

    @Test func hexRefusesWhatItCannotRead() {
        #expect(HexColor.parse("#12345") == nil)
        #expect(HexColor.parse("blue") == nil)
        #expect(HexColor.parse("") == nil)
    }

    @Test func hexWritesAndReadsBack() {
        let colour = HexColor.RGBA(red: 14 / 255, green: 79 / 255, blue: 236 / 255, alpha: 0.5)
        #expect(HexColor.format(colour) == "#0E4FEC")
        #expect(HexColor.format(colour, includeAlpha: true) == "#0E4FEC80")
        #expect(HexColor.parse(HexColor.format(colour)) == HexColor.RGBA(red: 14 / 255, green: 79 / 255, blue: 236 / 255))
    }
}
