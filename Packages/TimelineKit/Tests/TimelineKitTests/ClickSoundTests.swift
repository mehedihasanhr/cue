import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

private func click(_ t: Double, secondary: Bool = false) -> CursorTrack.Click {
    CursorTrack.Click(t: t, point: CGPoint(x: 100, y: 100), isSecondary: secondary)
}

/// A timeline of the whole 20-second recording, with the click sound on.
private func timeline(_ change: (inout Timeline) -> Void = { _ in }) -> Timeline {
    var timeline = Timeline(sourceDuration: time(20))
    timeline.cursor.clickSound = true
    change(&timeline)
    return timeline
}

private func seconds(_ moments: [ClickSoundMoment]) -> [Double] {
    moments.map { ($0.time.seconds * 1_000).rounded() / 1_000 }
}

@Suite("Where clicks are heard")
struct ClickSoundPlacementTests {
    @Test("Off unless asked for")
    func offByDefault() {
        var plain = Timeline(sourceDuration: time(20))
        #expect(plain.clickSoundMoments(for: [click(3)]).isEmpty)
        plain.cursor.clickSound = true
        #expect(plain.clickSoundMoments(for: [click(3)]).count == 1)
    }

    @Test("Heard where it happened, with the button it was")
    func uncut() {
        let moments = timeline().clickSoundMoments(for: [click(3), click(7.5, secondary: true)])
        #expect(seconds(moments) == [3, 7.5])
        #expect(moments.map(\.isSecondary) == [false, true])
    }

    @Test("Not heard where it was cut")
    func cutAway() {
        let edit = timeline {
            $0.clips = [Clip(sourceStart: .zero, sourceDuration: time(5)),
                        Clip(sourceStart: time(10), sourceDuration: time(10))]
        }
        // 3 s is kept; 7 s was cut; 12 s is now 2 s after the first clip's 5.
        #expect(seconds(edit.clickSoundMoments(for: [click(3), click(7), click(12)])) == [3, 7])
    }

    @Test("A sped-up clip brings its clicks closer to its start")
    func spedUp() {
        let edit = timeline {
            $0.clips = [Clip(sourceStart: .zero, sourceDuration: time(4)),
                        Clip(sourceStart: time(4), sourceDuration: time(16), speed: 2)]
        }
        // 8 s is 4 s into a double-speed clip that starts at 4: heard at 6.
        #expect(seconds(edit.clickSoundMoments(for: [click(8)])) == [6])
    }

    @Test("Footage used twice is heard twice")
    func usedTwice() {
        let edit = timeline {
            $0.clips = [Clip(sourceStart: time(2), sourceDuration: time(3)),
                        Clip(sourceStart: time(2), sourceDuration: time(3))]
        }
        #expect(seconds(edit.clickSoundMoments(for: [click(3)])) == [1, 4])
    }

    @Test("Silent where the pointer is hidden")
    func hidden() {
        let edit = timeline {
            $0.cursorRegions = [CursorRegion(start: time(5), duration: time(4), isHidden: true)]
        }
        #expect(seconds(edit.clickSoundMoments(for: [click(3), click(7), click(12)])) == [3, 12])
        let noPointer = timeline { $0.cursor.isVisible = false }
        #expect(noPointer.clickSoundMoments(for: [click(3)]).isEmpty)
    }

    @Test("Clicks too close together after a speed-up are heard once")
    func buzz() {
        let edit = timeline {
            $0.clips = [Clip(sourceStart: .zero, sourceDuration: time(20), speed: 8)]
        }
        // 0.1 s apart in the recording is 12.5 ms apart at eight times the speed.
        // Three within 25 ms of the first are heard as it; the one at 6 s is well clear.
        let moments = edit.clickSoundMoments(for: [click(4), click(4.1), click(4.2), click(6)])
        #expect(seconds(moments) == [0.5, 0.75])
    }

    @Test("In time order whatever order the clicks arrive in")
    func ordered() {
        #expect(seconds(timeline().clickSoundMoments(for: [click(9), click(2), click(5)])) == [2, 5, 9])
    }

    @Test("A detached sound lane does not move them")
    func followsThePicture() {
        var edit = timeline()
        let attached = edit.clickSoundMoments(for: [click(6)])
        edit.detachedSound = [SoundRun(start: time(2), duration: time(18), sourceStart: .zero)]
        #expect(edit.clickSoundMoments(for: [click(6)]) == attached)
    }
}

@Suite("Click sounds and the sound of the edit")
struct ClickSoundSignatureTests {
    @Test("Turning them on, choosing another or changing the level changes the sound")
    func settingsAreAudible() {
        let off = Timeline(sourceDuration: time(20))
        var on = off
        on.cursor.clickSound = true
        #expect(off.audioSignature != on.audioSignature)
        var crisp = on
        crisp.cursor.clickSoundKind = .crisp
        #expect(crisp.audioSignature != on.audioSignature)
        var louder = on
        louder.cursor.clickSoundVolume = 0.9
        #expect(louder.audioSignature != on.audioSignature)
    }

    @Test("While they are off, nothing about them rebuilds the sound")
    func offIsSilentAboutThem() {
        let off = Timeline(sourceDuration: time(20))
        var other = off
        other.cursor.clickSoundKind = .crisp
        other.cursorRegions = [CursorRegion(start: time(5), duration: time(4), isHidden: true)]
        #expect(off.audioSignature == other.audioSignature)
    }

    @Test("With the sound detached, a cut in the picture still moves the clicks")
    func pictureCutsCount() {
        var edit = Timeline(sourceDuration: time(20))
        edit.cursor.clickSound = true
        edit.detachedSound = [SoundRun(start: .zero, duration: time(20), sourceStart: .zero)]
        var cut = edit
        cut.clips = [Clip(sourceStart: time(2), sourceDuration: time(18))]
        #expect(edit.audioSignature != cut.audioSignature)
    }

    @Test("A stretch that hides the pointer changes where they are heard")
    func hidingCounts() {
        var edit = Timeline(sourceDuration: time(20))
        edit.cursor.clickSound = true
        var hidden = edit
        hidden.cursorRegions = [CursorRegion(start: time(5), duration: time(4), isHidden: true)]
        #expect(edit.audioSignature != hidden.audioSignature)
    }
}

@Suite("Click sound settings in older projects")
struct ClickSoundCompatibilityTests {
    @Test("A project from before them opens with them off")
    func missingFields() throws {
        let data = Data(#"{"isVisible":true,"scale":2,"clickStyle":"ripple"}"#.utf8)
        let style = try JSONDecoder().decode(CursorStyle.self, from: data)
        #expect(style.clickSound == false)
        #expect(style.clickSoundKind == .soft)
        #expect(style.clickSoundVolume == 0.5)
        #expect(style.scale == 2)
        #expect(style.clickStyle == .ripple)
    }

    @Test("They survive a save")
    func roundTrip() throws {
        var style = CursorStyle()
        style.clickSound = true
        style.clickSoundKind = .crisp
        style.clickSoundVolume = 0.8
        let back = try JSONDecoder().decode(CursorStyle.self, from: JSONEncoder().encode(style))
        #expect(back == style)
    }

    @Test("A level out of range is brought back into it")
    func clamped() throws {
        let data = Data(#"{"clickSound":true,"clickSoundVolume":4}"#.utf8)
        #expect(try JSONDecoder().decode(CursorStyle.self, from: data).clickSoundVolume == 1)
        #expect(CursorStyle(clickSoundVolume: -1).clickSoundVolume == 0)
    }
}
