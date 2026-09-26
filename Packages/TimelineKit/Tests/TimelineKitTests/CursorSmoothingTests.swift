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
    /// matters without buying jitter everywhere else.
    @Test func thePathAwayFromAClickIsStillSmoothed() {
        let plain = arrival().smoothed(0.6)
        let anchored = arrival(clickAt: 1.0).smoothed(0.6)
        let away = 1.0 - CursorTrack.clickAnchorWindow - 0.05
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
