import CoreGraphics
import Foundation
import Testing
@testable import RecordKit

/// The flip between the window server's coordinates and AppKit's.
///
/// Tested rather than trusted because this project has already shipped one bug of exactly
/// this kind — an anchor read top-down and applied bottom-up, mirroring every off-centre
/// zoom — and because the symptom on a single laptop screen is subtle enough to survive a
/// lot of looking.
struct DisplayGeometryTests {
    /// A 1080-tall primary display, which is what `primaryMaxY` is measured against.
    private let primary: CGFloat = 1080

    @Test func aWindowAtTheTopOfTheScreenIsAtTheTopInBothConventions() {
        // Window server: origin at the top, so y = 0 is the top edge.
        let atTop = CGRect(x: 100, y: 0, width: 400, height: 300)
        let flipped = DisplayGeometry.appKit(atTop, primaryMaxY: primary)
        // AppKit: the top edge is maxY, which must now be the screen's own top.
        #expect(flipped.maxY == primary)
        #expect(flipped.minY == primary - 300)
        #expect(flipped.minX == 100, "x never moves")
        #expect(flipped.size == atTop.size, "a flip is not a resize")
    }

    @Test func aWindowAtTheBottomLandsAtZero() {
        let atBottom = CGRect(x: 0, y: 780, width: 400, height: 300)
        #expect(DisplayGeometry.appKit(atBottom, primaryMaxY: primary).minY == 0)
    }

    /// The property that makes it a flip: doing it twice gets you back.
    @Test(arguments: [0.0, 120.0, 540.0, 900.0])
    func flippingTwiceIsWhereYouStarted(y: Double) {
        let frame = CGRect(x: 40, y: y, width: 320, height: 180)
        let there = DisplayGeometry.appKit(frame, primaryMaxY: primary)
        let back = DisplayGeometry.windowServer(there, primaryMaxY: primary)
        #expect(back == frame)
    }

    /// A window on a display sitting *above* the primary one has a negative y in the
    /// window server's space, and must come out above the primary in AppKit's.
    @Test func aDisplayAboveThePrimaryStaysAbove() {
        let onSecond = CGRect(x: 0, y: -900, width: 400, height: 300)
        let flipped = DisplayGeometry.appKit(onSecond, primaryMaxY: primary)
        #expect(flipped.minY > primary, "above the primary display, not below it")
    }

    /// The mistake the doc comment warns about: measuring against the wrong screen's
    /// height puts the rectangle out by exactly the difference.
    @Test func measuringAgainstTheWrongScreenIsOutByTheDifference() {
        let frame = CGRect(x: 0, y: 200, width: 100, height: 100)
        let right = DisplayGeometry.appKit(frame, primaryMaxY: primary)
        let wrong = DisplayGeometry.appKit(frame, primaryMaxY: 1440)
        #expect(wrong.minY - right.minY == 360)
    }
}
