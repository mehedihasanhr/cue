import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// Exporting part of a video: the excerpt's frames are the whole video's frames.
struct ExcerptTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 1_600, height: 1_000)

    /// An edit with something happening across every edge of the range 10…25: a glide
    /// between two zooms astride the start, a caption and a pointer stretch astride the
    /// end, a speed change in the middle, and a pointer wandering throughout.
    private func timeline() -> Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        ClipSequence.split(&timeline, at: time(20))
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(20), end: time(40)), speed: 2)
        timeline.cursor.smoothing = 0
        timeline.zooms = [ZoomRegion(start: time(5), duration: time(4.8), scale: 3, transition: time(0.5)),
                          ZoomRegion(start: time(10.2), duration: time(4), scale: 2,
                                     center: CGPoint(x: 0.7, y: 0.6), transition: time(0.5), followsCursor: false),
                          ZoomRegion(start: time(23), duration: time(6), scale: 2.5, transition: time(1))]
        timeline.captions = [CaptionCue(start: time(9), duration: time(3), text: "astride the start"),
                             CaptionCue(start: time(24), duration: time(3), text: "astride the end")]
        timeline.cursorRegions = [CursorRegion(start: time(24.5), duration: time(2))]
        timeline.annotations = [AnnotationItem(start: time(8), duration: time(5), kind: .rectangle,
                                               rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                                               animation: AnnotationAnimation(entrance: .pop, exit: .fade))]
        return timeline
    }

    private func track() -> CursorTrack {
        var samples: [CursorSample] = []
        for step in 0...(60 * 30) {
            let t = Double(step) / 30
            samples.append(CursorSample(t: t, x: 100 + 600 * (0.5 + 0.5 * sin(t / 3)),
                                        y: 250 + 200 * cos(t / 5), shape: .arrow))
        }
        return CursorTrack(samples: samples)
    }

    /// Every frame of the excerpt, described, is the same frame of the whole video —
    /// camera, pointer, captions, everything.
    @Test func everyFrameOfTheExcerptIsAFrameOfTheWhole() {
        let whole = timeline()
        let range = CMTimeRange(start: time(10), end: time(25))
        let cut = whole.cut(to: range)
        let builder = SceneBuilder(videoSize: videoSize, displayScale: 2)
        let pointer = track()

        for frame in 0...(15 * 30) {
            let at = CMTime(value: CMTimeValue(frame), timescale: 30)
            let excerpt = builder.descriptor(for: cut, at: at, cursor: pointer)
            let original = builder.descriptor(for: whole, at: at + range.start, cursor: pointer)
            #expect(excerpt == original, "frame \(frame) differs")
        }
    }

    /// The first frame lands in the gap between two zooms that glide, and shows the
    /// glide: the camera is still in, never at the whole picture, even though the first
    /// zoom has ended and the second has not begun.
    @Test func theFirstFrameCanBeMidGlide() {
        let whole = timeline()
        let cut = whole.cut(to: CMTimeRange(start: time(10), end: time(25)))
        let scene = SceneBuilder(videoSize: videoSize, displayScale: 2).descriptor(for: cut, at: .zero)
        #expect(scene.zoom >= 2 && scene.zoom <= 3)
        #expect(cut.zooms[0].end < .zero, "the first zoom is over")
        #expect(cut.zooms[1].start > .zero, "and the second has not started")
    }

    /// And through the exporter, against a real file: the excerpt is as long as the
    /// range and no longer.
    @Test func anExcerptExportsAtItsOwnLength() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        let sourceSize = CGSize(width: 640, height: 360)
        try await ExportTests.writeSilentVideo(to: source, size: sourceSize, frames: 60, frameRate: 30)

        var whole = Timeline(sourceDuration: time(2))
        whole.style.padding = 0
        let cut = whole.cut(to: CMTimeRange(start: time(0.5), end: time(1.5)))
        #expect(cut.duration == time(1))

        var settings = ExportSettings(format: .mp4, frameRate: 30, includesAudio: false)
        settings.maximumDimension = 320
        let destination = folder.appendingPathComponent("excerpt.mp4")
        try await VideoExporter(timeline: cut,
                                builder: SceneBuilder(videoSize: sourceSize),
                                cursor: nil,
                                videoURL: source,
                                packageURL: nil,
                                settings: settings).export(to: destination)

        let duration = try await AVURLAsset(url: destination).load(.duration)
        #expect(abs(duration.seconds - 1) < 0.1)
    }
}
