import AVFoundation
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The edited sound.
///
/// Worth testing now for a reason it was not before: this is no longer only what gets
/// written at the end, it is what the editor plays and what the playhead follows. A
/// mixdown that is the wrong length no longer produces a slightly odd file — it produces
/// a preview whose picture and sound disagree.
struct AudioMixdownTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Four seconds of tone, as a file with an audio track and nothing else.
    ///
    /// `AudioMixdown` reads audio tracks from the recording's URL and does not care
    /// whether a picture came with them, so a bare audio file is a faithful stand-in and
    /// far less machinery than encoding video nobody looks at.
    private func tone(seconds: Double = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tone-\(UUID().uuidString).m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
        ])

        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            let phase: Double = 2 * Double.pi * 440 * Double(frame) / 44_100
            samples[frame] = Float(0.25 * sin(phase))
        }
        try file.write(from: buffer)
        return url
    }

    private func duration(of result: AudioMixdown.Result) async throws -> Double {
        let track = try #require(result.composition.tracks(withMediaType: .audio).first)
        return try await track.load(.timeRange).duration.seconds
    }

    @Test func theSoundIsAsLongAsTheEdit() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        let timeline = Timeline(sourceDuration: time(4))
        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)

        #expect(!result.isEmpty)
        #expect(result.composition.tracks(withMediaType: .audio).count == 1)
        #expect(abs(try await duration(of: result) - 4) < 0.1)
    }

    @Test func cuttingTheEditShortensTheSound() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        ClipSequence.split(&timeline, at: time(2))
        timeline.clips.removeLast()

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(abs(timeline.duration.seconds - 2) < 0.01, "the fixture, not the mixdown")
        #expect(abs(try await duration(of: result) - 2) < 0.1)
    }

    /// The case the preview would betray first: sped-up footage whose sound was left at
    /// its original length would run past the end of the picture.
    @Test func speedingTheEditUpShortensTheSoundToMatch() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        timeline.clips[0].speed = 2

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(abs(timeline.duration.seconds - 2) < 0.01, "the fixture, not the mixdown")
        #expect(abs(try await duration(of: result) - 2) < 0.1)
    }

    /// Timeline time is composition time, which is what lets the player's clock be read
    /// as a playhead without any mapping in between. A reordered edit is where that would
    /// break if the two were ever allowed to diverge.
    @Test func theSoundFollowsTheOrderTheClipsAreIn() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        ClipSequence.split(&timeline, at: time(1))
        timeline.clips.reverse()

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(abs(try await duration(of: result) - 4) < 0.1)
    }

    // MARK: - The recording's own level

    /// Muting must reach the exported file, not just the preview. A mute that only
    /// silenced playback would be the worst kind of bug: invisible until somebody
    /// published the video.
    @Test func mutingTheRecordingLeavesNoSoundInTheExport() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        timeline.sound.isMuted = true

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(result.isEmpty, "a muted recording should have no audio track at all")
    }

    @Test func turningTheRecordingDownIsCarriedByTheMix() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        timeline.sound.gain = 0.5

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(!result.isEmpty)
        let mix = try #require(result.audioMix, "a level other than 1 needs a mix to carry it")
        #expect(mix.inputParameters.count == 1)
    }

    /// The ordinary case must not pay for the feature: sound left as recorded needs no
    /// mix at all, and asking AVFoundation for one would be work for nothing.
    @Test func soundLeftAloneNeedsNoMix() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await AudioMixdown.build(timeline: Timeline(sourceDuration: time(4)),
                                              videoURL: url, packageURL: nil)
        #expect(result.audioMix == nil)
    }

    /// The premise the editor's playhead now rests on: this asset can be handed to an
    /// `AVPlayer`, and the time it reports back is timeline time, moving forward.
    ///
    /// Played at zero volume, because a test suite has no business making a noise.
    @MainActor
    @Test func thePlayersClockRunsInTimelineTime() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await AudioMixdown.build(timeline: Timeline(sourceDuration: time(4)),
                                              videoURL: url, packageURL: nil)
        let item = AVPlayerItem(asset: result.composition)
        item.audioMix = result.audioMix
        let player = AVPlayer(playerItem: item)
        player.volume = 0

        player.play()
        // Until it is moving, rather than for a fixed time: the clock is the output
        // device's, and a Bluetooth headset that has gone to sleep takes a second or more
        // to wake. A fixed wait measured the headset, and failed whenever it was asleep.
        let began = Date()
        while player.currentTime().seconds <= 0.05, Date().timeIntervalSince(began) < 6 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let from = player.currentTime().seconds
        let measured = Date()
        try await Task.sleep(for: .milliseconds(600))
        let advanced = player.currentTime().seconds - from
        let elapsed = Date().timeIntervalSince(measured)
        player.pause()

        #expect(player.currentItem?.status == .readyToPlay)
        // Generous on both sides: the point is that it moves, and that it moves in
        // seconds of the edit rather than in some internal scale of its own.
        #expect(from > 0.05, "the clock never started")
        #expect(advanced > elapsed * 0.5, "the clock ran slower than the edit")
        #expect(advanced < elapsed * 2, "the clock advanced far faster than real time")
    }

    @Test func aSilentRecordingHasNoSoundRatherThanAnEmptyTrack() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ExportTests.writeSilentVideo(to: url, size: CGSize(width: 64, height: 64),
                                               frames: 4, frameRate: 4)

        let result = await AudioMixdown.build(timeline: Timeline(sourceDuration: time(1)),
                                              videoURL: url, packageURL: nil)
        #expect(result.isEmpty)
        #expect(result.audioMix == nil)
    }

    // MARK: - The sound lane, cut loose from the picture

    /// Every filled stretch of a composition, as (where it plays, how long, which second
    /// of the source it came from) — which is the whole of what a listener can hear.
    ///
    /// Comparing these rather than a duration is what makes the promise below checkable:
    /// "detaching is inaudible" is a claim about *where every word lands*, and two
    /// compositions of the same length can still differ in all of it.
    private func layout(of result: AudioMixdown.Result) async throws -> [(at: Double, length: Double, from: Double)] {
        var laid: [(at: Double, length: Double, from: Double)] = []
        for track in result.composition.tracks(withMediaType: .audio) {
            for segment in try await track.load(.segments) where !segment.isEmpty {
                laid.append((segment.timeMapping.target.start.seconds,
                             segment.timeMapping.target.duration.seconds,
                             segment.timeMapping.source.start.seconds))
            }
        }
        return laid.sorted { $0.at < $1.at }
    }

    private func same(_ one: [(at: Double, length: Double, from: Double)],
                      _ two: [(at: Double, length: Double, from: Double)]) -> Bool {
        guard one.count == two.count else { return false }
        return zip(one, two).allSatisfy {
            abs($0.at - $1.at) < 0.05 && abs($0.length - $1.length) < 0.05 && abs($0.from - $1.from) < 0.05
        }
    }

    /// The promise the whole feature rests on: the instant after detaching, nothing has
    /// changed. If this fails, nobody can afford to press the menu item in the middle of a
    /// cut — and the failure would be inaudible until they played it back.
    @Test func detachingChangesNothingYouCanHear() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var attached = Timeline(sourceDuration: time(4))
        ClipSequence.split(&attached, at: time(1))
        ClipSequence.split(&attached, at: time(3))
        attached.clips[1].speed = 2

        var detached = attached
        #expect(ClipSequence.detachSound(&detached))

        let one = await AudioMixdown.build(timeline: attached, videoURL: url, packageURL: nil)
        let two = await AudioMixdown.build(timeline: detached, videoURL: url, packageURL: nil)

        #expect(two.composition.tracks(withMediaType: .audio).count
                == one.composition.tracks(withMediaType: .audio).count)
        #expect(abs(two.composition.duration.seconds - one.composition.duration.seconds) < 0.05)
        let before = try await layout(of: one)
        let after = try await layout(of: two)
        #expect(!before.isEmpty, "the fixture, not the mixdown")
        #expect(same(before, after), "detaching moved the sound: \(before) became \(after)")
    }

    /// The narration case: a run slid later has to play later, with silence where it was.
    /// Measured in the asset rather than in the model, because the model has been right
    /// about this since the first test and the composition is where it would be lost.
    @Test func aRunSlidLaterPlaysLater() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        ClipSequence.detachSound(&timeline)
        timeline.detachedSound = [SoundRun(start: time(1), duration: time(2), sourceStart: .zero)]

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        let laid = try await layout(of: result)
        #expect(laid.count == 1)
        let run = try #require(laid.first)
        #expect(abs(run.at - 1) < 0.05, "the run did not start where it said it would")
        #expect(abs(run.length - 2) < 0.1)
        #expect(abs(run.from) < 0.05, "sliding the run re-cut the take")
    }

    /// Lifting a stretch out of the sound alone: the edit stays four seconds long, and the
    /// sound is the length of what is left rather than the length of the picture.
    @Test func aTrimmedLaneIsAsLongAsWhatSurvivedIt() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        ClipSequence.detachSound(&timeline)
        timeline.detachedSound = [SoundRun(start: .zero, duration: time(1), sourceStart: .zero),
                                  SoundRun(start: time(3), duration: time(1), sourceStart: time(3))]

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(abs(timeline.duration.seconds - 4) < 0.01, "the picture is untouched")
        let laid = try await layout(of: result)
        #expect(laid.count == 2)
        #expect(abs(laid[0].at) < 0.05)
        #expect(abs(laid[1].at - 3) < 0.05)
        #expect(abs(laid[1].from - 3) < 0.05)
        // The two seconds in between are silence and belong to nobody: the point of the
        // whole feature is that the picture there is still on screen.
        #expect(laid.allSatisfy { $0.at + $0.length <= 4.1 })
    }

    /// Keeping talking over a cut means two runs covering one moment, which one track
    /// cannot express — so the mixdown opens a second. Without this the later run would
    /// overwrite the earlier one and the overlap would simply be missing.
    @Test func twoRunsOverOneMomentEachGetATrack() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        ClipSequence.detachSound(&timeline)
        timeline.detachedSound = [SoundRun(start: .zero, duration: time(2), sourceStart: .zero),
                                  SoundRun(start: time(1), duration: time(2), sourceStart: time(2))]

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(result.composition.tracks(withMediaType: .audio).count == 2)
        let laid = try await layout(of: result)
        #expect(laid.count == 2)
        #expect(abs(laid[0].at) < 0.05)
        #expect(abs(laid[1].at - 1) < 0.05)
        #expect(abs(laid[1].from - 2) < 0.05)
    }

    /// A speed carried over from the clip it was detached from still plays in the time the
    /// run occupies, which is what `scaleTimeRange` is doing on both branches.
    @Test func aSpedUpRunStillFitsTheTimeItOccupies() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        ClipSequence.detachSound(&timeline)
        timeline.detachedSound = [SoundRun(start: .zero, duration: time(2), sourceStart: .zero, speed: 2)]

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        let laid = try await layout(of: result)
        let run = try #require(laid.first)
        #expect(abs(run.length - 2) < 0.1, "four seconds of source did not fit into two")
    }

    /// Muting is still absence rather than silence, whichever state the lane is in: a
    /// muted detached lane must cost neither the decoding nor a track in the file.
    @Test func aMutedRecordingIsStillAbsentWhenDetached() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        ClipSequence.detachSound(&timeline)
        timeline.sound.isMuted = true

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(result.isEmpty)
    }

    /// A lane whose runs have all been deleted is silence somebody chose, and an export of
    /// it has no audio track rather than an empty one — the same bargain muting makes.
    @Test func aLaneWithNoRunsLeftHasNothingToPlay() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        ClipSequence.detachSound(&timeline)
        timeline.detachedSound = []

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(try await layout(of: result).isEmpty)
    }

    /// Re-attaching gets the picture's sound back exactly, which is the other half of
    /// `detachingChangesNothingYouCanHear` and the reason re-attaching can be a discard
    /// rather than a reconciliation.
    @Test func reAttachingRestoresTheSoundThePictureCuts() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        ClipSequence.split(&timeline, at: time(2))
        let attached = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)

        ClipSequence.detachSound(&timeline)
        timeline.detachedSound?[0].start = time(1)
        ClipSequence.attachSound(&timeline)
        let again = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)

        #expect(same(try await layout(of: attached), try await layout(of: again)))
    }

    // MARK: - Narration laid over the edit

    /// A project package with one take in its `Audio` folder, which is where a voiceover
    /// is copied to and where the mixdown looks for it.
    private func package(holdingTakeOf seconds: Double) throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("package-\(UUID().uuidString)", isDirectory: true)
        let folder = package.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let take = try tone(seconds: seconds)
        try FileManager.default.moveItem(at: take, to: folder.appendingPathComponent("voice.m4a"))
        return package
    }

    /// Where a voiceover ends up, measured rather than assumed.
    ///
    /// This is the seam a punch-in can lie at: the region says it begins two seconds in,
    /// the editor draws it two seconds in, the document saves it two seconds in — and if
    /// the mixdown laid it at zero, everything would look right and sound wrong. The
    /// recording's own sound is muted so the only track in the composition is the take.
    @Test func aVoiceoverLandsWhereItWasPunchedIn() async throws {
        let recording = try tone()
        let package = try package(holdingTakeOf: 1)
        defer {
            try? FileManager.default.removeItem(at: recording)
            try? FileManager.default.removeItem(at: package)
        }

        var timeline = Timeline(sourceDuration: time(4))
        timeline.sound.isMuted = true
        timeline.audio = [AudioRegion(start: time(2), duration: time(1), path: "Audio/voice.m4a")]

        let result = await AudioMixdown.build(timeline: timeline, videoURL: recording, packageURL: package)
        let track = try #require(result.composition.tracks(withMediaType: .audio).first)
        let segments = try await track.load(.segments)
        let filled = try #require(segments.first { !$0.isEmpty }, "the take reached no part of the composition")
        #expect(abs(filled.timeMapping.target.start.seconds - 2) < 0.05)
        #expect(abs(filled.timeMapping.target.duration.seconds - 1) < 0.1)
    }

    /// A take that outran the edit is cut at the edit's end, and the edit does not grow to
    /// hold the rest. The arithmetic for that lives in `TimelineKit`; this is the other
    /// half of the same promise, in the asset that is actually played and written.
    @Test func aTakeTrimmedAtTheEndDoesNotLengthenTheSound() async throws {
        let recording = try tone()
        let package = try package(holdingTakeOf: 4)
        defer {
            try? FileManager.default.removeItem(at: recording)
            try? FileManager.default.removeItem(at: package)
        }

        var timeline = Timeline(sourceDuration: time(4))
        let placement = try #require(timeline.voiceoverPlacement(punchedInAt: time(3), recorded: time(4)))
        #expect(placement.wasTrimmed)
        timeline.audio = [AudioRegion(start: placement.start, duration: placement.duration,
                                      path: "Audio/voice.m4a")]

        let result = await AudioMixdown.build(timeline: timeline, videoURL: recording, packageURL: package)
        for track in result.composition.tracks(withMediaType: .audio) {
            let range = try await track.load(.timeRange)
            #expect(range.end.seconds <= 4.1, "the sound runs past the end of the edit")
        }
    }
}
