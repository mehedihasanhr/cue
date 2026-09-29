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

    // MARK: - A window the frame had to shrink

    /// The take that found this: a full-screen browser, 1512 × 950 points, recorded into a
    /// file sized for 1512 × 861. ScreenCaptureKit shrank the picture to 0.906 of itself to
    /// fit, and the pointer was written down as though it had not — so a click on a link
    /// 400 points down the page was drawn 40 points below it.
    private let shrunk = FrameGeometry(screenRect: CGRect(x: 0, y: 32, width: 1_512, height: 950),
                                       contentRect: CGRect(x: 0, y: 0, width: 1_371, height: 861),
                                       contentScale: 861.0 / 950.0,
                                       scaleFactor: 2)

    @Test func aShrunkWindowShrinksThePointerWithIt() {
        let mapper = CursorMapper(origin: .zero, following: 7, outputScale: 2)
        mapper.place(shrunk)
        let mapped = mapper.map(CGPoint(x: 400, y: 32 + 400))
        #expect(abs(mapped.x - 400 * 861 / 950) < 0.001)
        #expect(abs(mapped.y - 400 * 861 / 950) < 0.001)
        #expect(mapper.map(CGPoint(x: 0, y: 32)) == .zero, "the window's corner is still the frame's corner")
    }

    /// The window server's origin for that window was the one it had before it went full
    /// screen, 90 points lower. The frame knows better, and a refresh must not undo it.
    @Test func theFramesSayWhereTheWindowIsAndARefreshDoesNotOverruleThem() {
        let mapper = CursorMapper(origin: CGPoint(x: 0, y: 121), following: 7, outputScale: 2)
        mapper.place(shrunk)
        mapper.refresh()
        #expect(mapper.origin == CGPoint(x: 0, y: 32))
    }

    /// A frame from a standard-density display, into a file made at 2×: one point of the
    /// window is one pixel, and so half a point of the frame.
    @Test func aOneXFrameInATwoXFileMapsAtHalfScale() {
        let mapper = CursorMapper(origin: .zero, following: 7, outputScale: 2)
        mapper.place(FrameGeometry(screenRect: CGRect(x: -1_600, y: 0, width: 800, height: 600),
                                   contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                                   contentScale: 1, scaleFactor: 1))
        #expect(mapper.map(CGPoint(x: -1_200, y: 300)) == CGPoint(x: 200, y: 150))
    }

    /// Letterboxed content is placed away from the corner; the pointer follows it there.
    @Test func contentPlacedAwayFromTheCornerCarriesThePointerWithIt() {
        let mapper = CursorMapper(origin: .zero, following: 7, outputScale: 2)
        mapper.place(FrameGeometry(screenRect: CGRect(x: 0, y: 0, width: 1_000, height: 500),
                                   contentRect: CGRect(x: 20, y: 0, width: 1_000, height: 500),
                                   contentScale: 1, scaleFactor: 2))
        #expect(mapper.map(CGPoint(x: 100, y: 100)) == CGPoint(x: 120, y: 100))
    }

    /// A frame that cannot place itself leaves the last good answer alone.
    @Test func aFrameWithNoSizeIsIgnored() {
        let mapper = CursorMapper(origin: CGPoint(x: 50, y: 50), following: 7, outputScale: 2)
        mapper.place(FrameGeometry(screenRect: .zero, contentRect: .zero, contentScale: 1, scaleFactor: 2))
        #expect(mapper.map(CGPoint(x: 60, y: 60)) == CGPoint(x: 10, y: 10))
    }

    /// Focus rectangles are sizes as well as corners; a shrunk picture shrinks them too.
    @Test func aRectangleIsScaledAsWellAsMoved() {
        let mapper = CursorMapper(origin: .zero, following: 7, outputScale: 2)
        mapper.place(FrameGeometry(screenRect: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
                                   contentRect: CGRect(x: 0, y: 0, width: 500, height: 500),
                                   contentScale: 0.5, scaleFactor: 2))
        #expect(mapper.map(CGRect(x: 100, y: 100, width: 200, height: 80))
                == CGRect(x: 50, y: 50, width: 100, height: 40))
    }

    /// Chrome in full screen, as it was when this was found. The window that is picked is
    /// only the page, 1512 × 861 at y = 121; the tab strip and toolbar are separate windows
    /// above it from y = 33, and the capture takes them too. Measured from the page's own
    /// corner every pointer was 88 points too high — a click on a link drawn a line above
    /// it. Measured from where the frame says the picture starts, it lands on the link.
    @Test func aFullScreenWindowIsMeasuredFromWhereItsPictureStarts() {
        let mapper = CursorMapper(origin: CGPoint(x: 0, y: 121), following: 112, outputScale: 2)
        let scale = 861.0 / 949.0
        mapper.place(FrameGeometry(screenRect: CGRect(x: 0, y: 33, width: 1_512, height: 949),
                                   contentRect: CGRect(x: 0, y: 0, width: 1_512 * scale, height: 861),
                                   contentScale: scale,
                                   scaleFactor: 2))
        // A link 500 points down the page, which is 588 down the picture.
        let mapped = mapper.map(CGPoint(x: 612, y: 121 + 500))
        #expect(abs(mapped.x - 612 * scale) < 0.001)
        #expect(abs(mapped.y - (88 + 500) * scale) < 0.001)
    }

    /// The same take, if the frame reports only the page's own rectangle: the content is
    /// 88 points taller than that, and the extra is the toolbar above it.
    @Test func contentTallerThanTheReportedWindowStartsAboveIt() {
        let mapper = CursorMapper(origin: CGPoint(x: 0, y: 121), following: 112, outputScale: 2)
        let scale = 861.0 / 949.0
        mapper.place(FrameGeometry(screenRect: CGRect(x: 0, y: 121, width: 1_512, height: 861),
                                   contentRect: CGRect(x: 0, y: 0, width: 1_512 * scale, height: 861),
                                   contentScale: scale,
                                   scaleFactor: 2))
        #expect(abs(mapper.origin.y - 33) < 0.001)
        let mapped = mapper.map(CGPoint(x: 612, y: 121 + 500))
        #expect(abs(mapped.y - (88 + 500) * scale) < 0.001)
    }
}
