import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

private func sound(from: Double = 10, lasting: Double = 8, fadeIn: Double = 0, fadeOut: Double = 0) -> AudioRegion {
    AudioRegion(start: time(from), duration: time(lasting), path: "Audio/song.m4a",
                fadeIn: fadeIn, fadeOut: fadeOut)
}

@Suite("Fading an added sound in and out")
struct SoundFadeTests {
    @Test("Heard as asked when they fit")
    func fits() {
        let fades = sound(fadeIn: 2, fadeOut: 3).heardFades
        #expect(fades.fadeIn == 2)
        #expect(fades.fadeOut == 3)
    }

    @Test("Never longer than the sound, and never overlapping")
    func fitted() {
        let fades = sound(lasting: 4, fadeIn: 3, fadeOut: 3).heardFades
        #expect(fades.fadeIn == 3)
        #expect(fades.fadeOut == 1)
        #expect(sound(lasting: 2, fadeIn: 5).heardFades.fadeIn == 2)
        #expect(sound(fadeIn: -1, fadeOut: .nan).heardFades == (0, 0))
    }

    @Test("Trimming short and long again gives the fades back")
    func keptWhileTrimmed() {
        var region = sound(lasting: 8, fadeIn: 3, fadeOut: 3)
        region.duration = time(2)
        #expect(region.heardFades.fadeOut < 3)
        region.duration = time(8)
        #expect(region.heardFades == (3, 3))
    }

    @Test("Rises from silence and falls back to it")
    func envelope() {
        let region = sound(from: 10, lasting: 8, fadeIn: 2, fadeOut: 4)
        #expect(region.envelope(at: time(10)) == 0)
        #expect(abs(region.envelope(at: time(11)) - 0.5) < 0.001)
        #expect(region.envelope(at: time(13)) == 1)
        #expect(abs(region.envelope(at: time(16)) - 0.5) < 0.001)
        #expect(region.envelope(at: time(9)) == 0, "before it")
        #expect(sound().envelope(at: time(10)) == 1, "no fade is full level from the start")
    }

    @Test("A project from before fades keeps its sounds")
    func olderProject() throws {
        let data = Data(#"""
        {"id":"7B1C2D3E-0000-4000-8000-000000000001",
         "start":{"value":600,"timescale":600,"flags":1,"epoch":0},
         "duration":{"value":3000,"timescale":600,"flags":1,"epoch":0},
         "path":"Audio/song.m4a","gain":0.5,
         "sourceStart":{"value":0,"timescale":600,"flags":1,"epoch":0}}
        """#.utf8)
        let region = try JSONDecoder().decode(AudioRegion.self, from: data)
        #expect(region.gain == 0.5)
        #expect(region.fadeIn == 0)
        #expect(region.fadeOut == 0)
        #expect(region.duration == time(5))
    }

    @Test("They survive a save")
    func roundTrip() throws {
        let region = sound(fadeIn: 1.5, fadeOut: 2.5)
        let back = try JSONDecoder().decode(AudioRegion.self, from: JSONEncoder().encode(region))
        #expect(back == region)
    }

    @Test("A copy keeps them")
    func copied() throws {
        var timeline = Timeline(sourceDuration: time(60))
        let region = sound(fadeIn: 1.5, fadeOut: 2.5)
        timeline.audio = [region]
        let copy = try #require(CopiedRegion(.audio(region.id), in: timeline))
        guard case .audio(let pasted) = copy.placed(at: time(30), in: timeline) else {
            Issue.record("not a sound")
            return
        }
        #expect(pasted.fadeIn == 1.5)
        #expect(pasted.fadeOut == 2.5)
    }

    @Test("Changing a fade changes the sound of the edit")
    func audible() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.audio = [sound()]
        var faded = timeline
        faded.audio[0].fadeOut = 2
        #expect(timeline.audioSignature != faded.audioSignature)
    }
}
