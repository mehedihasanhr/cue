import CoreGraphics
import Foundation
import Testing
@testable import RecordKit

/// Which clicks a window recording keeps: the ones made in the window while it was in front.
struct WindowPresenceTests {
    private let window = CGSize(width: 1_200, height: 800)

    @Test func aClickInTheWindowInFrontCounts() {
        #expect(CursorTracker.counts(CGPoint(x: 600, y: 400), isInFront: true, frameSize: window))
        #expect(CursorTracker.counts(CGPoint(x: 0, y: 0), isInFront: true, frameSize: window))
        #expect(CursorTracker.counts(CGPoint(x: 1_200, y: 800), isInFront: true, frameSize: window))
    }

    /// Outside the window is another app's, even with the window's app in front.
    @Test func aClickOutsideTheWindowDoesNot() {
        #expect(!CursorTracker.counts(CGPoint(x: -4, y: 400), isInFront: true, frameSize: window))
        #expect(!CursorTracker.counts(CGPoint(x: 600, y: 820), isInFront: true, frameSize: window))
        #expect(!CursorTracker.counts(CGPoint(x: 1_300, y: 10), isInFront: true, frameSize: window))
    }

    /// With another window in front, a click over where the recorded one lies landed on
    /// the one in front.
    @Test func aClickWhileTheWindowIsBehindDoesNot() {
        #expect(!CursorTracker.counts(CGPoint(x: 600, y: 400), isInFront: false, frameSize: window))
    }

    /// A display or an area keeps every click, as it always did.
    @Test func aDisplayKeepsEveryClick() {
        #expect(CursorTracker.counts(CGPoint(x: -50, y: 9_000), isInFront: true, frameSize: nil))
    }

    @Test func aPresenceSampleRoundTrips() throws {
        let sample = PresenceSample(t: 3.25, front: false)
        let data = try JSONEncoder().encode(sample)
        #expect(try JSONDecoder().decode(PresenceSample.self, from: data) == sample)
    }
}

/// Which of an app's windows counts as the one in front.
struct WindowFrontmostTests {
    private let page: (id: CGWindowID, bounds: CGRect) = (116, CGRect(x: 0, y: 121, width: 1_512, height: 861))

    /// A full-screen browser's own strips — menu bar, toolbar, the address bar's popups —
    /// lie above its page and do not make it "behind". The listing Chrome actually gave.
    @Test func aFullScreenBrowsersStripsDoNotHideItsPage() {
        let windows: [(id: CGWindowID, bounds: CGRect)] = [
            (120, CGRect(x: 0, y: 33, width: 1_512, height: 41)),
            (109, CGRect(x: 0, y: 0, width: 1_512, height: 33)),
            (108, CGRect(x: 0, y: 0, width: 1_512, height: 33)),
            (632, CGRect(x: 0, y: 33, width: 1_512, height: 124)),
            (119, CGRect(x: 0, y: 74, width: 1_512, height: 47)),
            (118, CGRect(x: 135, y: 59, width: 1_098, height: 89)),
            (117, CGRect(x: 135, y: 59, width: 1_098, height: 139)),
            page,
        ]
        #expect(WindowPresence.frontmost(116, among: windows))
    }

    /// Another of the app's windows, the size of a window, over the page: behind.
    @Test func anotherWindowOverItIsInFront() {
        let other: (id: CGWindowID, bounds: CGRect) = (300, CGRect(x: 100, y: 200, width: 1_200, height: 700))
        #expect(!WindowPresence.frontmost(116, among: [other, page]))
        // The same window elsewhere on the screen, not over it, leaves it in front.
        let aside: (id: CGWindowID, bounds: CGRect) = (301, CGRect(x: 2_000, y: 0, width: 1_200, height: 700))
        #expect(WindowPresence.frontmost(116, among: [aside, page]))
    }

    /// Not on screen — on another Space — is not in front.
    @Test func aWindowNotOnScreenIsBehind() {
        let elsewhere: [(id: CGWindowID, bounds: CGRect)] = [(300, CGRect(x: 0, y: 0, width: 800, height: 600))]
        #expect(!WindowPresence.frontmost(116, among: elsewhere))
    }
}
