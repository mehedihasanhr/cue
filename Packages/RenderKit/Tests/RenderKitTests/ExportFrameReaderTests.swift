import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import RenderKit

/// Which frame the exporter's reader hands back for a moment.
/// Serialized and time-limited: these read and write real movies, and many decoders and
/// encoders at once — this suite in parallel with itself, beside other test runs — can
/// leave AVFoundation waiting for a frame that never comes. One at a time, and a stall
/// fails in minutes rather than hanging the run.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ExportFrameReaderTests {
    /// The frame showing at a moment is the last one to have started by then — the rule the
    /// preview's `FrameSource` follows. The reader used to hand back the one after it:
    /// decoded samples carry no duration, so "when this frame ends" came out as when it
    /// began, and it walked one frame too far. Every exported frame was a frame early
    /// against the preview, the pointer and anything followed on the picture.
    @Test func handsBackTheFrameShowingAtEachMoment() async throws {
        let footage = FollowingFootage.moving(frames: 12) { CGPoint(x: 100 + 40 * $0, y: 300) }
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("footage.mov")
        try await footage.write(to: url)

        let reader = try await ExportFrameReader(url: url)
        _ = await reader.naturalSize()
        let context = CIContext()
        // Each frame as it was drawn, to recognise the decoded ones by.
        let drawn = try (0..<12).map { try #require(LumaPlane(footage.image($0), scale: 1, context: context)) }
        for frame in 0..<12 {
            // Exactly on the frame, and half way through it — as a rational, so the moment is
            // the frame's own timestamp and not a rounding of it.
            for into in [0, 1] {
                let time = CMTime(value: CMTimeValue(2 * frame + into), timescale: 60)
                let image = try #require(try reader.frame(at: time))
                let plane = try #require(LumaPlane(image, scale: 1, context: context))
                let whole = LumaPatch(width: plane.width, height: plane.height, pixels: plane.pixels)
                let nearest = drawn.indices.min { a, b in
                    (drawn[a].difference(whole, at: (0, 0), rowStep: 4) ?? .infinity)
                        < (drawn[b].difference(whole, at: (0, 0), rowStep: 4) ?? .infinity)
                }
                #expect(nearest == frame, "at frame \(frame) + \(into) half-frames")
            }
        }
    }

    /// Frames handed back are the reader's own, not the decoder's. Holding every frame read —
    /// as renders still queued on the GPU do — used to use up the decoder's few buffers, and
    /// the next read waited for one to come back for ever: exports and test runs hung.
    @Test func framesHeldDoNotStallTheDecoder() async throws {
        let footage = FollowingFootage.moving(frames: 60) { CGPoint(x: 100 + 8 * $0, y: 300) }
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("footage.mov")
        try await footage.write(to: url)

        let reader = try await ExportFrameReader(url: url)
        _ = await reader.naturalSize()
        var held: [CIImage] = []
        for frame in 0..<60 {
            let image = try #require(try reader.frame(at: CMTime(value: CMTimeValue(2 * frame), timescale: 60)))
            held.append(image)
        }
        #expect(held.count == 60)
        // Each held frame is still the picture it was: none was written over by a later one.
        let context = CIContext()
        let first = try #require(LumaPlane(held[0], scale: 1, context: context))
        let last = try #require(LumaPlane(held[59], scale: 1, context: context))
        let whole = LumaPatch(width: last.width, height: last.height, pixels: last.pixels)
        #expect((first.difference(whole, at: (0, 0), rowStep: 4) ?? 0) > 0)
    }

    /// A decoder that stalls is replaced by a reader opened just after the last frame, and
    /// the frames carry on in order with none repeated or skipped. It used to wait for
    /// ever: an export stuck at a percentage, a test run that never finished.
    @Test func carriesOnAfterTheDecoderStalls() async throws {
        let footage = FollowingFootage.moving(frames: 12) { CGPoint(x: 100 + 40 * $0, y: 300) }
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("footage.mov")
        try await footage.write(to: url)

        let reader = try await ExportFrameReader(url: url)
        _ = await reader.naturalSize()
        let context = CIContext()
        let drawn = try (0..<12).map { try #require(LumaPlane(footage.image($0), scale: 1, context: context)) }
        for frame in 0..<12 {
            // A stall in the middle of the file, then one right after it.
            if frame == 5 || frame == 6 { reader.simulatedStalls = 1 }
            let image = try #require(try reader.frame(at: CMTime(value: CMTimeValue(2 * frame), timescale: 60)))
            let plane = try #require(LumaPlane(image, scale: 1, context: context))
            let whole = LumaPatch(width: plane.width, height: plane.height, pixels: plane.pixels)
            let nearest = drawn.indices.min { a, b in
                (drawn[a].difference(whole, at: (0, 0), rowStep: 4) ?? .infinity)
                    < (drawn[b].difference(whole, at: (0, 0), rowStep: 4) ?? .infinity)
            }
            #expect(nearest == frame, "frame \(frame)")
        }
    }

    /// A decoder that stalls again straight after being replaced is reported, not waited on.
    @Test func secondStallInARowIsAnError() async throws {
        let footage = FollowingFootage.moving(frames: 12) { CGPoint(x: 100 + 40 * $0, y: 300) }
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("footage.mov")
        try await footage.write(to: url)

        let reader = try await ExportFrameReader(url: url)
        _ = await reader.naturalSize()
        _ = try reader.frame(at: .zero)
        reader.simulatedStalls = 2
        #expect(throws: ExportError.self) {
            _ = try reader.frame(at: CMTime(value: 10, timescale: 60))
        }
    }
}
