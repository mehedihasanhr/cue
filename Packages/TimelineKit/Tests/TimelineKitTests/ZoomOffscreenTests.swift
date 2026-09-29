import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// Only what happened inside the recording becomes a zoom.
///
/// The pointer is watched wherever it goes, because it has to be: a recording of one
/// window still needs the pointer's whole path to draw it, and a click on the menu bar or
/// on a window beside the one being filmed is part of what the person did. It is not part
/// of what the viewer will see — and a zoom aimed off the edge is pulled back to the edge
/// by the framing clamp, because it has to point *somewhere*, producing a shot of a corner
/// nothing happened in.
struct ZoomOffscreenTests {
    /// A window recording: 1200 × 800 points of Chrome, with a whole desktop around it.
    private let frame = CGSize(width: 1_200, height: 800)

    private func suggester() -> ZoomSuggester { ZoomSuggester(frameSize: frame) }

    private func click(_ t: Double, _ x: Double, _ y: Double) -> InputSample {
        .mouseDown(t: t, button: 0, x: x, y: y)
    }

    private func focus(_ kind: FocusSample.Kind, at t: Double, _ rect: CGRect) -> FocusSample {
        FocusSample(t: t, kind: kind, rect: rect)
    }

    private func zooms(clicks: [InputSample] = [], focus: [FocusSample] = []) -> [ZoomRegion] {
        suggester().suggestions(cursor: [], input: clicks, focus: focus,
                                duration: CMTime(seconds: 60, preferredTimescale: 600))
    }

    // MARK: - Clicks

    /// Clicking another window while recording this one is not a moment in this recording.
    @Test func aClickOutsideTheRecordedWindowIsNotAZoom() {
        #expect(zooms(clicks: [click(5, -260, 400)]).isEmpty, "to the left of the window")
        #expect(zooms(clicks: [click(5, 1_500, 400)]).isEmpty, "to the right of it")
        #expect(zooms(clicks: [click(5, 600, -40)]).isEmpty, "the menu bar above it")
        #expect(zooms(clicks: [click(5, 600, 980)]).isEmpty, "the Dock below it")
    }

    /// And it does not drag a real moment off target either: a click inside and one
    /// outside are one click's worth of evidence, aimed where the real one landed.
    @Test func anOutsideClickDoesNotMoveARealOne() {
        let zooms = zooms(clicks: [click(5, 900, 200), click(5.6, -300, 200)])
        #expect(zooms.count == 1)
        #expect((zooms.first?.center.x ?? 0) > 0.6, "still pointed at the right-hand side")
    }

    @Test func clicksJustInsideTheEdgeStillCount() {
        #expect(!zooms(clicks: [click(5, 2, 2)]).isEmpty)
        #expect(!zooms(clicks: [click(5, 1_198, 798)]).isEmpty)
    }

    /// A recording with nothing but outside clicks suggests nothing, rather than a pile of
    /// zooms at the corners.
    @Test func aRecordingOfClicksElsewhereSuggestsNothing() {
        let elsewhere = (0..<6).map { click(3 + Double($0) * 2, -400 - Double($0) * 10, 300) }
        #expect(zooms(clicks: elsewhere).isEmpty)
    }

    // MARK: - Focus

    /// Focus following another app is the same story: a window recording watches the
    /// frontmost window, which is not always the window being recorded.
    @Test func focusInAnotherWindowIsNotAZoom() {
        var tuning = ZoomSuggester.Tuning()
        tuning.followsWindows = true
        let suggester = ZoomSuggester(frameSize: frame, tuning: tuning)
        let away = CGRect(x: 1_400, y: 100, width: 500, height: 300)
        let zooms = suggester.suggestions(cursor: [], input: [],
                                          focus: [focus(.window, at: 5, away)],
                                          duration: CMTime(seconds: 60, preferredTimescale: 600))
        #expect(zooms.isEmpty)
    }

    /// A field half off the edge is framed on the half that was filmed, not on a midpoint
    /// that is partly outside the picture.
    @Test func aFieldHalfOutsideIsFramedOnTheHalfThatWasRecorded() {
        let straddling = CGRect(x: 1_000, y: 380, width: 400, height: 30)
        let zooms = zooms(focus: [focus(.field, at: 5, straddling)])
        let zoom = try? #require(zooms.first)

        // The visible half spans 1000…1200 of 1200 — the right-hand edge. The shot is
        // aimed there and then pulled inside the picture, so what is asserted is the thing
        // that matters: the filmed half of the field is in the shot, and the shot is in
        // the picture. Aimed at the whole field's midpoint it would have been centred at
        // 1200 of 1200, half of it on canvas that was never recorded.
        let centre = zoom?.center.x ?? 0
        let half = 0.5 / (zoom?.scale ?? 1)
        #expect(centre + half <= 1.0001, "the shot reaches off the right")
        #expect(centre - half <= 1_000 / 1_200, "the filmed part of the field is outside the shot")
        #expect(centre > 0.6, "and it is still about the right-hand side")
    }

    @Test func aFieldInsideTheWindowIsUntouched() {
        let field = CGRect(x: 400, y: 380, width: 400, height: 30)
        let zooms = zooms(focus: [focus(.field, at: 5, field)])
        #expect(abs((zooms.first?.center.x ?? 0) - 0.5) < 0.01)
    }
}
