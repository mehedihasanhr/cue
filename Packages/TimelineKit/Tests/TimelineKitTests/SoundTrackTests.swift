import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// The recording's sound, source by source.
///
/// The thing being pinned down here is that a level set on one source lands on that
/// source: the bug this feature exists to fix was muting "the recording" and losing the
/// voiceover along with the browser tab that was playing music.
struct SoundTrackTests {
    private func manifest(_ tracks: [RecordingManifest.Track]) -> RecordingManifest {
        RecordingManifest(name: "Take", duration: 10, tracks: tracks)
    }

    private let picture = RecordingManifest.Track(kind: .screen, path: "media/screen.mov")

    private func timeline(_ tracks: [SoundTrack]) -> Timeline {
        Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600), soundTracks: tracks)
    }

    // MARK: - Where the lanes come from

    @Test func aRecordingWithTwoMicrophonesOpensWithALanePerSource() {
        var edit = timeline([])
        edit.adoptSoundTracks(from: manifest([
            picture,
            .init(kind: .systemAudio, path: "media/system-audio.m4a", name: "System Audio"),
            .init(kind: .microphone, path: "media/microphone-1.m4a", name: "MacBook Pro Microphone", deviceID: "built-in"),
            .init(kind: .microphone, path: "media/microphone-2.m4a", name: "Shure MV7", deviceID: "usb-1"),
        ]))

        #expect(edit.soundTracks.count == 3)
        #expect(edit.soundTracks.map(\.name) == ["System Audio", "MacBook Pro Microphone", "Shure MV7"])
        #expect(edit.soundTracks.map(\.source) == [.systemAudio, .microphone, .microphone])
        #expect(edit.soundTracks[2].deviceID == "usb-1", "two of the same model are told apart by id")
        #expect(edit.hasSeparateSound)
    }

    /// The compatibility case, and the one that would be silently wrong: an old recording
    /// names its audio tracks too, both pointing at the file the picture is in.
    @Test func aRecordingWhoseSoundIsInsideTheVideoGetsNoLanes() {
        var edit = timeline([])
        edit.adoptSoundTracks(from: manifest([
            picture,
            .init(kind: .systemAudio, path: "media/screen.mov"),
            .init(kind: .microphone, path: "media/screen.mov"),
        ]))

        #expect(edit.soundTracks.isEmpty, "one track read twice would play twice")
        #expect(!edit.hasSeparateSound)
    }

    /// Reopening a project must not undo the levels set in it.
    @Test func openingAProjectAgainLeavesItsLanesAlone() {
        var edit = timeline([SoundTrack(source: .microphone, name: "Shure MV7",
                                        path: "media/microphone-1.m4a",
                                        style: SoundStyle(isMuted: false, gain: 0.4))])
        edit.adoptSoundTracks(from: manifest([
            picture,
            .init(kind: .systemAudio, path: "media/system-audio.m4a"),
            .init(kind: .microphone, path: "media/microphone-1.m4a"),
        ]))

        #expect(edit.soundTracks.count == 1)
        #expect(edit.soundTracks[0].style.gain == 0.4)
    }

    // MARK: - Levels

    @Test func aSourcesLevelIsItsOwnUnderTheMaster() {
        var edit = timeline([SoundTrack(source: .systemAudio, path: "a.m4a",
                                        style: SoundStyle(gain: 0.5))])
        #expect(edit.level(of: edit.soundTracks[0]) == 0.5)

        edit.sound.gain = 0.5
        #expect(edit.level(of: edit.soundTracks[0]) == 0.25, "half of half")
    }

    @Test func mutingTheMasterSilencesEverySource() {
        var edit = timeline([
            SoundTrack(source: .systemAudio, path: "a.m4a"),
            SoundTrack(source: .microphone, path: "b.m4a"),
        ])
        edit.sound.isMuted = true
        #expect(edit.soundTracks.allSatisfy { !edit.isAudible($0) })
    }

    /// The whole point of the feature, in one test.
    @Test func mutingOneSourceLeavesTheOtherAudible() {
        var edit = timeline([
            SoundTrack(source: .systemAudio, path: "a.m4a"),
            SoundTrack(source: .microphone, path: "b.m4a"),
        ])
        edit.soundTracks[0].style.isMuted = true

        #expect(!edit.isAudible(edit.soundTracks[0]))
        #expect(edit.isAudible(edit.soundTracks[1]), "the voice is still there")
    }

    // MARK: - Commands

    @Test func soloMutesEverythingElse() {
        var edit = timeline([
            SoundTrack(source: .systemAudio, path: "a.m4a"),
            SoundTrack(source: .microphone, path: "b.m4a"),
            SoundTrack(source: .microphone, path: "c.m4a"),
        ])
        let voice = edit.soundTracks[1].id
        #expect(Commands.SoloSoundTrack(id: voice).apply(to: &edit))

        #expect(edit.soundTracks.filter { !$0.style.isMuted }.map(\.id) == [voice])
        #expect(Commands.UnmuteAllSoundTracks().apply(to: &edit))
        #expect(edit.soundTracks.allSatisfy { !$0.style.isMuted })
    }

    /// A command that changes nothing reports so, which is what keeps it off the undo
    /// stack.
    @Test func aCommandThatChangesNothingSaysSo() {
        var edit = timeline([SoundTrack(source: .microphone, path: "b.m4a")])
        #expect(!Commands.UnmuteAllSoundTracks().apply(to: &edit), "nothing was muted")
        #expect(!Commands.SoloSoundTrack(id: UUID()).apply(to: &edit), "no such lane")
        #expect(!Commands.RestyleSoundTrack(id: edit.soundTracks[0].id, name: "Level") { $0.style.gain = 1 }
            .apply(to: &edit))
    }

    @Test func renamingALaneIsAnEdit() {
        var edit = timeline([SoundTrack(source: .microphone, path: "b.m4a")])
        #expect(Commands.RestyleSoundTrack(id: edit.soundTracks[0].id, name: "Rename") { $0.name = "Guest" }
            .apply(to: &edit))
        #expect(edit.soundTracks[0].name == "Guest")
    }

    // MARK: - What the preview has to rebuild for

    @Test func mutingOneSourceChangesTheSoundOfTheEdit() {
        var edit = timeline([
            SoundTrack(source: .systemAudio, path: "a.m4a"),
            SoundTrack(source: .microphone, path: "b.m4a"),
        ])
        let before = edit.audioSignature
        edit.soundTracks[0].style.isMuted = true
        #expect(edit.audioSignature != before)
    }

    /// The counterpart, and the reason the signature exists: something only visible must
    /// not send the player off to decode the recording again.
    @Test func renamingALaneDoesNotChangeTheSoundOfTheEdit() {
        var edit = timeline([SoundTrack(source: .microphone, path: "b.m4a")])
        let before = edit.audioSignature
        edit.soundTracks[0].name = "Guest"
        #expect(edit.audioSignature == before)
    }

    // MARK: - Captions

    @Test func captionsAreMadeFromAVoiceWhenThereIsOne() {
        let edit = timeline([
            SoundTrack(source: .systemAudio, path: "a.m4a"),
            SoundTrack(source: .microphone, path: "b.m4a"),
        ])
        #expect(edit.soundTrackForSpeech?.path == "b.m4a")
    }

    @Test func captionsFallBackToWhateverSoundThereIs() {
        let edit = timeline([SoundTrack(source: .systemAudio, path: "a.m4a")])
        #expect(edit.soundTrackForSpeech?.path == "a.m4a")
        #expect(timeline([]).soundTrackForSpeech == nil)
    }

    /// A muted microphone is still the microphone, but a *second*, audible one is the
    /// better bet — transcribing silence produces no captions at all.
    @Test func captionsPreferAMicrophoneThatCanBeHeard() {
        var edit = timeline([
            SoundTrack(source: .microphone, path: "muted.m4a"),
            SoundTrack(source: .microphone, path: "live.m4a"),
        ])
        edit.soundTracks[0].style.isMuted = true
        #expect(edit.soundTrackForSpeech?.path == "live.m4a")
    }

    // MARK: - Round trip

    @Test func lanesSurviveBeingWrittenAndReadBack() throws {
        let edit = timeline([
            SoundTrack(source: .systemAudio, path: "media/system-audio.m4a",
                       style: SoundStyle(isMuted: true, gain: 0.3)),
            SoundTrack(source: .microphone, name: "Shure MV7", path: "media/microphone-1.m4a",
                       deviceID: "usb-1"),
        ])
        let data = try JSONEncoder().encode(edit)
        let read = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(read.soundTracks == edit.soundTracks)
    }

    /// A project written before lanes existed opens with none, and sounds as it did.
    @Test func aProjectWrittenBeforeLanesExistedOpensWithoutThem() throws {
        let json = #"{"sourceDuration":{"value":6000,"timescale":600},"clips":[]}"#
        let read = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
        #expect(read.soundTracks.isEmpty)
        #expect(!read.hasSeparateSound)
        #expect(read.sound.isAudible)
    }
}
