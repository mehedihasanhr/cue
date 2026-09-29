import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// Clips that play a movie brought into the project rather than the recording.
///
/// Two promises are tested here. Every edit that works on a clip of the recording works on
/// one of these, in that file's own time. And nothing measured against the recording — a
/// click, a word, a marker, a run of its sound — ever lands on one.
struct ImportedClipTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func close(_ a: CMTime, _ b: CMTime, within tolerance: Double = 0.002) -> Bool {
        abs((a - b).seconds) < tolerance
    }

    private let movie = MediaFile(path: "Movies/intro.mov", name: "intro.mov", duration: CMTime(value: 5, timescale: 1),
                                  pixelSize: CGSize(width: 1080, height: 1920), hasSound: true)

    /// A twenty-second recording with the five-second movie added at `at`.
    private func timeline(addingAt at: Double = 20, recording seconds: Double = 20) -> Timeline {
        var timeline = Timeline(sourceDuration: time(seconds))
        _ = Commands.AddMedia(movie, at: time(at)).apply(to: &timeline)
        return timeline
    }

    // MARK: - Old projects

    @Test func aProjectWrittenBeforeImportsOpensWithEveryClipPlayingTheRecording() throws {
        let json = """
        {"sourceDuration":{"value":1200,"timescale":60},
         "clips":[{"id":"8A1F0C1E-4C1B-4F3A-9E8D-2B1D6A0F5C11","sourceStart":{"value":0,"timescale":60},
                   "sourceDuration":{"value":1200,"timescale":60},"speed":1}]}
        """
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
        #expect(timeline.clips.count == 1)
        #expect(timeline.clips[0].source == nil)
        #expect(timeline.clips[0].playsRecording)
        #expect(timeline.media.isEmpty)
    }

    /// A clip of the recording is written byte for byte as it was: no `source` key at all.
    @Test func aClipOfTheRecordingIsWrittenWithoutASourceKey() throws {
        let data = try JSONEncoder().encode(Clip(sourceStart: .zero, sourceDuration: time(3)))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("source\""))
    }

    @Test func anImportedClipAndItsFileSurviveASaveAndAReopen() throws {
        let timeline = timeline()
        let data = try JSONEncoder().encode(timeline)
        let reopened = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(reopened == timeline)
        #expect(reopened.clips.last?.source == movie.path)
        #expect(reopened.media == [movie])
    }

    /// One unreadable entry in the list of files costs that entry, not the others or the
    /// edit.
    @Test func anUnreadableFileEntryIsDroppedAndTheRestKept() throws {
        let json = """
        {"sourceDuration":{"value":1200,"timescale":60},
         "media":[{"name":"no path here"},
                  {"path":"Movies/a.mov","duration":{"value":300,"timescale":60}}]}
        """
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
        #expect(timeline.media.map(\.path) == ["Movies/a.mov"])
        #expect(timeline.media[0].name == "a.mov", "the file's own name when none was written")
        #expect(timeline.media[0].hasSound, "looked for rather than assumed away")
    }

    // MARK: - Putting one in

    @Test func addingAtTheEndPutsTheWholeMovieAfterTheRecording() {
        let timeline = timeline()
        #expect(timeline.clips.count == 2)
        #expect(timeline.duration == time(25))
        let added = timeline.clips[1]
        #expect(added.source == movie.path)
        #expect(added.sourceStart == .zero && added.sourceDuration == time(5))
        #expect(timeline.media == [movie])
    }

    @Test func addingAtThePlayheadCutsTheRecordingThereAndPushesTheRestAlong() {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.zooms = [ZoomRegion(start: time(12), duration: time(2))]
        #expect(Commands.AddMedia(movie, at: time(8)).apply(to: &timeline))
        #expect(timeline.clips.map(\.source) == [nil, movie.path, nil])
        #expect(timeline.clips[0].sourceEnd == time(8))
        #expect(timeline.clips[2].sourceStart == time(8))
        #expect(timeline.zooms[0].start == time(17), "a zoom after the playhead moves with its footage")
    }

    @Test func theCommandIsNamedForWhatWasAdded() {
        #expect(Commands.AddMedia(movie, at: .zero).name == "Add Video")
        var take = movie
        take.kind = .recording
        #expect(Commands.AddMedia(take, at: .zero).name == "Add Recording")
    }

    @Test func aMovieTooShortToBeAClipIsRefused() {
        var timeline = Timeline(sourceDuration: time(20))
        var tiny = movie
        tiny.duration = CMTime(value: 1, timescale: 100)
        #expect(!Commands.AddMedia(tiny, at: .zero).apply(to: &timeline))
        #expect(timeline.media.isEmpty, "no record of a file nothing plays")
    }

    // MARK: - Which file, and when

    @Test func overAnImportedClipThereIsNoMomentOfTheRecording() throws {
        let timeline = timeline()
        #expect(timeline.sourceTime(at: time(10)) == time(10))
        #expect(timeline.sourceTime(at: time(22)) == nil, "the pointer from another take has no place here")
        let moment = try #require(timeline.mediaTime(at: time(22)))
        #expect(moment.source == movie.path)
        #expect(moment.time == time(2))
    }

    /// The recording's two seconds in and the movie's two seconds in are different moments,
    /// and only the first is on the timeline as "two seconds into the recording".
    @Test func theRecordingsClockNeverLandsOnAnImportedClip() {
        var timeline = Timeline(sourceDuration: time(20))
        ClipSequence.delete(&timeline, range: CMTimeRange(start: time(0), duration: time(4)))
        _ = Commands.AddMedia(movie, at: .zero).apply(to: &timeline)
        // The recording's 0–4 was cut; the movie, which also has a 0–4, is first.
        #expect(timeline.timelineTime(atSource: time(2)) == nil, "cut from the recording, and the movie is not it")
        #expect(timeline.timelineTime(atSource: time(6)) == time(7))
    }

    /// The clicks are heard where they are seen, and they are never seen on an imported
    /// clip — not even one whose own times cover the click's moment.
    @Test func noClickIsHeardOverAnImportedClip() {
        var timeline = timeline(addingAt: 10)
        timeline.cursor.clickSound = true
        let clicks = [CursorTrack.Click(t: 2, point: .zero, isSecondary: false),
                      CursorTrack.Click(t: 12, point: .zero, isSecondary: false)]
        let heard = timeline.clickSoundMoments(for: clicks).map(\.time)
        #expect(heard.count == 2)
        #expect(close(heard[0], time(2)))
        #expect(close(heard[1], time(17)), "the click at twelve seconds, after the five-second movie")
    }

    @Test func aMarkerHasNoPlaceOnAnImportedClip() {
        let timeline = timeline(addingAt: 0)
        let times = RecordedMarkers.times(of: [MarkerSample(t: 1), MarkerSample(t: 12)], in: timeline)
        #expect(times == [time(6), time(17)])
    }

    @Test func wordsSaidInTheRecordingNeverLandOnAnImportedClip() {
        let timeline = timeline(addingAt: 0)
        #expect(timeline.timelineRanges(ofSource: 1...3) == [CMTimeRange(start: time(6), end: time(8))])
    }

    // MARK: - Every edit

    @Test func splittingAnImportedClipKeepsBothHalvesInItsFile() {
        var timeline = timeline()
        #expect(ClipSequence.split(&timeline, at: time(22)))
        #expect(timeline.clips.count == 3)
        #expect(timeline.clips[1].source == movie.path && timeline.clips[2].source == movie.path)
        #expect(timeline.clips[1].sourceEnd == time(2))
        #expect(timeline.clips[2].sourceStart == time(2) && timeline.clips[2].sourceEnd == time(5))
    }

    /// Trimmed against its own length: the movie is five seconds, the recording twenty.
    @Test func anImportedClipIsTrimmedWithinItsOwnFile() {
        var timeline = timeline()
        let id = timeline.clips[1].id
        #expect(Commands.TrimClip(clipID: id, head: time(1)).apply(to: &timeline))
        #expect(timeline.clips[1].sourceStart == time(1))
        #expect(Commands.TrimClip(clipID: id, head: .zero, tail: time(30)).apply(to: &timeline))
        #expect(timeline.clips[1].sourceEnd == time(5), "not past the end of the movie")
        #expect(timeline.clips[1].sourceStart == .zero)
    }

    @Test func theFramesTrimmedOffAnImportedClipAtTheEndCanBeSelectedBack() {
        var timeline = timeline()
        let id = timeline.clips[1].id
        #expect(Commands.TrimClip(clipID: id, tail: time(4)).apply(to: &timeline))
        #expect(Selection.tailTrim.isValid(in: timeline))
        #expect(Commands.TrimClip(clipID: id, tail: time(5)).apply(to: &timeline))
        #expect(!Selection.tailTrim.isValid(in: timeline), "nothing left of the movie to put back")
    }

    @Test func anImportedClipSpeedsUpInItsOwnTime() {
        var timeline = timeline()
        #expect(Commands.SetSpeed(CMTimeRange(start: time(20), duration: time(5)), speed: 2).apply(to: &timeline))
        #expect(timeline.duration == time(22.5))
        #expect(timeline.mediaTime(at: time(21))?.time == time(2))
        #expect(timeline.mediaTime(at: time(21))?.source == movie.path)
    }

    @Test func deletingAnImportedClipTakesItsTimeAway() {
        var timeline = timeline(addingAt: 10)
        #expect(Commands.DeleteRange(CMTimeRange(start: time(10), duration: time(5))).apply(to: &timeline))
        #expect(timeline.duration == time(20))
        #expect(timeline.clips.allSatisfy { $0.source == nil })
    }

    @Test func anImportedClipMovesInTheOrderLikeAnyOther() {
        var timeline = timeline()
        let id = timeline.clips[1].id
        #expect(Commands.MoveClip(from: 1, to: 0).apply(to: &timeline))
        #expect(timeline.clips[0].id == id)
        #expect(timeline.mediaTime(at: time(1))?.source == movie.path)
        #expect(timeline.sourceTime(at: time(6)) == time(1))
    }

    @Test func aTransitionIntoAnImportedClipIsKept() {
        var timeline = timeline()
        let id = timeline.clips[1].id
        #expect(ClipSequence.setTransition(&timeline, clipID: id, to: ClipTransition(.crossfade)))
        #expect(timeline.clips[1].transition?.style == .crossfade)
        #expect(timeline.transition(at: time(20)) != nil)
    }

    /// A freeze of an imported clip holds that clip's frame — the movie's two seconds, not
    /// the recording's.
    @Test func aFreezeFrameOfAnImportedClipHoldsItsFrame() throws {
        var timeline = timeline()
        #expect(ClipSequence.freeze(&timeline, at: time(22), for: time(2)))
        let still = timeline.clips[2]
        #expect(still.isStill)
        #expect(still.source == movie.path)
        #expect(still.sourceStart == time(2))
        #expect(timeline.sourceTime(at: time(23)) == nil)
        #expect(timeline.mediaTime(at: time(23))?.source == movie.path)
        // And a split of the still keeps both halves on the movie.
        #expect(ClipSequence.split(&timeline, at: time(23)))
        #expect(timeline.clips[3].source == movie.path)
    }

    @Test func copyingAndPastingAnImportedClipCarriesItsFile() throws {
        let timeline = timeline()
        let copy = try #require(CopiedFootage(.clip(timeline.clips[1].id), in: timeline))
        #expect(copy.media == [movie])
        #expect(copy.soundRuns.isEmpty, "its sound is its own, not the recording's")

        // Into the same project after the add was undone: the copy brings the file's
        // record back.
        var undone = Timeline(sourceDuration: time(20))
        #expect(ClipSequence.insert(&undone, copy.freshened(), at: .zero))
        #expect(undone.media == [movie])
        #expect(undone.clips[0].source == movie.path)

        // Across the pasteboard.
        let data = try #require(copy.encoded())
        let decoded = try #require(CopiedFootage.decoded(from: data))
        #expect(decoded == copy)
    }

    /// A movie longer than the recording pastes: its length is measured against its own
    /// file, not the recording's.
    @Test func aMovieLongerThanTheRecordingStillPastes() throws {
        var timeline = Timeline(sourceDuration: time(3))
        #expect(Commands.AddMedia(movie, at: .zero).apply(to: &timeline))
        let copy = try #require(CopiedFootage(.clip(timeline.clips[0].id), in: timeline))
        #expect(copy.sourceEnd == .zero)
        #expect(ClipSequence.insert(&timeline, copy.freshened(), at: timeline.duration))
    }

    @Test func footageNamingAFileNobodyKnowsIsRefused() {
        var timeline = Timeline(sourceDuration: time(20))
        let stray = Clip(sourceStart: .zero, sourceDuration: time(2), source: "Movies/gone.mov")
        #expect(!ClipSequence.insert(&timeline, CopiedFootage(clips: [stray], sourceDuration: time(20)), at: .zero))
        #expect(CopiedFootage(clips: [stray], sourceDuration: time(20)).playsMissingMedia { _ in true })
    }

    // MARK: - Sound

    @Test func detachingLaysNoRunOfTheRecordingOverAnImportedClip() {
        var timeline = timeline(addingAt: 10)
        #expect(ClipSequence.detachSound(&timeline))
        let runs = timeline.detachedSound ?? []
        #expect(runs.count == 2)
        #expect(runs.map(\.start) == [.zero, time(15)])
        #expect(timeline.detachedSoundIsInStepWithClips)
    }

    @Test func addingAMovieToADetachedLaneOpensTimeInIt() {
        var timeline = Timeline(sourceDuration: time(20))
        ClipSequence.detachSound(&timeline)
        #expect(Commands.AddMedia(movie, at: time(10)).apply(to: &timeline))
        let runs = timeline.detachedSound ?? []
        #expect(runs.map(\.start) == [.zero, time(15)], "the recording's sound goes on after the movie")
        #expect(runs.last?.sourceStart == time(10))
    }

    @Test func whichFileAClipPlaysIsPartOfWhatItSoundsLike() {
        let first = timeline()
        var second = first
        second.clips[1].source = "Movies/other.mov"
        #expect(first.audioSignature != second.audioSignature)
        var detached = first
        ClipSequence.detachSound(&detached)
        #expect(!detached.audioSignature.imported.isEmpty, "heard whether or not the lane is detached")
    }

    // MARK: - Excerpts

    @Test func anExcerptOfAnImportedClipKeepsItsFile() {
        let timeline = timeline()
        let cut = timeline.cut(to: CMTimeRange(start: time(21), duration: time(2)))
        #expect(cut.clips.count == 1)
        #expect(cut.clips[0].source == movie.path)
        #expect(cut.clips[0].sourceStart == time(1))
        #expect(cut.media == [movie])
    }
}
