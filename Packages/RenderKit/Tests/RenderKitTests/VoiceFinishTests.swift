import AVFoundation
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// "Clean up voice", "Even out volume" and "Lower under speech", heard the way the
/// exporter hears them: every number here is measured from the mixdown's own samples,
/// read back through `AVAssetReader`, from sound synthesised in the test.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct VoiceFinishTests {
    typealias Sound = SynthesisedSound

    private let voicePath = "media/microphone-1.wav"
    private let nowhere = URL(fileURLWithPath: "/nonexistent/screen.mov")

    /// A package holding one microphone file made of `samples`.
    private func package(voice samples: [Float], music: [Float]? = nil) throws -> URL {
        let folder = try Sound.folder()
        try Sound.write(samples, to: folder.appendingPathComponent(voicePath))
        if let music { try Sound.write(music, to: folder.appendingPathComponent("Audio/music.wav")) }
        return folder
    }

    private func timeline(seconds: Double, voice: SoundStyle) -> Timeline {
        Timeline(sourceDuration: Sound.time(seconds),
                 soundTracks: [SoundTrack(source: .microphone, path: voicePath, style: voice)])
    }

    private func render(_ timeline: Timeline, in folder: URL) async throws -> [Float] {
        let result = await AudioMixdown.build(timeline: timeline, videoURL: nowhere, packageURL: folder)
        return try Sound.exported(result)
    }

    /// Words with pauses between them, over a room's hiss.
    private func speech(seconds: Double, amplitude: Double, hiss: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * Sound.rate))
        var at = 0.5
        var long = false
        while at + 0.5 < seconds {
            Sound.voice(&samples, from: at, to: at + 0.45, amplitude: amplitude)
            at += 0.45 + (long ? 1.2 : 0.35)
            long.toggle()
        }
        if hiss > 0 { Sound.hiss(&samples, rms: hiss) }
        return samples
    }

    // MARK: - The meter

    /// The standard's own check: a 1 kHz sine at −20 dBFS in one channel measures
    /// −23.0 LUFS (its RMS is 3 dB under its peak, and one channel of two).
    @Test func theMeterAgreesWithTheStandard() {
        var mono = [Float](repeating: 0, count: Int(5 * Sound.rate))
        Sound.tone(&mono, frequency: 997, amplitude: 0.1)
        var stereo = [Float](repeating: 0, count: mono.count * 2)
        for i in mono.indices { stereo[i * 2] = mono[i] }
        let loudness = Sound.loudness(ofStereo: stereo) ?? 0
        #expect(abs(loudness - -23.0) < 0.1, "measured \(loudness)")
    }

    // MARK: - Clean up voice

    @Test func rumbleUnderEightyHertzIsTakenOut() async throws {
        var samples = [Float](repeating: 0, count: Int(4 * Sound.rate))
        Sound.voice(&samples, from: 0, to: 4, amplitude: 0.2, syllables: false)
        Sound.tone(&samples, frequency: 50, amplitude: 0.15)
        let folder = try package(voice: samples)
        defer { try? FileManager.default.removeItem(at: folder) }

        let plain = try await render(timeline(seconds: 4, voice: SoundStyle()), in: folder)
        let clean = try await render(timeline(seconds: 4, voice: SoundStyle(cleansVoice: true)), in: folder)
        let before = Sound.left(plain, from: 1, to: 3)
        let after = Sound.left(clean, from: 1, to: 3)

        // Against the voice's own 300 Hz harmonic, so the compressor's share of turning
        // everything down is not counted as taking the rumble out.
        let rumble = (Sound.power(at: 50, in: after) - Sound.power(at: 300, in: after))
            - (Sound.power(at: 50, in: before) - Sound.power(at: 300, in: before))
        #expect(rumble <= -12, "rumble changed by \(rumble) dB")
    }

    @Test func theHissBetweenWordsIsTurnedDown() async throws {
        let samples = speech(seconds: 8, amplitude: 0.2, hiss: 0.003)
        let folder = try package(voice: samples)
        defer { try? FileManager.default.removeItem(at: folder) }

        let plain = try await render(timeline(seconds: 8, voice: SoundStyle()), in: folder)
        let clean = try await render(timeline(seconds: 8, voice: SoundStyle(cleansVoice: true)), in: folder)

        // The first long pause runs from 1.75 to 2.95; its middle is well clear of both words.
        let pause = Sound.rms(Sound.left(clean, from: 2.1, to: 2.7)) - Sound.rms(Sound.left(plain, from: 2.1, to: 2.7))
        let word = Sound.rms(Sound.left(clean, from: 3.05, to: 3.3)) - Sound.rms(Sound.left(plain, from: 3.05, to: 3.3))
        #expect(pause <= -12, "the hiss changed by \(pause) dB")
        #expect(abs(word) < 3, "and a word by \(word) dB")
    }

    /// The source's level slider turns down the cleaned voice; it does not feed the
    /// clean-up a quieter voice, which the expander would take for hiss.
    @Test func theLevelSliderActsAfterTheCleanUp() async throws {
        let samples = speech(seconds: 6, amplitude: 0.2, hiss: 0.003)
        let folder = try package(voice: samples)
        defer { try? FileManager.default.removeItem(at: folder) }

        let full = try await render(timeline(seconds: 6, voice: SoundStyle(cleansVoice: true)), in: folder)
        let half = try await render(timeline(seconds: 6, voice: SoundStyle(gain: 0.25, cleansVoice: true)), in: folder)
        let worst = zip(full, half).map { abs($0 * 0.25 - $1) }.max() ?? 1
        #expect(worst < 0.000_01, "a quarter of the cleaned voice, sample for sample: \(worst)")
    }

    // MARK: - Even out volume

    @Test(arguments: [0.05, 0.9])
    func levellingBringsSpeechToTheTarget(amplitude: Double) async throws {
        let samples = speech(seconds: 10, amplitude: amplitude, hiss: 0.000_5)
        let folder = try package(voice: samples)
        defer { try? FileManager.default.removeItem(at: folder) }

        let plain = try await render(timeline(seconds: 10, voice: SoundStyle()), in: folder)
        let level = try await render(timeline(seconds: 10, voice: SoundStyle(evensVolume: true)), in: folder)
        let both = try await render(timeline(seconds: 10, voice: SoundStyle(cleansVoice: true, evensVolume: true)),
                                    in: folder)

        let before = try #require(Sound.loudness(ofStereo: plain))
        let after = try #require(Sound.loudness(ofStereo: level))
        let cleaned = try #require(Sound.loudness(ofStereo: both))
        #expect(abs(before - Levelling.target) > 4, "the test starts somewhere else: \(before)")
        #expect(abs(after - Levelling.target) <= 1, "levelled to \(after) LUFS from \(before)")
        #expect(abs(cleaned - Levelling.target) <= 1, "cleaned and levelled to \(cleaned) LUFS")
        #expect((level.map { abs($0) }.max() ?? 0) <= 1)
        #expect((both.map { abs($0) }.max() ?? 0) <= 1)
    }

    @Test func noSampleGoesOverFullScale() async throws {
        // Near full scale already, with a spike, then raised: the limiter has to hold it.
        var samples = speech(seconds: 6, amplitude: 0.3, hiss: 0)
        for i in stride(from: Int(1.0 * Sound.rate), to: Int(1.01 * Sound.rate), by: 1) { samples[i] = 0.99 }
        let folder = try package(voice: samples)
        defer { try? FileManager.default.removeItem(at: folder) }

        let levelled = try await render(timeline(seconds: 6, voice: SoundStyle(cleansVoice: true, evensVolume: true)),
                                        in: folder)
        let peak = levelled.map { abs($0) }.max() ?? 0
        #expect(peak <= 1, "peak \(peak)")
        #expect(Double(peak) <= VoiceChain.ceiling + 0.001, "and under the ceiling: \(peak)")
    }

    @Test func theMeasurementIsShownAsTheMixHearsIt() async throws {
        let samples = speech(seconds: 8, amplitude: 0.05, hiss: 0.000_5)
        let folder = try package(voice: samples)
        defer { try? FileManager.default.removeItem(at: folder) }

        let reading = try #require(await SoundAnalyzer.shared.level(of: folder.appendingPathComponent(voicePath),
                                                                     cleansVoice: false))
        let plain = try await render(timeline(seconds: 8, voice: SoundStyle()), in: folder)
        let heard = try #require(Sound.loudness(ofStereo: plain))
        #expect(abs(reading.measured - heard) < 0.5, "shown \(reading.measured), heard \(heard)")
        #expect(abs(reading.gain - (Levelling.target - reading.measured)) < 0.001)
    }

    // MARK: - Lower under speech

    /// Music at 1 kHz and a voice at 150 Hz: a narrow filter at 1 kHz hears only the music.
    private func musicLevels(_ mixed: [Float], at times: [Double]) -> [Double] {
        times.map { Sound.power(at: 1_000, in: Sound.left(mixed, from: $0 - 0.1, to: $0 + 0.1)) }
    }

    private func musicUnder(voice samples: [Float], seconds: Double,
                            captions: [CaptionCue] = []) async throws -> [Float] {
        var music = [Float](repeating: 0, count: Int(seconds * Sound.rate))
        Sound.tone(&music, frequency: 1_000, amplitude: 0.2)
        let folder = try package(voice: samples, music: music)
        defer { try? FileManager.default.removeItem(at: folder) }
        var edit = timeline(seconds: seconds, voice: SoundStyle())
        edit.captions = captions
        edit.audio = [AudioRegion(start: .zero, duration: Sound.time(seconds), path: "Audio/music.wav",
                                  ducksUnderSpeech: true)]
        return try await render(edit, in: folder)
    }

    @Test func musicGoesDownUnderTheCaptionsWords() async throws {
        // A silent voice, so the only speech there is is what the captions say.
        let silent = [Float](repeating: 0, count: Int(8 * Sound.rate))
        let cue = CaptionCue(start: Sound.time(2), duration: Sound.time(2), text: "one two three",
                             words: [.init(text: "one", from: 0, to: 0.3),
                                     .init(text: "two", from: 0.35, to: 0.65),
                                     .init(text: "three", from: 0.7, to: 1)])
        let mixed = try await musicUnder(voice: silent, seconds: 8, captions: [cue])
        let levels = musicLevels(mixed, at: [1.0, 2.5, 3.5, 5.0])
        #expect(levels[1] - levels[0] <= -10, "under the words: \(levels[1] - levels[0]) dB")
        #expect(levels[2] - levels[0] <= -10, "and between them: \(levels[2] - levels[0]) dB")
        #expect(abs(levels[3] - levels[0]) < 0.5, "back to full a second after: \(levels[3] - levels[0]) dB")
    }

    @Test func withoutCaptionsTheMusicListensToTheVoice() async throws {
        var samples = [Float](repeating: 0, count: Int(9 * Sound.rate))
        Sound.voice(&samples, from: 3, to: 5, amplitude: 0.3, syllables: false)
        Sound.hiss(&samples, rms: 0.000_5)
        let mixed = try await musicUnder(voice: samples, seconds: 9)
        let levels = musicLevels(mixed, at: [1.5, 3.5, 4.5, 6.0, 7.5])
        #expect(levels[1] - levels[0] <= -10, "under the voice: \(levels[1] - levels[0]) dB")
        #expect(levels[2] - levels[0] <= -10, "all the way through: \(levels[2] - levels[0]) dB")
        #expect(abs(levels[3] - levels[0]) < 0.5, "full again within a second: \(levels[3] - levels[0]) dB")
        #expect(abs(levels[4] - levels[0]) < 0.5)
    }

    @Test func theDipFollowsTheVoiceThroughACut() async throws {
        // The voice speaks from 5 to 6 s of the recording. Cutting the first 3 s out moves
        // the words to 2–3 s on the timeline, and the dip has to move with them.
        var samples = [Float](repeating: 0, count: Int(9 * Sound.rate))
        Sound.voice(&samples, from: 5, to: 6, amplitude: 0.3, syllables: false)
        var music = [Float](repeating: 0, count: Int(9 * Sound.rate))
        Sound.tone(&music, frequency: 1_000, amplitude: 0.2)
        let folder = try package(voice: samples, music: music)
        defer { try? FileManager.default.removeItem(at: folder) }
        var edit = timeline(seconds: 9, voice: SoundStyle())
        edit.clips = [Clip(sourceStart: Sound.time(3), sourceDuration: Sound.time(6))]
        edit.audio = [AudioRegion(start: .zero, duration: Sound.time(6), path: "Audio/music.wav",
                                  ducksUnderSpeech: true)]
        let mixed = try await render(edit, in: folder)
        let levels = musicLevels(mixed, at: [1.0, 2.5, 4.5])
        #expect(levels[1] - levels[0] <= -10, "at the words' new place: \(levels[1] - levels[0]) dB")
        #expect(abs(levels[2] - levels[0]) < 0.5)
    }

    @Test func aMutedVoiceDucksNothing() async throws {
        var samples = [Float](repeating: 0, count: Int(6 * Sound.rate))
        Sound.voice(&samples, from: 2, to: 4, amplitude: 0.3, syllables: false)
        var music = [Float](repeating: 0, count: Int(6 * Sound.rate))
        Sound.tone(&music, frequency: 1_000, amplitude: 0.2)
        let folder = try package(voice: samples, music: music)
        defer { try? FileManager.default.removeItem(at: folder) }
        var edit = timeline(seconds: 6, voice: SoundStyle(isMuted: true))
        edit.audio = [AudioRegion(start: .zero, duration: Sound.time(6), path: "Audio/music.wav",
                                  ducksUnderSpeech: true)]
        let mixed = try await render(edit, in: folder)
        let levels = musicLevels(mixed, at: [1.0, 3.0])
        #expect(abs(levels[1] - levels[0]) < 0.5)
    }

    // MARK: - A recording with its sound inside the video

    @Test func aRecordingFromBeforeSeparateSourcesIsTreatedAsAWhole() async throws {
        var samples = [Float](repeating: 0, count: Int(6 * Sound.rate))
        Sound.voice(&samples, from: 2, to: 4, amplitude: 0.1, syllables: false)
        Sound.tone(&samples, frequency: 50, amplitude: 0.05)
        var music = [Float](repeating: 0, count: Int(6 * Sound.rate))
        Sound.tone(&music, frequency: 1_000, amplitude: 0.2)
        let folder = try Sound.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Only its audio is read, so a sound file stands in for the video.
        let recording = folder.appendingPathComponent("screen.wav")
        try Sound.write(samples, to: recording)
        try Sound.write(music, to: folder.appendingPathComponent("Audio/music.wav"))

        var edit = Timeline(sourceDuration: Sound.time(6),
                            sound: SoundStyle(cleansVoice: true, evensVolume: true))
        edit.audio = [AudioRegion(start: .zero, duration: Sound.time(6), path: "Audio/music.wav",
                                  ducksUnderSpeech: true)]
        let treated = await AudioMixdown.build(timeline: edit, videoURL: recording, packageURL: folder)
        edit.sound = SoundStyle()
        let plain = await AudioMixdown.build(timeline: edit, videoURL: recording, packageURL: folder)
        let after = try Sound.exported(treated)
        let before = try Sound.exported(plain)

        let voice = Sound.power(at: 300, in: Sound.left(after, from: 2.5, to: 3.5))
            - Sound.power(at: 300, in: Sound.left(before, from: 2.5, to: 3.5))
        let rumble = Sound.power(at: 50, in: Sound.left(after, from: 2.5, to: 3.5))
            - Sound.power(at: 50, in: Sound.left(before, from: 2.5, to: 3.5))
        #expect(voice > 6, "the quiet voice is raised: \(voice) dB")
        #expect(rumble - voice <= -12, "and the rumble taken out: \(rumble - voice) dB")
        let dip = musicLevels(after, at: [3.0])[0] - musicLevels(after, at: [0.8])[0]
        #expect(dip <= -10, "and the music goes down under it: \(dip) dB")
    }

    // MARK: - Old projects

    @Test func anUntreatedSourceIsMixedExactlyAsBefore() async throws {
        let samples = speech(seconds: 4, amplitude: 0.2, hiss: 0.001)
        let folder = try package(voice: samples)
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = await AudioMixdown.build(timeline: timeline(seconds: 4, voice: SoundStyle()),
                                              videoURL: nowhere, packageURL: folder)
        #expect(result.audioMix == nil, "no switch on, nothing in the mix")
        let mixed = try Sound.exported(result)
        let original = Sound.left(mixed, from: 0, to: 4)
        let expected = Array(samples.prefix(original.count))
        let worst = zip(original, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 0.000_1, "the file comes through untouched: \(worst)")
    }

    // MARK: - Preview and export

    @Test @MainActor func thePreviewPlaysTheSamplesTheExportWrites() async throws {
        let samples = speech(seconds: 8, amplitude: 0.1, hiss: 0.002)
        var music = [Float](repeating: 0, count: Int(8 * Sound.rate))
        Sound.tone(&music, frequency: 440, amplitude: 0.2)
        let folder = try package(voice: samples, music: music)
        defer { try? FileManager.default.removeItem(at: folder) }

        var edit = timeline(seconds: 8, voice: SoundStyle(cleansVoice: true, evensVolume: true))
        edit.audio = [AudioRegion(start: .zero, duration: Sound.time(8), path: "Audio/music.wav",
                                  gain: 0.8, fadeIn: 1, ducksUnderSpeech: true)]
        // Two builds, as the editor makes them: one by the preview, one by the exporter.
        let forPreview = await AudioMixdown.build(timeline: edit, videoURL: nowhere, packageURL: folder)
        let forExport = await AudioMixdown.build(timeline: edit, videoURL: nowhere, packageURL: folder)

        let previewed = try await Sound.previewed(forPreview)
        let exported = try Sound.exported(forExport)
        #expect(previewed.count == exported.count)
        #expect(!exported.isEmpty)
        let worst = zip(previewed, exported).map { abs($0 - $1) }.max() ?? 1
        // Equal to the last bit of a float: the mixer's volume ramps are worked out per
        // slice of samples it happens to be handed, and that rounds a hair differently
        // from one read to the next. −130 dB is far under anything audible.
        #expect(worst < 0.000_000_3, "largest difference \(worst)")
        #expect(forPreview.audioMix?.inputParameters.contains { $0.audioTapProcessor != nil } == true,
                "and the preview's item carries the clean-up")
    }
}
