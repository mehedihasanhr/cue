import Foundation
import Testing
@testable import RenderKit

/// A GIF lasts as long as the video it came from.
struct GIFTimingTests {
    @Test(arguments: [10, 12, 15, 20, 24, 25, 30])
    func theFramesAddUpToTheEdit(_ frameRate: Int) {
        let frames = frameRate * 30
        let delays = GIFExporter.delays(frames: frames, frameRate: frameRate)
        #expect(delays.count == frames)
        #expect(abs(delays.reduce(0, +) - 30) < 0.011, "thirty seconds of edit, thirty seconds of GIF")
        // Every delay a whole number of hundredths, the only thing a GIF can say.
        #expect(delays.allSatisfy { abs(($0 * 100).rounded() - $0 * 100) < 0.000_1 })
    }

    /// Each frame ends on the hundredth nearest to where it should: 3, 7, 10, 13, 17, 20.
    @Test func thirtyAFrameSecondIsThreesAndFours() {
        #expect(GIFExporter.delays(frames: 6, frameRate: 30) == [0.03, 0.04, 0.03, 0.03, 0.04, 0.03])
    }

    @Test func nothingToShowIsNoDelays() {
        #expect(GIFExporter.delays(frames: 0, frameRate: 30).isEmpty)
    }
}
