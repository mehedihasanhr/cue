import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// Moving a clip to another place in the order, with what was placed on it.
///
/// It used to move only the clip. Everything on the other lanes stayed where it was in
/// time, so the zoom on a click landed on whatever footage slid under it.
struct ClipReorderTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func close(_ a: CMTime, _ b: CMTime, within tolerance: Double = 0.002) -> Bool {
        abs((a - b).seconds) < tolerance
    }

    /// A 30-second take in three ten-second clips: A, B, C.
    private func threeClips() -> Timeline {
        var timeline = Timeline(sourceDuration: time(30))
        ClipSequence.split(&timeline, at: time(10))
        ClipSequence.split(&timeline, at: time(20))
        return timeline
    }

    @Test func aZoomOnAClipGoesWhereTheClipGoes() {
        var timeline = threeClips()
        let zoom = ZoomRegion(start: time(22), duration: time(3))   // on C
        timeline.zooms = [zoom]
        let c = timeline.clips[2].id

        #expect(ClipSequence.move(&timeline, from: 2, to: 0))
        #expect(timeline.clips[0].id == c)
        #expect(timeline.zooms.count == 1)
        #expect(timeline.zooms[0].id == zoom.id, "the same zoom, so a selection on it survives")
        #expect(timeline.zooms[0].start == time(2), "two seconds into C, wherever C is")
        #expect(timeline.sourceTime(at: timeline.zooms[0].start) == time(22), "still on the same frame")
    }

    /// Every lane, not only zooms — and what was on the clips that did not move stays on
    /// them too, after they have shifted.
    @Test func everyLaneStaysOnItsFootage() {
        var timeline = threeClips()
        let rect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        timeline.blurs = [BlurRegion(start: time(1), duration: time(2), rect: rect)]          // A
        timeline.captions = [CaptionCue(start: time(12), duration: time(3), text: "on B")]     // B
        timeline.annotations = [AnnotationItem(start: time(25), duration: time(2), kind: .text("on C"), rect: rect)]
        timeline.cursorRegions = [CursorRegion(start: time(14), duration: time(1), isHidden: true)]
        timeline.keyCues = [KeyCue(start: time(27), duration: time(1), modifiers: [.command], key: "S")]

        #expect(ClipSequence.move(&timeline, from: 0, to: 2))            // B, C, A

        func source(_ start: CMTime) -> CMTime? { timeline.sourceTime(at: start) }
        #expect(source(timeline.blurs[0].start) == time(1))
        #expect(source(timeline.captions[0].start) == time(12))
        #expect(source(timeline.annotations[0].start) == time(25))
        #expect(source(timeline.cursorRegions[0].start) == time(14))
        #expect(source(timeline.keyCues[0].start) == time(27))
        #expect(timeline.duration == time(30))
    }

    /// A region across the clip's edge stays behind, shortened by the part the clip took.
    @Test func aRegionAcrossTheClipsEdgeStaysBehindShortened() {
        var timeline = threeClips()
        timeline.zooms = [ZoomRegion(start: time(8), duration: time(4))]    // 8…12, across A|B
        #expect(ClipSequence.move(&timeline, from: 1, to: 2))              // A, C, B
        #expect(timeline.zooms.count == 1)
        #expect(timeline.zooms[0].start == time(8))
        #expect(timeline.zooms[0].duration == time(2), "only the part over A is left")
    }

    /// Detached, the sound over the clip travels with it; nothing is heard twice or lost.
    @Test func aDetachedLanesWordsGoWithTheirPicture() throws {
        var timeline = threeClips()
        ClipSequence.detachSound(&timeline)
        #expect(ClipSequence.move(&timeline, from: 2, to: 0))              // C, A, B
        let runs = try #require(timeline.detachedSound).sorted { $0.start < $1.start }
        #expect(runs.count == 3)
        for run in runs {
            #expect(timeline.sourceTime(at: run.start) == run.sourceStart,
                    "each run plays the sound of the picture over it")
        }
        #expect(timeline.detachedSoundIsInStepWithClips)
    }

    /// Attached, the sound follows the clips by construction, so the signature changes and
    /// the preview rebuilds.
    @Test func movingAClipChangesTheSound() {
        var timeline = threeClips()
        let before = timeline.audioSignature
        ClipSequence.move(&timeline, from: 0, to: 1)
        #expect(timeline.audioSignature != before)
    }

    @Test func movingAFreezeFrameOrATitleKeepsItWhole() {
        var timeline = threeClips()
        ClipSequence.freeze(&timeline, at: time(5), for: time(2))          // A1, still, A2, B, C
        _ = Commands.AddTitle(at: .zero).apply(to: &timeline)                   // title, A1, still, …
        let title = timeline.clips[0]
        let still = timeline.clips[2]

        #expect(ClipSequence.move(&timeline, from: 2, to: 0))
        #expect(timeline.clips[0] == still)
        #expect(ClipSequence.move(&timeline, from: 1, to: timeline.clips.count - 1))
        #expect(timeline.clips.last == title)
        #expect(timeline.duration == time(35))
    }

    @Test func movingToWhereItAlreadyIsIsNotAnEdit() {
        var timeline = threeClips()
        let before = timeline
        #expect(!ClipSequence.move(&timeline, from: 1, to: 1))
        #expect(!ClipSequence.move(&timeline, from: 5, to: 0))
        #expect(timeline == before)
    }

    @Test func aDestinationPastTheEndMeansTheEnd() {
        var timeline = threeClips()
        let a = timeline.clips[0].id
        #expect(ClipSequence.move(&timeline, from: 0, to: 99))
        #expect(timeline.clips.last?.id == a)
    }

    /// A clip at another speed moves with its speed and its regions.
    @Test func aSpedUpClipMovesWithItsRegions() {
        var timeline = threeClips()
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(10), end: time(20)), speed: 2)
        timeline.zooms = [ZoomRegion(start: time(12), duration: time(1))]   // 4 s into B's source
        #expect(ClipSequence.move(&timeline, from: 1, to: 0))
        #expect(timeline.clips[0].speed == 2)
        #expect(timeline.zooms[0].start == time(2))
        #expect(close(timeline.sourceTime(at: timeline.zooms[0].start) ?? .zero, time(14)))
    }

    /// A transition belongs to the clip that arrives with it, so it goes too.
    @Test func aClipsEntranceGoesWithIt() {
        var timeline = threeClips()
        let c = timeline.clips[2].id
        ClipSequence.setTransition(&timeline, clipID: c, to: ClipTransition(.crossfade))
        #expect(ClipSequence.move(&timeline, from: 2, to: 1))
        #expect(timeline.clips[1].transition?.style == .crossfade)
    }

    // MARK: - One step on the undo stack

    @MainActor
    @Test func aMoveIsOneUndo() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KlikStudioTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try RecordingPackage.create(named: "Take", in: folder)
        try package.write(RecordingManifest(name: "Take", duration: 30))
        let document = try EditorDocument(package: package)
        document.apply(Commands.Split(at: time(10)))
        document.apply(Commands.AddZoom(ZoomRegion(start: time(12), duration: time(2))))
        let before = document.timeline

        #expect(document.apply(Commands.MoveClip(from: 1, to: 0)))
        #expect(document.undoName == "Move Clip")
        document.undo()
        #expect(document.timeline == before)
    }
}
