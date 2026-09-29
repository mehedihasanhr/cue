import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Regressions for defects found by review: excerpt fades, merged caption timings, pasted
/// pictures and click sounds outside the crop.
struct ReviewFixTests {
    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    // MARK: - An excerpt's fades carry on from the full edit

    private func music() -> AudioRegion {
        AudioRegion(start: t(0), duration: t(60), path: "Sounds/music.m4a", fadeIn: 5, fadeOut: 3)
    }

    @Test func anExcerptStartsPartWayUpTheFadeIn() throws {
        var timeline = Timeline(sourceDuration: t(60))
        timeline.audio = [music()]
        let full = music()
        let piece = try #require(timeline.cut(to: CMTimeRange(start: t(2), end: t(20))).audio.first)
        for seconds in stride(from: 2.0, to: 20, by: 0.5) {
            #expect(abs(piece.envelope(at: t(seconds - 2)) - full.envelope(at: t(seconds))) < 0.001, "at \(seconds)")
        }
        #expect(abs(piece.shape(at: piece.start) - 0.4) < 0.001)
        // Nowhere near the fade out, so it ends at full level.
        #expect(abs(piece.shape(at: piece.end) - 1) < 0.001)
    }

    @Test func anExcerptEndingInsideTheFadeOutEndsPartWayDown() throws {
        var timeline = Timeline(sourceDuration: t(60))
        timeline.audio = [music()]
        let piece = try #require(timeline.cut(to: CMTimeRange(start: t(30), end: t(58.5))).audio.first)
        #expect(abs(piece.shape(at: piece.end) - 0.5) < 0.001)
        #expect(piece.fadeCorners.map(\.seconds).contains { abs($0 - 27) < 0.001 }, "the fade out starts 57 s into the edit")
    }

    @Test func aPieceInsideBothFadesPeaksWhereTheyMeet() {
        // Two-second fades on a four-second sound, and the middle two seconds of it: it
        // starts halfway up the fade in, reaches full level only at its midpoint, and
        // ends halfway down the fade out.
        var short = AudioRegion(start: t(0), duration: t(2), path: "a", fadeIn: 2, fadeOut: 2)
        short.leadIn = 1
        short.leadOut = 1
        #expect(short.fadeCorners.map(\.seconds) == [0, 1, 2])
        #expect(abs(short.shape(at: t(0)) - 0.5) < 0.001)
        #expect(abs(short.shape(at: t(1)) - 1) < 0.001)
        #expect(abs(short.shape(at: t(2)) - 0.5) < 0.001)
    }

    @Test func duckingStartsFromTheCarriedOnLevel() {
        var piece = music()
        piece.leadIn = 2
        piece.duration = t(18)
        let points = Ducking.envelope(for: piece, speech: [])
        #expect(abs((points.first?.volume ?? 0) - 0.4) < 0.001)
    }

    @Test func aWholeSoundIsUnchanged() {
        let whole = music()
        #expect(whole.shape(at: whole.start) == 0)
        #expect(abs(whole.shape(at: t(2.5)) - 0.5) < 0.001)
        #expect(whole.shape(at: whole.end) == 0)
        #expect(whole.fadeCorners.map(\.seconds) == [0, 5, 57, 60])
    }

    // MARK: - Merging keeps recorded timings only when both lines have them

    @Test func mergingAHandCorrectedLineDropsGuessedTimings() {
        var timeline = Timeline(sourceDuration: t(10))
        var first = CaptionCue(start: t(0), duration: t(3), text: "so um yeah",
                               words: [.init(text: "so", from: 0, to: 0.2),
                                       .init(text: "um", from: 0.6, to: 0.7),
                                       .init(text: "yeah", from: 0.8, to: 1)])
        first.text = "so um yes"
        let second = CaptionCue(start: t(3), duration: t(2), text: "right then",
                                words: [.init(text: "right", from: 0, to: 0.4), .init(text: "then", from: 0.5, to: 1)])
        timeline.captions = [first, second]
        #expect(Commands.MergeCaptions(id: first.id).apply(to: &timeline))
        let merged = timeline.captions[0]
        #expect(merged.words.isEmpty || merged.words != merged.timedWords)
        #expect(TranscriptEditing.fillerRanges(in: timeline).isEmpty)
    }

    // MARK: - Pictures whose files are elsewhere

    @Test func footageLeavesOutPicturesItCannotFind() {
        let here = AnnotationItem(start: t(0), duration: t(2), kind: .image(path: "Images/here.png"),
                                  rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let there = AnnotationItem(start: t(0), duration: t(2), kind: .image(path: "Images/there.png"),
                                   rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let words = AnnotationItem(start: t(0), duration: t(2), kind: .text("Hi"),
                                   rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let footage = CopiedFootage(clips: [Clip(sourceStart: t(0), sourceDuration: t(2))],
                                    annotations: [here, there, words], sourceDuration: t(10))
        let kept = footage.withoutPictures { $0 == "Images/there.png" }
        #expect(kept.annotations.map(\.id) == [here.id, words.id])
        #expect(CopiedRegion.annotation(there).picturePath == "Images/there.png")
        #expect(CopiedRegion.annotation(words).picturePath == nil)
    }

    // MARK: - Clicks outside the crop are not heard

    @Test func clicksOutsideTheCropAreDropped() {
        var timeline = Timeline(sourceDuration: t(10))
        timeline.style.crop = CropRect(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let clicks = [CursorTrack.Click(t: 1, point: CGPoint(x: 100, y: 300), isSecondary: false),
                      CursorTrack.Click(t: 2, point: CGPoint(x: 1_200, y: 300), isSecondary: false)]
        let seen = timeline.visibleClicks(clicks, frame: CGSize(width: 1_440, height: 900))
        #expect(seen.map(\.t) == [2])
        timeline.style.crop = nil
        #expect(timeline.visibleClicks(clicks, frame: CGSize(width: 1_440, height: 900)).count == 2)
    }

    @Test func croppingChangesWhatThePreviewHears() {
        var timeline = Timeline(sourceDuration: t(10))
        timeline.cursor.clickSound = true
        let before = timeline.audioSignature
        timeline.style.crop = CropRect(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(timeline.audioSignature != before)
    }
}
