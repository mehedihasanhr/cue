import CoreGraphics
import Testing
@testable import Cue

/// Chrome's frames are as read from a full-screen Chrome, turned to AppKit coordinates
/// on a 982-point-high screen.
struct WindowPieceTests {
    private func window(_ id: CGWindowID, _ owner: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> WindowInfo {
        WindowInfo(id: id, ownerName: owner, title: "", frame: CGRect(x: x, y: y, width: w, height: h))
    }

    private var chrome: [WindowInfo] {
        [window(1, "Google Chrome", 0, 908, 1512, 41),  // tab strip
         window(2, "Google Chrome", 0, 861, 1512, 47),  // toolbar
         window(3, "Google Chrome", 0, 0, 1512, 861)]   // page
    }

    @Test func aFullScreenBrowsersPartsArePieces() {
        for id: CGWindowID in [1, 2, 3] { #expect(WindowDetector.isPiece(id, of: chrome)) }
    }

    @Test func aBarInsideItsWindowIsAPiece() {
        let term = [window(1, "WezTerm", 0, 0, 1512, 949), window(2, "WezTerm", 0, 905, 1512, 44)]
        #expect(WindowDetector.isPiece(2, of: term))
        #expect(!WindowDetector.isPiece(1, of: term))
    }

    @Test func ordinaryWindowsAreNotPieces() {
        let lone = [window(1, "Finder", 100, 100, 800, 600)]
        #expect(!WindowDetector.isPiece(1, of: lone))
        let cascaded = [window(1, "Finder", 100, 100, 800, 600), window(2, "Finder", 140, 60, 800, 600)]
        #expect(!WindowDetector.isPiece(1, of: cascaded))
        #expect(!WindowDetector.isPiece(2, of: cascaded))
        let apart = [window(1, "Finder", 0, 0, 400, 400), window(2, "Finder", 500, 0, 400, 400)]
        #expect(!WindowDetector.isPiece(1, of: apart))
    }

    @Test func anotherAppTouchingDoesNotCount() {
        let tiled = [window(1, "Safari", 0, 0, 756, 900), window(2, "Notes", 756, 0, 756, 900)]
        #expect(!WindowDetector.isPiece(1, of: tiled))
    }

    @Test func aWindowThatHasGoneIsNotAPiece() {
        #expect(!WindowDetector.isPiece(9, of: chrome))
    }
}
