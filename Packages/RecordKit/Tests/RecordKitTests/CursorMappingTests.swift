import CoreGraphics
import Foundation
import Testing
@testable import RecordKit

/// Turning a pointer position on the desk into a position inside the frame.
///
/// The arithmetic is a subtraction, and it was never the hard part. What was wrong was
/// the number being subtracted: the recorder asked `SCContentFilter.contentRect` where the
/// recorded area was, and that answers zero — it describes how big the content is, not
/// where on the desk it sits. Subtracting zero is right for a recording of the main
/// display and wrong by a whole display, or a whole window, for everything else.
///
/// So these check the subtraction against containers that are *not* at the origin, which
/// is the only case that can tell a correct translation from a missing one.
struct CursorMappingTests {
    private let secondDisplay = CGRect(x: 1_920, y: 0, width: 2_560, height: 1_440)
    private let mainDisplay = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

    // MARK: - Where the recorded corner is

    @Test func recordingTheMainDisplayStartsAtTheCorner() {
        #expect(CaptureTarget.display(1).origin(inside: mainDisplay) == .zero)
    }

    /// The case a single-display Mac can never show: every sample on the second display
    /// used to be out by the first display's width.
    @Test func recordingASecondDisplayStartsWhereThatDisplayDoes() {
        #expect(CaptureTarget.display(2).origin(inside: secondDisplay) == CGPoint(x: 1_920, y: 0))
    }

    @Test func recordingAnAreaStartsAtTheAreasOwnCorner() {
        let area = CaptureTarget.area(display: 1, rect: CGRect(x: 300, y: 200, width: 640, height: 480))
        #expect(area.origin(inside: mainDisplay) == CGPoint(x: 300, y: 200))
    }

    /// Both offsets at once — an area on a display that is not the main one.
    @Test func anAreaOnASecondDisplayCountsBothOffsets() {
        let area = CaptureTarget.area(display: 2, rect: CGRect(x: 300, y: 200, width: 640, height: 480))
        #expect(area.origin(inside: secondDisplay) == CGPoint(x: 2_220, y: 200))
    }

    @Test func recordingAWindowStartsAtTheWindowsCorner() {
        let window = CGRect(x: 412, y: 233, width: 1_280, height: 800)
        #expect(CaptureTarget.window(7).origin(inside: window) == CGPoint(x: 412, y: 233))
    }

    // MARK: - The translation

    @Test func aPointerPositionBecomesAPositionInsideTheFrame() {
        let mapper = CursorMapper(origin: CGPoint(x: 1_920, y: 0))
        #expect(mapper.map(CGPoint(x: 1_920, y: 0)) == .zero, "the recorded corner is the frame's corner")
        #expect(mapper.map(CGPoint(x: 2_000, y: 40)) == CGPoint(x: 80, y: 40))
    }

    /// A pointer that is not over the recorded area maps outside it, rather than being
    /// clamped to an edge. The renderer drops what falls outside the frame, and a pointer
    /// pinned to the edge of the picture would be a pointer that is drawn as though it were
    /// in the recording when it is on another screen entirely.
    @Test func aPointerOutsideTheRecordedAreaMapsOutsideIt() {
        let mapper = CursorMapper(origin: CGPoint(x: 1_920, y: 0))
        let mapped = mapper.map(CGPoint(x: 10, y: 10))
        #expect(mapped.x < 0)
    }

    @Test func mappingIsAnIdentityWhenTheRecordedAreaIsTheCorner() {
        let mapper = CursorMapper(origin: .zero)
        #expect(mapper.map(CGPoint(x: 640, y: 480)) == CGPoint(x: 640, y: 480))
    }

    /// A window that is dragged while it is being recorded: the picture does not move,
    /// because ScreenCaptureKit follows the window, so the translation has to move with it
    /// or the drawn pointer drifts by the length of the drag.
    ///
    /// `refresh()` is what re-reads it during a recording, from the window server. Here the
    /// point is only that the mapper reads the origin each time rather than capturing it —
    /// a struct that copied the origin into every sample could not be corrected at all.
    @Test func theTranslationCanFollowAWindowThatMoves() {
        let mapper = CursorMapper(origin: CGPoint(x: 100, y: 100))
        #expect(mapper.map(CGPoint(x: 150, y: 150)) == CGPoint(x: 50, y: 50))
        mapper.move(to: CGPoint(x: 400, y: 300))
        #expect(mapper.map(CGPoint(x: 450, y: 350)) == CGPoint(x: 50, y: 50),
                "the same spot in the window is the same spot in the frame")
    }

    /// Nothing to follow means nothing to re-read: a display does not move, and refreshing
    /// one must not reset the origin it was given.
    @Test func refreshingADisplaysMappingLeavesItAlone() {
        let mapper = CursorMapper(origin: CGPoint(x: 1_920, y: 0))
        mapper.refresh()
        #expect(mapper.origin == CGPoint(x: 1_920, y: 0))
    }
}
