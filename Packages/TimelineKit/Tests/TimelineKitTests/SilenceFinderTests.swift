import Foundation
import Testing
@testable import TimelineKit

/// Finding where nobody speaks, for hiding the camera while they do not.
struct SilenceFinderTests {
    /// Speech, then `quiet` seconds of near-nothing, then speech again, at 100 bins a second.
    private func peaks(speech: Double = 3, quiet: Double, noise: Float = 0.02) -> WaveformPeaks {
        let bins = 100.0
        var levels: [Float] = []
        for _ in 0..<Int(speech * bins) { levels.append(0.8) }
        for _ in 0..<Int(quiet * bins) { levels.append(noise) }
        for _ in 0..<Int(speech * bins) { levels.append(0.7) }
        let finest = WaveformPeaks.Level(binsPerSecond: bins, minimums: levels.map { -$0 }, maximums: levels)
        return WaveformPeaks(duration: (speech * 2 + quiet), finest: finest)
    }

    @Test func aLongQuietStretchIsASilence() throws {
        let silences = SilenceFinder.silences(in: peaks(quiet: 6), minimum: 5)
        let silence = try #require(silences.first)
        #expect(silences.count == 1)
        #expect(abs(silence.lowerBound - 3) < 0.06)
        #expect(abs(silence.upperBound - 9) < 0.06)
    }

    @Test func aShortPauseIsNot() {
        #expect(SilenceFinder.silences(in: peaks(quiet: 3), minimum: 5).isEmpty)
    }

    /// A tenth of the loudest: room noise under that is silence, a voice over it is not.
    @Test func quietIsMeasuredAgainstTheLoudest() {
        #expect(SilenceFinder.silences(in: peaks(quiet: 6, noise: 0.2), minimum: 5).isEmpty)
    }

    @Test func theCameraGoesHalfASecondInAndComesBackHalfASecondEarly() {
        let hidden = SilenceFinder.cameraHidden(in: [3...9, 20...20.8])
        #expect(hidden == [3.5...8.5])
    }
}
