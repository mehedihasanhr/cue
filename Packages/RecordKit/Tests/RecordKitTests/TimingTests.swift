import CoreMedia
import Foundation
import Testing
@testable import RecordKit

/// The arithmetic that keeps picture and sound on the same clock.
struct TimingTests {
    // MARK: - Frame pacing

    private let pacer = FramePacer(frameRate: 60)

    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    @Test func aFrameOnTimeNeedsNoFiller() {
        #expect(pacer.fillTimes(lastFrame: seconds(1), next: seconds(1 + 1.0 / 60)).isEmpty)
    }

    /// The screen not changing for a second is the normal case in a demo recording, not
    /// an error — and it is exactly where a naive recorder loses sync.
    @Test func aStillScreenIsFilledFrameByFrame() {
        let fills = pacer.fillTimes(lastFrame: seconds(1), next: seconds(2))
        #expect(fills.count == 59)
        #expect(fills.first!.seconds > 1)
        #expect(fills.last!.seconds < 2)
        // Evenly spaced, one frame apart.
        let gaps = zip(fills, fills.dropFirst()).map { ($1 - $0).seconds }
        #expect(gaps.allSatisfy { abs($0 - 1.0 / 60) < 0.0001 })
    }

    @Test func aRecordingNeverStartsWithFiller() {
        #expect(pacer.fillTimes(lastFrame: nil, next: seconds(5)).isEmpty)
    }

    /// A machine that slept for an hour must not wake up and emit 216,000 frames.
    @Test func anAbsurdGapIsCapped() {
        let fills = pacer.fillTimes(lastFrame: seconds(0), next: seconds(3_600))
        #expect(fills.count == 120, "two seconds' worth at 60 fps")
    }

    @Test func timeRunningBackwardsProducesNothing() {
        #expect(pacer.fillTimes(lastFrame: seconds(10), next: seconds(9)).isEmpty)
    }

    @Test(arguments: [24, 30, 60, 120])
    func theFillRateFollowsTheFrameRate(_ rate: Int) {
        let pacer = FramePacer(frameRate: rate)
        let fills = pacer.fillTimes(lastFrame: seconds(0), next: seconds(1))
        #expect(fills.count == rate - 1)
    }

    // MARK: - Audio gaps

    private let filler = AudioGapFiller()

    @Test func ordinaryBufferJitterIsNotAGap() {
        #expect(filler.silence(writtenThrough: seconds(1), next: seconds(1.01)) == nil)
    }

    @Test func aHoleIsFilledWithExactlyItsOwnLength() {
        let silence = filler.silence(writtenThrough: seconds(1), next: seconds(3))
        #expect(silence?.seconds == 2)
    }

    @Test func theFirstBufferHasNothingToFill() {
        #expect(filler.silence(writtenThrough: nil, next: seconds(4)) == nil)
    }

    /// A recording that lost audio for an hour is already odd; a capped silence keeps
    /// the rest of it usable rather than synthesising an hour of zeroes.
    @Test func anEnormousHoleIsClamped() {
        let silence = filler.silence(writtenThrough: seconds(0), next: seconds(3_600))
        #expect(silence?.seconds == 30)
    }

    // MARK: - Disk

    @Test func theDiskVerdictHasThreeBands() {
        let monitor = DiskSpaceMonitor(stopBelow: 100, warnBelow: 1_000)
        #expect(monitor.verdict(bytesAvailable: 5_000) == .fine)
        #expect(monitor.verdict(bytesAvailable: 500) == .low(bytesAvailable: 500))
        #expect(monitor.verdict(bytesAvailable: 50) == .stop(bytesAvailable: 50))
    }

    // MARK: - Clock

    @Test func theClockIsZeroUntilItStarts() {
        let clock = RecordingClock()
        #expect(!clock.hasStarted)
        #expect(clock.elapsed() == 0)

        let origin = RecordingClock.now
        clock.start(at: origin)
        #expect(clock.hasStarted)
        #expect(clock.elapsed(at: origin + CMTime(seconds: 2.5, preferredTimescale: 600)) == 2.5)
    }

    /// A telemetry sample that races the first frame belongs at the start, not before it.
    @Test func aSampleFromBeforeTheStartLandsAtZero() {
        let clock = RecordingClock()
        let origin = RecordingClock.now
        clock.start(at: origin)
        #expect(clock.elapsed(at: origin - CMTime(seconds: 1, preferredTimescale: 600)) == 0)
    }

    // MARK: - Holds

    /// The whole reason the clock owns the pause: a sample taken after a hold has to land
    /// where the picture is, and the picture has had the hold taken out of it.
    @Test func aHoldComesOutOfEverythingAfterIt() {
        let clock = RecordingClock()
        let origin = RecordingClock.now
        clock.start(at: origin)
        clock.hold(at: origin + seconds(10))
        clock.release(at: origin + seconds(12))

        #expect(clock.elapsed(at: origin + seconds(9)) == 9)
        #expect(abs(clock.elapsed(at: origin + seconds(13)) - 11) < 0.0001,
                "a second after a two-second hold is eleven seconds into the recording, not thirteen")
        #expect(clock.recordingTime(forHost: origin + seconds(13)) == origin + seconds(11))
    }

    @Test func holdsAddUp() {
        let clock = RecordingClock()
        let origin = RecordingClock.now
        clock.start(at: origin)
        clock.hold(at: origin + seconds(2))
        clock.release(at: origin + seconds(3))
        clock.hold(at: origin + seconds(5))
        clock.release(at: origin + seconds(8))

        #expect(abs(clock.elapsed(at: origin + seconds(4)) - 3) < 0.0001)
        #expect(abs(clock.elapsed(at: origin + seconds(9)) - 5) < 0.0001)
    }

    /// A buffer stamped inside a hold was captured while the recording was not running.
    /// It has no time in the file, and saying so is what stops it being written.
    @Test func aMomentInsideAHoldHasNoPlaceInTheFile() {
        let clock = RecordingClock()
        let origin = RecordingClock.now
        clock.start(at: origin)
        clock.hold(at: origin + seconds(4))
        #expect(clock.isHeld)
        #expect(clock.recordingTime(forHost: origin + seconds(5)) == nil, "still held")

        clock.release(at: origin + seconds(6))
        #expect(!clock.isHeld)
        #expect(clock.recordingTime(forHost: origin + seconds(5)) == nil, "held then, even though not now")
        #expect(clock.recordingTime(forHost: origin + seconds(3)) == origin + seconds(3))
    }

    /// The pointer's clock stands still through a hold rather than running on.
    @Test func theClockStandsStillWhileHeld() {
        let clock = RecordingClock()
        let origin = RecordingClock.now
        clock.start(at: origin)
        clock.hold(at: origin + seconds(4))
        #expect(abs(clock.elapsed(at: origin + seconds(7)) - 4) < 0.0001)
    }

    @Test func releasingWithoutHoldingChangesNothing() {
        let clock = RecordingClock()
        let origin = RecordingClock.now
        clock.start(at: origin)
        clock.release(at: origin + seconds(3))
        #expect(clock.elapsed(at: origin + seconds(5)) == 5)
    }

    // MARK: - When an event happened

    /// A click is stamped with the moment it happened, which is a little before the
    /// moment anybody was told about it.
    @Test func anEventKeepsItsOwnTime() {
        let now = seconds(1_000)
        let stamped = CursorTracker.hostTime(forEventTimestamp: 999.96, now: now)
        #expect(abs(stamped.seconds - 999.96) < 0.000_001)
    }

    /// A timestamp that cannot be right is not used: a clock error of a minute in a click
    /// would put its ring in a different scene.
    @Test func anEventWithAnImpossibleTimeIsStampedNow() {
        let now = seconds(1_000)
        #expect(CursorTracker.hostTime(forEventTimestamp: 1_030, now: now) == now, "from the future")
        #expect(CursorTracker.hostTime(forEventTimestamp: 940, now: now) == now, "a minute old")
        #expect(CursorTracker.hostTime(forEventTimestamp: 0, now: now) == now)
    }

    // MARK: - Quality

    @Test func bitrateRisesWithQualityAndPixels() {
        let pixels = 2_560 * 1_440
        let good = CaptureQuality.good.bitrate(forPixels: pixels)
        let best = CaptureQuality.best.bitrate(forPixels: pixels)
        #expect(good < best)
        #expect(CaptureQuality.better.bitrate(forPixels: 1_920 * 1_080)
                    < CaptureQuality.better.bitrate(forPixels: 3_840 * 2_160))
    }

    @Test func bitrateStaysSaneAtTheExtremes() {
        #expect(CaptureQuality.good.bitrate(forPixels: 100) >= 2_000_000)
        #expect(CaptureQuality.best.bitrate(forPixels: 7_680 * 4_320) <= 120_000_000)
    }
}

/// How far the pointer's clock is moved to meet the picture.
struct PointerLatencyTests {
    @Test func itIsOneRefreshOfTheDisplay() {
        #expect(abs(PointerLatency.seconds(refreshRate: 120) - 1.0 / 120) < 0.000_001)
        #expect(abs(PointerLatency.seconds(refreshRate: 60) - 1.0 / 60) < 0.000_001)
    }

    /// A display that reports nothing, or nonsense, gets the common answer rather than
    /// none or an enormous one.
    @Test(arguments: [0.0, -1, 5, 10_000, .nan, .infinity])
    func aRateThatCannotBeRightIsTreatedAsSixty(_ rate: Double) {
        #expect(abs(PointerLatency.seconds(refreshRate: rate) - 1.0 / 60) < 0.000_001)
    }
}
