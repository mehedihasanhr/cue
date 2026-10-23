import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// "Clean up voice", "Even out volume" and "Lower under speech" as parts of the edit:
/// stored, copied, undone, and noticed by the sound's signature. What they sound like is
/// measured in RenderKit's `VoiceFinishTests`.
struct VoiceSwitchTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func voice(_ style: SoundStyle = SoundStyle()) -> SoundTrack {
        SoundTrack(source: .microphone, path: "media/microphone-1.m4a", style: style)
    }

    private func music(ducks: Bool = true) -> AudioRegion {
        AudioRegion(start: time(0), duration: time(20), path: "Audio/music.m4a", ducksUnderSpeech: ducks)
    }

    // MARK: - Old projects

    @Test func aSoundStyleSavedBeforeTheSwitchesKeepsItsMuteAndLevel() throws {
        let style = try JSONDecoder().decode(SoundStyle.self, from: Data(#"{"isMuted":true,"gain":0.4}"#.utf8))
        #expect(style.isMuted)
        #expect(style.gain == 0.4)
        #expect(!style.cleansVoice)
        #expect(!style.evensVolume)
    }

    @Test func aSourceSavedBeforeTheSwitchesOpensUntreated() throws {
        let json = #"{"id":"6F1C9B1E-8A56-4B4E-9E3F-2B2B1F0D9C11","source":"microphone","name":"Mic","path":"media/microphone-1.m4a","style":{"isMuted":false,"gain":1.5}}"#
        let track = try JSONDecoder().decode(SoundTrack.self, from: Data(json.utf8))
        #expect(track.style.gain == 1.5, "the level set before is kept")
        #expect(!track.style.isTreated)
    }

    @Test func anAddedSoundSavedBeforeDuckingDoesNotDuck() throws {
        let json = #"{"id":"6F1C9B1E-8A56-4B4E-9E3F-2B2B1F0D9C12","start":{"value":0,"timescale":600},"duration":{"value":6000,"timescale":600},"path":"Audio/music.m4a","gain":0.7,"fadeIn":2}"#
        let region = try JSONDecoder().decode(AudioRegion.self, from: Data(json.utf8))
        #expect(!region.ducksUnderSpeech)
        #expect(region.duckAmount == AudioRegion.defaultDuckAmount)
        #expect(region.gain == 0.7)
        #expect(region.fadeIn == 2)
    }

    @Test func theSwitchesSurviveSaving() throws {
        var edit = Timeline(sourceDuration: time(20),
                            sound: SoundStyle(cleansVoice: true),
                            soundTracks: [voice(SoundStyle(gain: 0.8, cleansVoice: true, evensVolume: true))])
        var region = music()
        region.duckAmount = 18
        edit.audio = [region]
        let data = try JSONEncoder().encode(edit)
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(decoded == edit)
        #expect(decoded.soundTracks[0].style.evensVolume)
        #expect(decoded.audio[0].duckAmount == 18)
    }

    @Test func anOldTimelineSoundsTheSame() {
        let edit = Timeline(sourceDuration: time(20), soundTracks: [voice()])
        #expect(edit.voiceSignature.treatments.allSatisfy { !$0.cleansVoice && !$0.evensVolume })
        #expect(edit.voiceSignature.dips.isEmpty)
        #expect(edit.voiceSignature.captionSpeech.isEmpty)
    }

    // MARK: - The signature

    @Test func cleaningUpASourceRebuildsTheSound() {
        let plain = Timeline(sourceDuration: time(20), soundTracks: [voice()])
        var cleaned = plain
        cleaned.soundTracks[0].style.cleansVoice = true
        var levelled = plain
        levelled.soundTracks[0].style.evensVolume = true
        #expect(cleaned.audioSignature != plain.audioSignature)
        #expect(levelled.audioSignature != plain.audioSignature)
        #expect(levelled.audioSignature != cleaned.audioSignature)
    }

    @Test func cleaningUpARecordingWithItsSoundInsideRebuildsTheSound() {
        let plain = Timeline(sourceDuration: time(20))
        var cleaned = plain
        cleaned.sound.cleansVoice = true
        #expect(cleaned.audioSignature != plain.audioSignature)
    }

    @Test func duckingAndItsAmountRebuildTheSound() {
        var plain = Timeline(sourceDuration: time(20))
        plain.audio = [music(ducks: false)]
        var ducked = plain
        ducked.audio[0].ducksUnderSpeech = true
        var deeper = ducked
        deeper.audio[0].duckAmount = 20
        #expect(ducked.audioSignature != plain.audioSignature)
        #expect(deeper.audioSignature != ducked.audioSignature)
    }

    @Test func captionsOnlyMatterToTheSoundWhileSomethingDucks() {
        let cue = CaptionCue(start: time(2), duration: time(2), text: "hello there")
        var plain = Timeline(sourceDuration: time(20))
        plain.audio = [music(ducks: false)]
        var captioned = plain
        captioned.captions = [cue]
        #expect(captioned.audioSignature == plain.audioSignature, "a caption is not heard")

        var ducking = captioned
        ducking.audio[0].ducksUnderSpeech = true
        var moved = ducking
        moved.captions[0].start = time(5)
        #expect(moved.audioSignature != ducking.audioSignature, "but the dips follow the words")
    }

    // MARK: - Copied and cut with the sound

    @Test func aCopiedSoundKeepsItsDip() throws {
        var region = music()
        region.duckAmount = 9
        var edit = Timeline(sourceDuration: time(30))
        edit.audio = [region]
        let copied = try #require(CopiedRegion(.audio(region.id), in: edit))
        guard case .audio(let placed)? = copied.placed(at: time(3), in: edit) else {
            Issue.record("the copy did not place")
            return
        }
        #expect(placed.ducksUnderSpeech)
        #expect(placed.duckAmount == 9)
        let data = try #require(copied.encoded())
        guard case .audio(let pasted)? = CopiedRegion.decoded(from: data) else {
            Issue.record("the copy did not cross the pasteboard")
            return
        }
        #expect(pasted.ducksUnderSpeech && pasted.duckAmount == 9)
    }

    /// Cutting out a range used to rebuild each sound field by field, and the fades were
    /// left behind. It keeps them now, and the dip.
    @Test func anExcerptKeepsASoundsFadesAndDip() {
        var region = music()
        region.fadeIn = 1.5
        region.fadeOut = 2
        region.duckAmount = 15
        var edit = Timeline(sourceDuration: time(20))
        edit.audio = [region]
        let excerpt = edit.cut(to: CMTimeRange(start: time(5), duration: time(10)))
        #expect(excerpt.audio.count == 1)
        #expect(excerpt.audio[0].fadeIn == 1.5)
        #expect(excerpt.audio[0].fadeOut == 2)
        #expect(excerpt.audio[0].ducksUnderSpeech)
        #expect(excerpt.audio[0].duckAmount == 15)
        #expect(excerpt.audio[0].sourceStart == time(5))
    }

    @Test func aSourcesSwitchesAreItsOwn() {
        var edit = Timeline(sourceDuration: time(20),
                            soundTracks: [voice(), SoundTrack(source: .systemAudio, path: "media/system-audio.m4a")])
        let id = edit.soundTracks[0].id
        _ = Commands.RestyleSoundTrack(id: id, name: "Clean Up Voice") { $0.style.cleansVoice = true }
            .apply(to: &edit)
        #expect(edit.soundTracks[0].style.cleansVoice)
        #expect(!edit.soundTracks[1].style.cleansVoice, "the screen's sound is left alone")
    }

    // MARK: - Where the speech is

    @Test func captionWordsAreSpeechOnTheTimeline() {
        var edit = Timeline(sourceDuration: time(20))
        edit.captions = [CaptionCue(start: time(2), duration: time(2), text: "one two",
                                    words: [.init(text: "one", from: 0, to: 0.25),
                                            .init(text: "two", from: 0.5, to: 1)])]
        let speech = edit.speechFromCaptions
        #expect(speech.count == 2)
        #expect(abs(speech[0].lowerBound - 2) < 1e-9 && abs(speech[0].upperBound - 2.5) < 1e-9)
        #expect(abs(speech[1].lowerBound - 3) < 1e-9 && abs(speech[1].upperBound - 4) < 1e-9)
    }

    @Test func theVoiceIsFollowedThroughCutsAndSpeed() {
        // Keep 2–6 s at normal speed, then 10–14 s at double speed.
        let edit = Timeline(sourceDuration: time(20),
                            clips: [Clip(sourceStart: time(2), sourceDuration: time(4)),
                                    Clip(sourceStart: time(10), sourceDuration: time(4), speed: 2)])
        let stretches = edit.timelineStretches(ofRecorded: [3...4, 7...8, 11...13])
        #expect(stretches.count == 2, "the words at 7–8 s were cut out")
        #expect(abs(stretches[0].lowerBound - 1) < 1e-9 && abs(stretches[0].upperBound - 2) < 1e-9)
        #expect(abs(stretches[1].lowerBound - 4.5) < 1e-9 && abs(stretches[1].upperBound - 5.5) < 1e-9)
    }

    @Test func aDetachedLaneIsFollowedWhereItWasSlid() {
        var edit = Timeline(sourceDuration: time(20))
        edit.detachedSound = [SoundRun(start: time(8), duration: time(4), sourceStart: time(2))]
        let stretches = edit.timelineStretches(ofRecorded: [3...4])
        #expect(stretches.count == 1)
        #expect(abs(stretches[0].lowerBound - 9) < 1e-9 && abs(stretches[0].upperBound - 10) < 1e-9)
    }

    @Test func aMutedVoiceIsNobodySpeaking() {
        var edit = Timeline(sourceDuration: time(20), soundTracks: [voice()])
        #expect(edit.duckingVoice != nil)
        edit.soundTracks[0].style.isMuted = true
        #expect(edit.duckingVoice == nil)
    }

    // MARK: - The dips

    @Test func twelveDecibelsIsAQuarter() {
        #expect(abs(Ducking.floor(forAmount: 12) - 0.251) < 0.001)
        #expect(Ducking.floor(forAmount: 0) == 1)
    }

    @Test func shortPausesStayDown() {
        let merged = Ducking.merged([1...2, 2.5...3, 6...7])
        #expect(merged == [1...3, 6...7], "half a second between words is one sentence")
    }

    @Test func theMusicIsDownBeforeTheFirstWordAndBackAfterTheLast() {
        let speech = [4.0...6.0]
        let floor = Ducking.floor(forAmount: 12)
        #expect(Ducking.duck(at: 3.7, speech: speech, floor: floor) == 1)
        #expect(abs(Ducking.duck(at: 4.0, speech: speech, floor: floor) - floor) < 1e-9, "down as the word starts")
        #expect(abs(Ducking.duck(at: 5.0, speech: speech, floor: floor) - floor) < 1e-9)
        let halfway = Ducking.duck(at: 6.3, speech: speech, floor: floor)
        #expect(halfway > floor && halfway < 1)
        #expect(Ducking.duck(at: 6.6, speech: speech, floor: floor) == 1, "back 0.6 s after")
    }

    @Test func theEnvelopeMultipliesGainFadesAndDips() {
        let region = AudioRegion(start: time(0), duration: time(10), path: "a.m4a",
                                 gain: 0.5, fadeIn: 1, fadeOut: 1, ducksUnderSpeech: true)
        let points = Ducking.envelope(for: region, speech: [4...5])
        func volume(at seconds: Double) -> Double? {
            points.first { abs($0.seconds - seconds) < 1e-9 }?.volume
        }
        #expect(volume(at: 0) == 0, "rises from silence")
        #expect(volume(at: 1) == 0.5)
        #expect(abs((volume(at: 4) ?? 0) - 0.5 * Ducking.floor(forAmount: 12)) < 1e-9)
        #expect(volume(at: 5.6) == 0.5)
        #expect(volume(at: 10) == 0, "and falls back to it")
        #expect(points.map(\.seconds) == points.map(\.seconds).sorted())
    }

    @Test func withoutAFadeOutTheSoundPlaysToItsEnd() {
        let region = AudioRegion(start: time(2), duration: time(4), path: "a.m4a", ducksUnderSpeech: true)
        let points = Ducking.envelope(for: region, speech: [])
        #expect(points.first?.volume == 1)
        #expect(points.last?.volume == 1)
    }
}

/// The switches as undoable edits.
@MainActor
struct VoiceSwitchUndoTests {
    @Test func turningASwitchOnIsOneUndo() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CueStudioTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try RecordingPackage.create(named: "Take", in: folder)
        try package.write(RecordingManifest(name: "Take", duration: 10))
        let document = try EditorDocument(package: package)
        document.apply(Commands.Restyle("Clean Up Voice") { $0.sound.cleansVoice = true })
        document.apply(Commands.Restyle("Lower Under Speech") { timeline in
            timeline.audio = [AudioRegion(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600),
                                          path: "Audio/music.m4a", ducksUnderSpeech: true)]
        })
        #expect(document.timeline.sound.cleansVoice)
        document.undo()
        #expect(document.timeline.audio.isEmpty)
        #expect(document.timeline.sound.cleansVoice)
        document.undo()
        #expect(!document.timeline.sound.cleansVoice)
    }
}
