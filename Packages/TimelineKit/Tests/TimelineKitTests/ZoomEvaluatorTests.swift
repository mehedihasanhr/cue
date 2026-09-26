import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// The camera's answer at a moment, and the promise that it is only ever a function of
/// that moment.
///
/// This is the invariant the whole zoom feature rests on: what the frame looks like at
/// 12.400s must not depend on whether you played there from the beginning, scrubbed
/// backwards to it, or opened the project and jumped straight to it. `scale(at:)` is
/// written to make that true by construction — no state, no clock, no accumulation — and
/// until now nothing checked it.
struct ZoomEvaluatorTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func zoom(start: Double = 2, duration: Double = 4,
                      scale: Double = 3, ramp: Double = 0.5,
                      easing: Easing = .easeInOut) -> ZoomRegion {
        ZoomRegion(start: time(start), duration: time(duration), scale: scale,
                   easing: easing, transition: time(ramp))
    }

    // MARK: - Determinism

    /// Played forwards, scrubbed backwards, and jumped to at random: the same answer.
    @Test func theSameMomentAlwaysLooksTheSame() {
        let region = zoom()
        let probes = stride(from: 0.0, through: 8.0, by: 1.0 / 120).map { time($0) }

        let forwards = probes.map { region.scale(at: $0) }
        let backwards = probes.reversed().map { region.scale(at: $0) }.reversed()
        let shuffled = probes.shuffled().map { ($0, region.scale(at: $0)) }

        #expect(Array(backwards) == forwards, "direction of travel changes nothing")
        for (at, value) in shuffled {
            let index = probes.firstIndex(of: at)!
            #expect(value == forwards[index], "jumping straight there changes nothing")
        }
    }

    /// Asking twice must not drift — the evaluator holds no running total.
    @Test func askingRepeatedlyGivesTheSameAnswer() {
        let region = zoom()
        let once = region.scale(at: time(3.25))
        for _ in 0..<1_000 {
            #expect(region.scale(at: time(3.25)) == once)
        }
    }

    /// Frame rate is not part of the answer. A 24 fps export and a 60 fps preview land on
    /// different instants, and each instant has one value; sampling one grid must not
    /// change what the other grid sees.
    @Test func theCurveDoesNotDependOnTheSamplingRate() {
        let region = zoom()
        for fps in [24.0, 30.0, 60.0] {
            for frame in 0...Int(8 * fps) {
                let at = time(Double(frame) / fps)
                #expect(region.scale(at: at) == region.scale(at: at))
            }
        }
        // And a moment that exists on two grids reads the same on both.
        #expect(region.scale(at: time(1.0 / 6)) == region.scale(at: time(4.0 / 24)))
    }

    // MARK: - The shape of the movement

    @Test func aZoomIsOneOutsideItself() {
        let region = zoom()
        #expect(region.scale(at: time(0)) == 1)
        #expect(region.scale(at: time(1.99)) == 1)
        #expect(region.scale(at: time(6.01)) == 1)
        #expect(region.scale(at: time(100)) == 1)
    }

    @Test func aZoomReachesItsFullScaleAndHoldsIt() {
        let region = zoom()
        #expect(abs(region.scale(at: time(3)) - 3) < 0.001, "arrived after the ramp")
        #expect(abs(region.scale(at: time(4)) - 3) < 0.001, "and still there in the middle")
        #expect(abs(region.scale(at: time(5)) - 3) < 0.001)
    }

    /// No steps. A camera that jumps a frame is the one fault a viewer always notices.
    @Test func theMovementHasNoJumpsInIt() {
        let region = zoom()
        var previous = region.scale(at: time(1.5))
        for step in 1...(7 * 120) {
            let now = region.scale(at: time(1.5 + Double(step) / 120))
            #expect(abs(now - previous) < 0.12, "a step at \(1.5 + Double(step) / 120)")
            previous = now
        }
    }

    @Test func everyEasingStartsAtOneAndEndsAtFull() {
        for easing in Easing.allCases {
            let region = zoom(easing: easing)
            #expect(abs(region.scale(at: time(2)) - 1) < 0.001, "\(easing) starts from nothing")
            #expect(abs(region.scale(at: time(4)) - 3) < 0.001, "\(easing) arrives")
        }
    }

    /// A ramp of zero is "already there", not a division by zero — the seam a split leaves.
    @Test func aSeamlessSplitHasNoDipInIt() {
        var first = zoom(start: 2, duration: 2)
        first.transitionOut = .zero
        var second = zoom(start: 4, duration: 2)
        second.transitionIn = .zero

        #expect(abs(first.scale(at: time(3.999)) - 3) < 0.001)
        #expect(abs(second.scale(at: time(4)) - 3) < 0.001, "in at the first frame of the second half")
    }

    // MARK: - Switched off

    @Test func aDisabledZoomDoesNothingAnywhere() {
        var region = zoom()
        region.isEnabled = false
        for step in 0...800 {
            #expect(region.scale(at: time(Double(step) / 100)) == 1)
        }
    }

    /// And it keeps everything, so switching it back on restores the shot rather than
    /// asking for it to be aimed again.
    @Test func switchingAZoomBackOnRestoresIt() {
        var region = zoom()
        let framing = (region.scale, region.center, region.start, region.duration)
        region.isEnabled = false
        region.isEnabled = true
        #expect(region.scale == framing.0)
        #expect(region.center == framing.1)
        #expect(region.start == framing.2)
        #expect(region.duration == framing.3)
        #expect(abs(region.scale(at: time(4)) - 3) < 0.001)
    }

    /// Switching a suggestion off is a decision about that stretch, so a fresh run leaves
    /// it alone instead of regenerating over it.
    @Test func aDisabledSuggestionIsNotReplacedByAFreshRun() {
        var suggested = zoom(start: 2, duration: 4)
        suggested.source = .click
        suggested.isEnabled = false

        let fresh = [ZoomRegion(start: time(2), duration: time(4), source: .click)]
        let after = ZoomLane.reconciled(fresh, with: [suggested], duration: time(30))

        #expect(after.count == 1)
        #expect(after[0].id == suggested.id, "the user's decision survived the run")
        #expect(after[0].isEnabled == false)
    }

    @Test func anEnabledSuggestionIsStillReplaced() {
        var suggested = zoom(start: 2, duration: 4)
        suggested.source = .click

        let fresh = [ZoomRegion(start: time(2), duration: time(4), source: .click)]
        let after = ZoomLane.reconciled(fresh, with: [suggested], duration: time(30))

        #expect(after.count == 1)
        #expect(after[0].id != suggested.id)
    }

    // MARK: - Round trip

    @Test func beingSwitchedOffSurvivesSavingAndReopening() throws {
        var region = zoom()
        region.isEnabled = false
        region.source = .typing
        let read = try JSONDecoder().decode(ZoomRegion.self,
                                            from: JSONEncoder().encode(region))
        #expect(read.isEnabled == false)
        #expect(read.source == .typing)
    }

    /// A zoom written before the switch existed is on, because that is what it was.
    @Test func aZoomFromAnOlderProjectIsOn() throws {
        let json = #"{"id":"\#(UUID().uuidString)","start":{"value":0,"timescale":600},"duration":{"value":600,"timescale":600},"scale":2}"#
        let read = try JSONDecoder().decode(ZoomRegion.self, from: Data(json.utf8))
        #expect(read.isEnabled)
    }
}
