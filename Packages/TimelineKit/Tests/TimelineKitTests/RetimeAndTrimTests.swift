import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

private func seconds(_ value: CMTime) -> Double {
    (value.seconds * 1_000).rounded() / 1_000
}

/// Which second of the recording is heard at a moment on the timeline, from a detached
/// lane.
private func heard(at moment: Double, in runs: [SoundRun]) -> Double? {
    guard let run = runs.first(where: { $0.start.seconds <= moment && moment < $0.end.seconds }) else { return nil }
    return run.sourceStart.seconds + (moment - run.start.seconds) * run.speed
}

/// Which second of the recording is seen at a moment on the timeline.
private func seen(at moment: Double, in timeline: Timeline) -> Double? {
    timeline.sourceTime(at: time(moment))?.seconds
}

@Suite("Changing speed moves what is on the timeline once")
struct RetimeTests {
    @Test("A zoom near the end of a slowed stretch is moved with it, not twice")
    func slowedOnce() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.zooms = [ZoomRegion(start: time(16), duration: time(3))]
        #expect(ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(10), end: time(20)), speed: 0.5))
        #expect(seconds(timeline.zooms[0].start) == 22)
        #expect(seconds(timeline.zooms[0].end) == 28)
    }

    @Test("A zoom after a sped-up stretch is not squeezed as though it were in it")
    func afterSpedUp() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.zooms = [ZoomRegion(start: time(22), duration: time(2))]
        #expect(ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(10), end: time(20)), speed: 2))
        #expect(seconds(timeline.zooms[0].start) == 17)
        #expect(seconds(timeline.zooms[0].duration) == 2)
    }

    @Test("A zoom across the edge of the stretch stretches only its inside part")
    func straddling() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.zooms = [ZoomRegion(start: time(18), duration: time(4))]
        #expect(ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(10), end: time(20)), speed: 0.5))
        #expect(seconds(timeline.zooms[0].start) == 26)
        #expect(seconds(timeline.zooms[0].end) == 32)
    }

    @Test("Detached sound keeps playing what the picture shows")
    func detachedStaysInStep() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.clips = [Clip(sourceStart: .zero, sourceDuration: time(20)),
                          Clip(sourceStart: time(20), sourceDuration: time(20)),
                          Clip(sourceStart: time(40), sourceDuration: time(20))]
        timeline.detachedSound = [SoundRun(start: .zero, duration: time(60), sourceStart: .zero)]
        #expect(ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(20), end: time(40)), speed: 2))
        let runs = timeline.detachedSound!
        for moment in [5.0, 21.0, 25.0, 29.9, 31.0, 45.0] {
            let picture = seen(at: moment, in: timeline)
            let sound = heard(at: moment, in: runs)
            #expect(picture != nil && sound != nil)
            if let picture, let sound {
                #expect(abs(picture - sound) < 0.01, "at \(moment) s the picture shows \(picture) and the sound plays \(sound)")
            }
        }
    }
}

@Suite("Trimming the front of a clip")
struct HeadTrimRegionTests {
    @Test("A zoom on the trimmed-away footage goes with it")
    func trimmedAway() throws {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.clips = [Clip(sourceStart: .zero, sourceDuration: time(10)),
                          Clip(sourceStart: time(10), sourceDuration: time(50))]
        timeline.zooms = [ZoomRegion(start: time(11), duration: time(2)),
                          ZoomRegion(start: time(20), duration: time(2))]
        let second = timeline.clips[1].id
        #expect(ClipSequence.trim(&timeline, clipID: second, head: time(15), tail: nil))
        #expect(timeline.zooms.count == 1, "the zoom on 11–13 s was on footage that is gone")
        #expect(seconds(timeline.zooms[0].start) == 15, "the one at 20 s moves back by the five seconds cut")
    }

    @Test("Revealing more footage at the front moves what is after it later")
    func revealed() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.clips = [Clip(sourceStart: .zero, sourceDuration: time(10)),
                          Clip(sourceStart: time(20), sourceDuration: time(40))]
        timeline.zooms = [ZoomRegion(start: time(12), duration: time(2))]
        let second = timeline.clips[1].id
        #expect(ClipSequence.trim(&timeline, clipID: second, head: time(15), tail: nil))
        #expect(seconds(timeline.zooms[0].start) == 17)
    }
}

@Suite("Cutting the picture under detached sound")
struct DetachedCutTests {
    @Test("The sound after the cut is the sound of the picture after it")
    func inStep() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.detachedSound = [SoundRun(start: .zero, duration: time(60), sourceStart: .zero)]
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(20), end: time(30))))
        let runs = timeline.detachedSound!
        #expect(runs.count == 2)
        for moment in [10.0, 19.9, 20.0, 25.0, 45.0] {
            let picture = seen(at: moment, in: timeline)
            let sound = heard(at: moment, in: runs)
            if let picture, let sound {
                #expect(abs(picture - sound) < 0.01, "at \(moment) s")
            } else {
                Issue.record("nothing at \(moment) s")
            }
        }
    }

    @Test("Splitting a run keeps every second of it, once")
    func split() {
        let run = SoundRun(start: time(5), duration: time(10), sourceStart: time(100), speed: 2)
        let pieces = run.split(at: [time(8), time(1), time(12), time(30)])
        #expect(pieces.count == 3)
        #expect(pieces.map { seconds($0.start) } == [5, 8, 12])
        #expect(pieces.map { seconds($0.sourceStart) } == [100, 106, 114])
        #expect(abs(pieces.map(\.duration.seconds).reduce(0, +) - 10) < 0.001)
    }
}
