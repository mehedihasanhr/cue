import Foundation
import Testing
@testable import TimelineKit

/// The timeline strip's layout arithmetic: how much room a chip's words get, where the
/// ruler puts its numbers, and how loud a waveform is drawn.
struct TimelineLayoutTests {
    // MARK: - Chip labels

    @Test func aShortZoomStillHasRoomForItsScale() {
        // An auto-zoom at its minimum length, on a 34-second take fitted to a 900-point
        // timeline: about 45 points. "1.8×" at 11 points semibold is about 24 wide. The old
        // gate asked for more than 48 points before it showed anything at all.
        #expect(TimelineLayout.labelRoom(forChipWidth: 45) >= 24)
    }

    @Test func roomGrowsWithTheChipAndNeverGoesNegative() {
        var last = -1.0
        for width in stride(from: 0.0, through: 400, by: 1) {
            let room = TimelineLayout.labelRoom(forChipWidth: width)
            #expect(room >= 0)
            #expect(room >= last)
            last = room
        }
    }

    @Test func gripsAreAtMostAQuarterOfTheChip() {
        #expect(TimelineLayout.gripBar(forChipWidth: 200) == 7)
        #expect(TimelineLayout.gripBar(forChipWidth: 20) == 5)
        #expect(TimelineLayout.gripBar(forChipWidth: 4) == 3)
    }

    @Test func aWideChipLosesOnlyItsGripsToTheLabel() {
        #expect(TimelineLayout.labelRoom(forChipWidth: 120) == 120 - 18)
    }

    // MARK: - Ruler steps

    @Test func numbersAreNeverCloserThanTheMinimum() {
        for pointsPerSecond in stride(from: 1.0, through: 600, by: 0.5) {
            let step = TimelineLayout.rulerStep(forPointsPerSecond: pointsPerSecond)
            #expect(step * pointsPerSecond >= TimelineLayout.minimumLabelSpacing || step == 900)
        }
    }

    @Test func theStepIsTheFinestThatFits() {
        // 34 seconds across 830 points: about 24 a second, so every 5 seconds.
        #expect(TimelineLayout.rulerStep(forPointsPerSecond: 24) == 5)
        // Very wide: every second.
        #expect(TimelineLayout.rulerStep(forPointsPerSecond: 80) == 1)
        // Zoomed right in: tenths.
        #expect(TimelineLayout.rulerStep(forPointsPerSecond: 600) == 0.1)
    }

    @Test func noStepPrintsAsUnevenTenths() {
        // Every step is a whole number of tenths, so one decimal place labels it exactly.
        for step in TimelineLayout.rulerSteps where step < 1 {
            let tenths = step * 10
            #expect(abs(tenths - tenths.rounded()) < 1e-9)
        }
    }

    @Test func subdivisionsLandOnRoundNumbersAndKeepTheirDistance() {
        for pointsPerSecond in stride(from: 1.0, through: 600, by: 1) {
            let step = TimelineLayout.rulerStep(forPointsPerSecond: pointsPerSecond)
            let parts = TimelineLayout.rulerSubdivisions(step: step, pointsPerSecond: pointsPerSecond)
            #expect(parts >= 2)
            #expect(step * pointsPerSecond / Double(parts) >= 12)
        }
        // Five seconds apart and far enough to show it: a mark each second.
        #expect(TimelineLayout.rulerSubdivisions(step: 5, pointsPerSecond: 20) == 5)
        // Close together: only the halfway mark.
        #expect(TimelineLayout.rulerSubdivisions(step: 1, pointsPerSecond: 56) == 4)
        #expect(TimelineLayout.rulerSubdivisions(step: 1, pointsPerSecond: 40) == 2)
    }

    // MARK: - Ruler labels and the playhead

    @Test func aLabelUnderTheKnobIsHidden() {
        // "0s" at the very start, with the playhead parked on zero.
        #expect(TimelineLayout.rulerLabelOpacity(minX: 6, maxX: 18, playheadX: 12) == 0)
        // Overlapping the knob's edge rather than its centre.
        #expect(TimelineLayout.rulerLabelOpacity(minX: 16, maxX: 30, playheadX: 12) == 0)
    }

    @Test func aLabelClearOfTheKnobIsFullyDrawn() {
        #expect(TimelineLayout.rulerLabelOpacity(minX: 100, maxX: 120, playheadX: 12) == 1)
        #expect(TimelineLayout.rulerLabelOpacity(minX: 100, maxX: 120, playheadX: 300) == 1)
    }

    @Test func labelsFadeRatherThanBlink() {
        let near = TimelineLayout.rulerLabelOpacity(minX: 22, maxX: 40, playheadX: 12)
        #expect(near > 0 && near < 1)
    }

    // MARK: - Waveform levels

    @Test func silenceStaysFlatAndLoudStaysFull() {
        #expect(TimelineLayout.displayedLevel(0) == 0)
        #expect(TimelineLayout.displayedLevel(1) == 1)
        #expect(TimelineLayout.displayedLevel(-1) == 1)
        #expect(TimelineLayout.displayedLevel(4) == 1)
    }

    @Test func quietSoundIsLiftedWithoutReordering() {
        // Speech at a fifth of full scale is drawn at almost half the lane.
        #expect(TimelineLayout.displayedLevel(0.2) > 0.4)
        #expect(TimelineLayout.displayedLevel(0.1) < TimelineLayout.displayedLevel(0.2))
    }
}
