import Foundation
import Testing
@testable import TimelineKit

/// What each of the J, K and L keys does, as a table.
struct PlaybackShuttleTests {
    @Test func theForwardKeyPlaysThenGoesFasterUpToALimit() {
        #expect(PlaybackShuttle.rate(after: .forward, running: nil) == 1)
        #expect(PlaybackShuttle.rate(after: .forward, running: 1) == 2)
        #expect(PlaybackShuttle.rate(after: .forward, running: 2) == 4)
        #expect(PlaybackShuttle.rate(after: .forward, running: 4) == 4, "and stays there")
    }

    @Test func theBackwardKeyIsTheMirror() {
        #expect(PlaybackShuttle.rate(after: .backward, running: nil) == -1)
        #expect(PlaybackShuttle.rate(after: .backward, running: -1) == -2)
        #expect(PlaybackShuttle.rate(after: .backward, running: -2) == -4)
        #expect(PlaybackShuttle.rate(after: .backward, running: -4) == -4)
    }

    /// Pressing the other direction turns round at normal speed rather than slowing down
    /// first: the person has just said which way they want to go.
    @Test func theOtherDirectionTurnsRoundAtNormalSpeed() {
        #expect(PlaybackShuttle.rate(after: .backward, running: 4) == -1)
        #expect(PlaybackShuttle.rate(after: .forward, running: -2) == 1)
    }

    @Test func theStopKeyStopsWhateverIsHappening() {
        for running in [nil, 1.0, -4.0, 2.0] {
            #expect(PlaybackShuttle.rate(after: .stop, running: running) == nil)
        }
    }

    @Test func theLimitIsFourTimes() {
        #expect(PlaybackShuttle.fastest == 4)
    }
}
