import CoreGraphics
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// Smoothing the recorded pointer, and where it must not be smoothed.
///
/// The bug these exist for: a pointer that arrives somewhere and stops is a corner in the
/// path, smoothing rounds corners, and so the drawn pointer came to rest short of the
/// thing that was clicked. Anywhere else that is invisible. At a click it is the recording
/// telling the viewer the wrong thing.
struct CursorSmoothingTests {
    /// A pointer that crosses the screen and stops dead at 1s, then stays.
    private func arrival(clickAt click: Double? = nil) -> CursorTrack {
        var samples: [CursorSample] = []
        for step in 0...200 {
            let t = Double(step) / 100                      // 0…2s at 100 Hz
            let x = t < 1 ? 100 + t * 500 : 600.0           // travels, then stops
            samples.append(CursorSample(t: t, x: x, y: 300, shape: .arrow))
        }
        let input: [InputSample] = click.map { [.mouseDown(t: $0, button: 0, x: 600, y: 300)] } ?? []
        return CursorTrack(samples: samples, input: input)
    }

    private func x(_ track: CursorTrack, at time: Double) -> Double {
        Double(track.position(at: time)?.x ?? .nan)
    }

    // MARK: -

    /// The thing being fixed, stated as a test: without a click, smoothing undershoots the
    /// stop. This is the *desired* behaviour everywhere else, so it is pinned down too.
    @Test func smoothingRoundsOffAnArrival() {
        let smoothed = arrival().smoothed(0.6)
        #expect(x(smoothed, at: 1.0) < 600, "the corner is cut, which is what smoothing is")
    }

    /// The spring is clamped: it eases into a stop and never sails past it, at any amount.
    @Test func theSpringNeverOvershootsAStop() {
        for amount in [0.1, 0.5, 1.0] {
            let smoothed = arrival().smoothed(amount)
            #expect(smoothed.samples.allSatisfy { $0.x <= 600.001 }, "overshot at \(amount)")
            #expect(abs(x(smoothed, at: 2) - 600) < 1, "settled by the end at \(amount)")
        }
    }

    /// And with a click there, it is not cut.
    @Test func aClickPutsThePointerExactlyWhereItWas() {
        let smoothed = arrival(clickAt: 1.0).smoothed(0.6)
        #expect(abs(x(smoothed, at: 1.0) - 600) < 1, "within a point of the truth")
    }

    /// Heavier smoothing does not weaken the guarantee — a click is a click.
    @Test func theHeaviestSmoothingStillLandsOnTheClick() {
        let smoothed = arrival(clickAt: 1.0).smoothed(1)
        #expect(abs(x(smoothed, at: 1.0) - 600) < 1)
    }

    /// Away from the click the path is smoothed as before, so this buys accuracy where it
    /// matters without buying jitter everywhere else. "Away" starts where the spring begins
    /// to chase the click, half a second ahead of it.
    @Test func thePathAwayFromAClickIsStillSmoothed() {
        let plain = arrival().smoothed(0.6)
        let anchored = arrival(clickAt: 1.0).smoothed(0.6)
        let away = 1.0 - PointerSpring.clickLookahead - 0.05
        #expect(abs(x(plain, at: away) - x(anchored, at: away)) < 0.001)
    }

    /// Eased rather than switched, so the correction cannot itself become a jump.
    @Test func theCorrectionFadesInAndOutRatherThanSnapping() {
        let anchored = arrival(clickAt: 1.0).smoothed(0.6)
        let window = CursorTrack.clickAnchorWindow
        // Walking out from the click, the drawn path never moves more between two
        // neighbouring samples than the pointer itself did.
        var previous = x(anchored, at: 1.0)
        for step in 1...14 {
            let t = 1.0 + Double(step) / 100
            let now = x(anchored, at: t)
            #expect(abs(now - previous) < 6, "no step at \\(t)")
            previous = now
        }
        #expect(window > 0.1, "and the window is long enough to cover an approach")
    }

    @Test func aTrackWithNoClicksIsUntouched() {
        let plain = arrival().smoothed(0.6)
        let same = arrival().smoothed(0.6)
        #expect(x(plain, at: 0.5) == x(same, at: 0.5))
    }
}

/// A click is part of the pointer's path, not a second opinion about it.
///
/// The path is read on a timer and is always a little stale; a click says exactly where the
/// pointer was and exactly when. While the hand is still moving as it clicks, the two
/// differ by a few points — and the ring, drawn from the click, sat beside the pointer,
/// drawn from the path.
struct CursorClickPinningTests {
    /// A pointer crossing at 1000 pt/s, read every 10 ms and each reading 4 ms stale.
    private func crossing(clicks: [InputSample]) -> CursorTrack {
        var samples: [CursorSample] = []
        for step in 0...100 {
            let t = Double(step) / 100
            samples.append(CursorSample(t: t, x: 100 + max(0, t - 0.004) * 1_000, y: 300, shape: .pointingHand))
        }
        return CursorTrack(samples: samples, input: clicks)
    }

    @Test func thePointerPassesThroughItsOwnClick() {
        // Pressed between two readings, where the hand really was.
        let press = InputSample.mouseDown(t: 0.505, button: 0, x: 605, y: 300)
        let track = crossing(clicks: [press])
        let drawn = track.position(at: 0.505)
        #expect(abs((drawn?.x ?? 0) - 605) < 0.001)

        let unpinned = crossing(clicks: [])
        #expect(abs((unpinned.position(at: 0.505)?.x ?? 0) - 605) > 3, "without the click, the path is stale there")
    }

    @Test func smoothingKeepsItThere() {
        let press = InputSample.mouseDown(t: 0.505, button: 0, x: 605, y: 300)
        let smoothed = crossing(clicks: [press]).smoothed(0.6)
        #expect(abs((smoothed.position(at: 0.505)?.x ?? 0) - 605) < 0.5)
    }

    @Test func theReleaseIsPinnedToo() {
        let track = crossing(clicks: [.mouseDown(t: 0.505, button: 0, x: 605, y: 300),
                                      .mouseUp(t: 0.545, button: 0, x: 645, y: 300)])
        #expect(abs((track.position(at: 0.545)?.x ?? 0) - 645) < 0.001)
    }

    /// A click stamped exactly when a reading was taken replaces it rather than standing
    /// beside it: two samples at one instant would make the pointer's place there
    /// ambiguous.
    @Test func aClickAtAReadingsOwnTimeReplacesIt() {
        let track = crossing(clicks: [.mouseDown(t: 0.5, button: 0, x: 600, y: 300)])
        #expect(track.samples.filter { $0.t == 0.5 }.count == 1)
        #expect(abs((track.position(at: 0.5)?.x ?? 0) - 600) < 0.001)
    }

    @Test func thePinTakesTheShapeThePointerHad() {
        let track = crossing(clicks: [.mouseDown(t: 0.505, button: 0, x: 605, y: 300)])
        #expect(track.shape(at: 0.505) == .pointingHand)
    }

    @Test func scrollsAndKeysAreNotPlaces() {
        let track = crossing(clicks: [.scroll(t: 0.3, dx: 0, dy: 4), .key(t: 0.4, modifiers: 0)])
        #expect(track.samples.count == 101)
    }

    @Test func samplesStayInOrder() {
        let track = crossing(clicks: [.mouseDown(t: 0.905, button: 0, x: 1_005, y: 300),
                                      .mouseDown(t: 0.105, button: 0, x: 205, y: 300)])
        #expect(zip(track.samples, track.samples.dropFirst()).allSatisfy { $0.t <= $1.t })
    }
}

/// A pointer that goes away when it is left alone.
struct CursorIdleTests {
    /// Still, then moving from 3 s to 4 s, then still, then a click at 9 s.
    private var track: CursorTrack {
        var samples: [CursorSample] = []
        for step in 0...1_200 {
            let t = Double(step) / 100
            let x = t < 3 ? 100 : (t < 4 ? 100 + (t - 3) * 400 : 500)
            samples.append(CursorSample(t: t, x: x, y: 200, shape: .arrow))
        }
        return CursorTrack(samples: samples, input: [.mouseDown(t: 9, button: 0, x: 500, y: 200),
                                                     .mouseUp(t: 9.05, button: 0, x: 500, y: 200)])
    }

    @Test func movementAndClicksAreActivity() {
        let activity = track.activity
        #expect(activity.count == 2)
        #expect(abs(activity[0].lowerBound - 3) < 0.02)
        #expect(abs(activity[0].upperBound - 4) < 0.02)
        #expect(abs(activity[1].lowerBound - 9) < 0.001)
    }

    @Test func thePointerIsThereWhileItIsInUse() {
        #expect(track.idleOpacity(at: 3.5, after: 2) == 1)
        #expect(track.idleOpacity(at: 9.02, after: 2) == 1)
    }

    /// Still for less than the delay: still there.
    @Test func itStaysForTheLengthOfTheDelay() {
        #expect(track.idleOpacity(at: 5.5, after: 2) == 1)
    }

    @Test func thenItFades() {
        let going = track.idleOpacity(at: 6.2, after: 2)
        #expect(going > 0 && going < 1)
        #expect(track.idleOpacity(at: 7, after: 2) == 0)
    }

    /// It is back before the movement begins, not part of the way through it.
    @Test func itComesBackBeforeItMoves() {
        let track = track
        #expect(track.idleOpacity(at: 8.7, after: 2) == 0)
        let arriving = track.idleOpacity(at: 8.9, after: 2)
        #expect(arriving > 0 && arriving < 1)
        #expect(track.idleOpacity(at: 9, after: 2) == 1)
    }

    /// A short hesitation in a movement is not the pointer coming to rest.
    @Test func aHesitationIsNotRest() {
        var samples: [CursorSample] = []
        for step in 0...300 {
            let t = Double(step) / 100
            // Moves, stops for a fifth of a second at 1 s, moves again.
            let x = t < 1 ? t * 100 : (t < 1.2 ? 100 : 100 + (t - 1.2) * 100)
            samples.append(CursorSample(t: t, x: x, y: 0, shape: .arrow))
        }
        #expect(CursorTrack(samples: samples).activity.count == 1)
    }

    @Test func aPointerNobodyTouchedGoesAfterTheDelay() {
        let samples = (0...500).map { CursorSample(t: Double($0) / 100, x: 10, y: 10, shape: .arrow) }
        let track = CursorTrack(samples: samples)
        #expect(track.activity.isEmpty)
        #expect(track.idleOpacity(at: 1, after: 2) == 1)
        #expect(track.idleOpacity(at: 4, after: 2) == 0)
    }

    /// Smoothing spreads a movement out in time. When the pointer is *in use* is a fact
    /// about the hand, so it is kept as it was recorded.
    @Test func smoothingDoesNotChangeWhenThePointerWasInUse() {
        let track = track
        #expect(track.smoothed(0.8).activity == track.activity)
    }

    @Test func playingToAMomentAndScrubbingToItAgree() {
        let track = track
        let forwards = stride(from: 0.0, through: 12, by: 0.25).map { track.idleOpacity(at: $0, after: 2) }
        let backwards = stride(from: 12.0, through: 0, by: -0.25).map { track.idleOpacity(at: $0, after: 2) }
        #expect(forwards == Array(backwards.reversed()))
    }
}

/// A shape the pointer held for only an instant is a flicker, not information.
struct CursorShapeSteadinessTests {
    /// An arrow that is an I-beam for 50 ms at 1 s, and a hand from 2 s on.
    private var track: CursorTrack {
        let samples = (0...300).map { step -> CursorSample in
            let t = Double(step) / 100
            let shape: CursorShape = t >= 2 ? .pointingHand : (t >= 1 && t < 1.05 ? .iBeam : .arrow)
            return CursorSample(t: t, x: 0, y: 0, shape: shape)
        }
        return CursorTrack(samples: samples)
    }

    @Test func aFlickerIsPassedOver() {
        #expect(track.shape(at: 1.02) == .iBeam, "it was recorded")
        #expect(track.steadyShape(at: 1.02) == .arrow, "and it is not drawn")
    }

    @Test func aShapeThatLastsIsKept() {
        #expect(track.steadyShape(at: 0.5) == .arrow)
        #expect(track.steadyShape(at: 2.5) == .pointingHand)
    }

    @Test func theChangeHappensWhenItDid() {
        #expect(track.steadyShape(at: 1.99) == .arrow)
        #expect(track.steadyShape(at: 2.0) == .pointingHand)
    }

    @Test func smoothingKeepsTheShapes() {
        #expect(track.smoothed(0.6).steadyShape(at: 1.02) == .arrow)
        #expect(track.smoothed(0.6).steadyShape(at: 2.5) == .pointingHand)
    }

    @Test func anEmptyTrackIsAnArrow() {
        #expect(CursorTrack(samples: []).steadyShape(at: 1) == .arrow)
    }
}

/// Pointer settings added after projects already existed.
struct CursorStyleCompatibilityTests {
    /// A project written before these settings draws the pointer it always drew.
    @Test func anOlderProjectKeepsItsLook() throws {
        let older = #"{"isVisible":true,"scale":1.4,"smoothing":0.6,"clickEffect":true,"motionBlur":false}"#
        let style = try JSONDecoder().decode(CursorStyle.self, from: Data(older.utf8))
        #expect(!style.hidesWhenIdle)
        #expect(!style.alwaysArrow)
        #expect(!style.steadiesShape)
        #expect(style.clickStyle == .ring)
        #expect(style.idleDelay == 2)
    }

    @Test func aNewProjectSteadiesThePointersShape() {
        #expect(CursorStyle().steadiesShape)
    }

    @Test func theSettingsSurviveBeingSaved() throws {
        var style = CursorStyle()
        style.hidesWhenIdle = true
        style.idleDelay = 3.5
        style.alwaysArrow = true
        style.clickStyle = .ripple
        let back = try JSONDecoder().decode(CursorStyle.self, from: JSONEncoder().encode(style))
        #expect(back == style)
    }

    @Test(arguments: [-4.0, 0, 900, .nan, .infinity])
    func aDelayThatCannotBeRightIsBroughtIntoRange(_ delay: Double) throws {
        let json = #"{"idleDelay":\#(delay.isFinite ? String(delay) : "1e999")}"#
        let style = (try? JSONDecoder().decode(CursorStyle.self, from: Data(json.utf8))) ?? CursorStyle(idleDelay: delay.isFinite ? delay : 2)
        #expect(CursorStyle.idleDelayRange.contains(style.idleDelay))
    }

    // MARK: - Shakes

    /// A reading that jumps far away and straight back is dropped; ordinary movement,
    /// however fast, is kept, and so is a click.
    @Test func aShakeIsDroppedAndMovementKept() {
        var samples: [CursorSample] = []
        for step in 0..<20 {
            samples.append(CursorSample(t: Double(step) / 60, x: 100 + Double(step) * 10, y: 100, shape: .arrow))
        }
        samples[8].x = 1_400                                  // a one-reading jump
        let shaken = CursorTrack(samples: samples)
        let steady = shaken.withoutShakes(threshold: 500)
        #expect(steady.samples.count == 19)
        #expect(!steady.samples.contains { $0.x == 1_400 })

        let clicked = CursorTrack(samples: samples,
                                  input: [.mouseDown(t: samples[8].t, button: 0, x: 1_400, y: 100)])
        #expect(clicked.withoutShakes(threshold: 500).samples.contains { $0.x == 1_400 }, "a click stays")
    }

    @Test func aStyleWithoutShakeRemovalLeavesThePathAlone() {
        let track = CursorTrack(samples: (0..<60).map {
            CursorSample(t: Double($0) / 60, x: 100 + Double($0) * 5, y: 300, shape: .arrow)
        })
        var style = CursorStyle(smoothing: 0)
        #expect(track.prepared(for: style).samples == track.samples)
        style.removesShakes = true
        #expect(track.prepared(for: style).samples == track.samples, "nothing in it is a shake")
    }

    @Test func anOldProjectHasShakesLeftIn() throws {
        let style = try JSONDecoder().decode(CursorStyle.self, from: Data(#"{"scale":2}"#.utf8))
        #expect(style.removesShakes == false)
        #expect(style.shakeThreshold == 500)
    }
}
