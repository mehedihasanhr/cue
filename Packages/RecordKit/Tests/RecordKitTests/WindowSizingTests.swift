import CoreGraphics
import Foundation
import Testing
@testable import RecordKit

/// Putting a window at a preset size before recording it: where it goes, and which window
/// it is. The Accessibility call that moves it is not tested here, and must not be.
@Suite("Window sizing")
struct WindowSizingTests {
    /// A 1512 × 982 Retina laptop: a 37-point menu bar, no Dock at the bottom.
    private let laptop = CGRect(x: 0, y: 37, width: 1_512, height: 945)

    @Test func aPresetIsTheRecordingsPixelsNotTheWindowsPoints() throws {
        let plan = try #require(WindowSizing.frame(for: .hd1080, window: CGRect(x: 100, y: 100, width: 700, height: 500),
                                                   visibleFrame: laptop, backingScale: 2))
        #expect(plan.frame.size == CGSize(width: 960, height: 540))
        #expect(!plan.isShrunk)
        let flat = try #require(WindowSizing.frame(for: .hd720, window: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                   visibleFrame: CGRect(x: 0, y: 25, width: 1_920, height: 1_055),
                                                   backingScale: 1))
        #expect(flat.frame.size == CGSize(width: 1_280, height: 720))
    }

    @Test func theWindowKeepsItsCornerWhenTheSizeFitsThere() throws {
        let plan = try #require(WindowSizing.frame(for: .hd720, window: CGRect(x: 200, y: 150, width: 900, height: 700),
                                                   visibleFrame: laptop, backingScale: 2))
        #expect(plan.frame.origin == CGPoint(x: 200, y: 150))
    }

    @Test func aWindowThatWouldHangOffTheScreenIsMovedOnToIt() throws {
        let plan = try #require(WindowSizing.frame(for: .hd1080, window: CGRect(x: 1_200, y: 800, width: 200, height: 100),
                                                   visibleFrame: laptop, backingScale: 2))
        #expect(plan.frame.maxX <= laptop.maxX)
        #expect(plan.frame.maxY <= laptop.maxY)
        #expect(plan.frame.size == CGSize(width: 960, height: 540))
        // And under the menu bar, never behind it.
        let high = try #require(WindowSizing.frame(for: .square, window: CGRect(x: 10, y: 0, width: 50, height: 50),
                                                   visibleFrame: laptop, backingScale: 2))
        #expect(high.frame.minY == laptop.minY)
    }

    @Test func aSizeTooBigForTheScreenKeepsItsShape() throws {
        // Upright 1080 × 1920 on a screen with one pixel to the point: far too tall.
        let screen = CGRect(x: 0, y: 25, width: 1_920, height: 1_055)
        let plan = try #require(WindowSizing.frame(for: .vertical, window: CGRect(x: 300, y: 300, width: 800, height: 600),
                                                   visibleFrame: screen, backingScale: 1))
        #expect(plan.isShrunk)
        #expect(plan.frame.height <= screen.height)
        #expect(plan.frame.minY >= screen.minY)
        #expect(abs(plan.frame.width / plan.frame.height - 1_080.0 / 1_920) < 0.002)
        #expect(plan.frame.width == plan.frame.width.rounded(), "whole points")
    }

    @Test func fitToDisplayIsTheUsableArea() throws {
        let plan = try #require(WindowSizing.frame(for: .fitDisplay, window: CGRect(x: 5, y: 60, width: 300, height: 200),
                                                   visibleFrame: laptop, backingScale: 2))
        #expect(plan.frame == laptop)
        #expect(!plan.isShrunk)
    }

    @Test func noScreenIsNoPlan() {
        #expect(WindowSizing.frame(for: .hd720, window: .zero, visibleFrame: .zero, backingScale: 2) == nil)
    }

    @Test func aNonsenseScaleIsTakenAsOne() throws {
        let plan = try #require(WindowSizing.frame(for: .hd720, window: .zero,
                                                   visibleFrame: CGRect(x: 0, y: 0, width: 3_000, height: 2_000),
                                                   backingScale: .nan))
        #expect(plan.frame.size == CGSize(width: 1_280, height: 720))
    }

    @Test func everyPresetHasANameAndAllButOneASize() {
        for preset in WindowSizePreset.allCases {
            #expect(!preset.title.isEmpty)
            #expect(!preset.subtitle.isEmpty)
            #expect((preset.pixels == nil) == (preset == .fitDisplay))
        }
    }

    // MARK: - Which window

    @Test func theWindowIsFoundByWhereItIs() {
        let candidates = [WindowSizing.Candidate(frame: CGRect(x: 0, y: 40, width: 600, height: 400), title: "Inbox"),
                          WindowSizing.Candidate(frame: CGRect(x: 300, y: 200, width: 800, height: 600), title: "Draft")]
        #expect(WindowSizing.match(CGRect(x: 300, y: 200, width: 800, height: 600), title: nil, among: candidates) == 1)
        // A point of rounding between the two accounts is the same window.
        #expect(WindowSizing.match(CGRect(x: 301, y: 199, width: 799, height: 601), title: "Draft", among: candidates) == 1)
    }

    @Test func twoWindowsInOnePlaceAreToldApartByTitle() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let candidates = [WindowSizing.Candidate(frame: frame, title: "One"),
                          WindowSizing.Candidate(frame: frame, title: "Two")]
        #expect(WindowSizing.match(frame, title: "Two", among: candidates) == 1)
        #expect(WindowSizing.match(frame, title: "One", among: candidates) == 0)
        // A title neither has is still one of them: they are both where the window is.
        #expect(WindowSizing.match(frame, title: "Three", among: candidates) != nil)
    }

    @Test func nothingCloseEnoughIsNoMatchRatherThanTheNearest() {
        let candidates = [WindowSizing.Candidate(frame: CGRect(x: 0, y: 40, width: 600, height: 400), title: "Inbox")]
        #expect(WindowSizing.match(CGRect(x: 20, y: 40, width: 600, height: 400), title: "Inbox", among: candidates) == nil)
        #expect(WindowSizing.match(.zero, title: nil, among: []) == nil)
    }

    // MARK: - Which screen, and which way up

    @Test func appKitsScreenRectanglesAreTurnedTheRightWayUp() {
        // The main display is 982 high; a Dock-less visible frame under a 37-point bar.
        let cocoa = CGRect(x: 0, y: 0, width: 1_512, height: 945)
        #expect(WindowSizing.topLeft(cocoa, mainHeight: 982) == CGRect(x: 0, y: 37, width: 1_512, height: 945))
        // A second display above the main one has a negative top.
        let above = CGRect(x: 0, y: 982, width: 1_920, height: 1_080)
        #expect(WindowSizing.topLeft(above, mainHeight: 982).minY == -1_080)
    }

    @Test func aWindowIsOnTheScreenHoldingMostOfIt() {
        let screens = [CGRect(x: 0, y: 0, width: 1_512, height: 982),
                       CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080)]
        #expect(WindowSizing.screen(for: CGRect(x: 1_400, y: 100, width: 600, height: 400), among: screens) == 1)
        #expect(WindowSizing.screen(for: CGRect(x: 100, y: 100, width: 600, height: 400), among: screens) == 0)
        #expect(WindowSizing.screen(for: CGRect(x: 5_000, y: 100, width: 10, height: 10), among: screens) == 1, "nearest")
        #expect(WindowSizing.screen(for: .zero, among: []) == nil)
    }
}
