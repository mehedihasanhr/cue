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
