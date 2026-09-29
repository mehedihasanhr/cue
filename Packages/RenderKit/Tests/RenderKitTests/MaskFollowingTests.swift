import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// Following a mask on footage where the truth is known: a patch moving in a line,
/// jumping, scrolling in a page, leaving the frame. Measured in pixels of the 1280 × 720
/// recording, frame by frame, against where the patch really is.
/// Serialized and time-limited: these read and write real movies, and many decoders and
/// encoders at once — this suite in parallel with itself, beside other test runs — can
/// leave AVFoundation waiting for a frame that never comes. One at a time, and a stall
/// fails in minutes rather than hanging the run.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct MaskFollowingTests {
    private let size = FollowingFootage.size
    private let rate = Double(FollowingFootage.frameRate)

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    private func frameTime(_ frame: Int) -> CMTime { CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(rate)) }

    private func normalised(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
               width: rect.width / size.width, height: rect.height / size.height)
    }

    private func pixels(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }

    /// Writes the footage, follows a mask put over the truth at `from`, and hands back the
    /// followed mask.
    private func follow(_ footage: FollowingFootage, from frame: Int,
                        style: BlurRegion.Style = .cover) async throws -> (BlurRegion, Timeline) {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("footage.mov")
        try await footage.write(to: url)

        var timeline = Timeline(sourceDuration: frameTime(footage.frames))
        var mask = BlurRegion(start: .zero, duration: frameTime(footage.frames),
                              rect: normalised(footage.truth(frame)), style: style,
                              color: ColorValue(r: 0, g: 1, b: 0))
        timeline.blurs = [mask]
        let clock = ContinuousClock()
        let began = clock.now
        let result = try await MaskFollower.follow(mask, in: timeline, from: frameTime(frame),
                                                   videoURL: url, frameRate: rate)
        print("Following · \(footage.frames) frames in \(clock.now - began)")
        #expect(result.rect == mask.rect)
        mask.rect = result.rect
        mask.path = result.path
        timeline.blurs = [mask]
        return (mask, timeline)
    }

    /// The worst distance, in pixels, between where the mask is and where the patch is, over
    /// the frames `frames` — and a check that the mask kept its size throughout.
    private func worstError(_ mask: BlurRegion, _ footage: FollowingFootage, frames: some Sequence<Int>,
                            truth: (Int) -> CGRect? = { _ in nil }) -> Double {
        var worst = 0.0
        for frame in frames {
            let shown = pixels(mask.rect(at: frameTime(frame)))
            let real = truth(frame) ?? footage.truth(frame)
            worst = max(worst, abs(shown.minX - real.minX), abs(shown.minY - real.minY))
            #expect(abs(shown.width - real.width) < 0.01 && abs(shown.height - real.height) < 0.01,
                    "the mask keeps its size at frame \(frame)")
        }
        return worst
    }

    // MARK: - Where it goes

    @Test func followsAPatchMovingInAStraightLine() async throws {
        let footage = FollowingFootage.moving(frames: 60) { CGPoint(x: 100 + 5 * $0, y: 300 + 2 * $0) }
        let (mask, _) = try await follow(footage, from: 20)
        let error = worstError(mask, footage, frames: 0..<60)
        print("Following · straight line: worst \(error) px, \(mask.path?.keys.count ?? 0) keys")
        #expect(error <= 2)
        #expect(mask.path?.losses.isEmpty == true)
        // A straight line is a straight line: a handful of keys, not sixty.
        #expect((mask.path?.keys.count ?? 99) <= 4)
    }

    @Test func followsAJumpAsAJump() async throws {
        let footage = FollowingFootage.moving(frames: 50) { $0 < 25 ? CGPoint(x: 300, y: 300) : CGPoint(x: 760, y: 470) }
        let (mask, _) = try await follow(footage, from: 10)
        let error = worstError(mask, footage, frames: 0..<50)
        print("Following · jump: worst \(error) px, \(mask.path?.keys.count ?? 0) keys")
        #expect(error <= 2)
        // Still on the old place for the whole of the frame before, on the new one from the
        // frame it jumps: never halfway.
        let before = pixels(mask.rect(at: frameTime(25) - CMTime(value: 1, timescale: 600)))
        #expect(abs(before.minX - 300) <= 2)
        #expect(abs(pixels(mask.rect(at: frameTime(25))).minX - 760) <= 2)
    }

    @Test func followsALineOfAPageScrollingUp() async throws {
        let line = CGRect(x: 20, y: 610, width: 220, height: 30)
        let footage = FollowingFootage.scrolling(frames: 60, speed: 7, list: false, line: line)
        let (mask, _) = try await follow(footage, from: 30)
        let error = worstError(mask, footage, frames: 0..<60)
        print("Following · page scroll: worst \(error) px, \(mask.path?.keys.count ?? 0) keys")
        #expect(error <= 2)
    }

    @Test func followsARowOfALookAlikeListScrolling() async throws {
        let line = CGRect(x: 20, y: 442, width: 300, height: 34)
        let footage = FollowingFootage.scrolling(frames: 45, speed: 9, list: true, line: line)
        let (mask, _) = try await follow(footage, from: 0)
        let error = worstError(mask, footage, frames: 0..<45)
        print("Following · list scroll: worst \(error) px")
        #expect(error <= 2)
    }

    @Test func followsAWindowBeingDragged() async throws {
        let footage = FollowingFootage.draggedWindow(frames: 60)
        let (mask, _) = try await follow(footage, from: 30)
        let error = worstError(mask, footage, frames: 0..<60)
        print("Following · dragged window: worst \(error) px, \(mask.path?.keys.count ?? 0) keys")
        #expect(error <= 3)
    }

    /// Out of the right-hand side at 12 px a frame. The mask follows it to the edge and
    /// stops there, the size it was, and says where it lost it.
    @Test func stopsAtTheEdgeWhenThePatchLeaves() async throws {
        let footage = FollowingFootage.moving(frames: 45) { CGPoint(x: 880 + 12 * $0, y: 200) }
        let (mask, _) = try await follow(footage, from: 5)
        // Until it touches the edge, on it exactly; after, held at the edge — which is where
        // what is left of it in the picture is.
        let edge = size.width - 220
        let error = worstError(mask, footage, frames: 0..<45) { frame in
            let real = footage.truth(frame)
            return CGRect(x: min(real.minX, edge), y: real.minY, width: real.width, height: real.height)
        }
        print("Following · leaving the frame: worst \(error) px, lost at \(mask.path?.losses ?? [])")
        #expect(error <= 2)
        let loss = try #require(mask.path?.losses.first)
        // 35% of it is still in the picture at x = 1280 - 77 = 1203, which it passes at
        // frame 27.
        #expect(abs(loss - 27 / rate) <= 2 / rate)
        #expect(pixels(mask.rect(at: frameTime(44))).maxX <= size.width + 0.01)
    }

    // MARK: - What it draws

    /// The followed mask, rendered over the real frames: green where the patch is at several
    /// moments, and not over where it used to be.
    @Test func theRenderedMaskCoversTheMovingPatch() async throws {
        let footage = FollowingFootage.moving(frames: 60) { CGPoint(x: 100 + 5 * $0, y: 300 + 2 * $0) }
        var (_, timeline) = try await follow(footage, from: 20)
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = false
        let builder = SceneBuilder(videoSize: size, displayScale: 1)

        for frame in [0, 15, 30, 45, 59] {
            let scene = builder.descriptor(for: timeline, at: frameTime(frame))
            let image = try #require(SceneRenderer().cgImage(for: scene, source: footage.image(frame)))
            let real = footage.truth(frame)
            for (fx, fy) in [(0.5, 0.5), (0.1, 0.2), (0.9, 0.8)] {
                let pixel = try #require(Self.pixel(image, x: real.minX + real.width * fx, y: real.minY + real.height * fy))
                #expect(pixel.g > 240 && pixel.r < 15 && pixel.b < 15, "covered at frame \(frame)")
            }
            if frame >= 30 {
                // Where it was at the start is page again.
                let old = footage.truth(0)
                let pixel = try #require(Self.pixel(image, x: old.midX, y: old.midY))
                #expect(!(pixel.g > 240 && pixel.r < 15), "not left behind at frame \(frame)")
            }
        }
    }

    /// The layer the renderer is handed is the mask where it is at that moment — the one
    /// place the preview and the export both read.
    @Test func theSceneCarriesTheMaskWhereItIsNow() async throws {
        let footage = FollowingFootage.moving(frames: 30) { CGPoint(x: 100 + 5 * $0, y: 300) }
        let (mask, timeline) = try await follow(footage, from: 0)
        let builder = SceneBuilder(videoSize: size, displayScale: 1)
        for frame in [0, 10, 29] {
            let layer = try #require(builder.descriptor(for: timeline, at: frameTime(frame)).blurs.first)
            #expect(layer.rect == mask.rect(at: frameTime(frame)))
        }
    }

    /// Followed, exported, and read back — and drawn for the preview from the editor's own
    /// frame source: both show the cover on the patch at the same frames, because both
    /// draw the path through `SceneBuilder`.
    @Test func theExportAndThePreviewCoverThePatchAlike() async throws {
        let footage = FollowingFootage.moving(frames: 60) { CGPoint(x: 100 + 7 * $0, y: 200 + 4 * $0) }
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("footage.mov")
        try await footage.write(to: source)

        var timeline = Timeline(sourceDuration: frameTime(60))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = false
        var mask = BlurRegion(start: .zero, duration: frameTime(60), rect: normalised(footage.truth(30)),
                              style: .cover, color: ColorValue(r: 0, g: 1, b: 0))
        timeline.blurs = [mask]
        let result = try await MaskFollower.follow(mask, in: timeline, from: frameTime(30), videoURL: source, frameRate: rate)
        mask.rect = result.rect
        mask.path = result.path
        timeline.blurs = [mask]

        let builder = SceneBuilder(videoSize: size, displayScale: 1)
        let exported = folder.appendingPathComponent("out.mov")
        let exporter = VideoExporter(timeline: timeline, builder: builder, cursor: nil, videoURL: source,
                                     packageURL: nil,
                                     settings: ExportSettings(format: .mov, frameRate: 30, includesAudio: false))
        try await exporter.export(to: exported)

        let reader = try await ExportFrameReader(url: exported)
        _ = await reader.naturalSize()
        let preview = try await FrameSource(url: source)
        let context = CIContext()
        for frame in [2, 17, 30, 44, 58] {
            let real = footage.truth(frame)
            let file = try #require(try reader.frame(at: frameTime(frame)))
            let written = try #require(context.createCGImage(file, from: file.extent))
            let still = try #require(await preview.frame(at: frameTime(frame)))
            let scene = builder.descriptor(for: timeline, at: frameTime(frame))
            let drawn = try #require(SceneRenderer().cgImage(for: scene, source: still))
            for image in [written, drawn] {
                for (fx, fy) in [(0.5, 0.5), (0.08, 0.15), (0.92, 0.85)] {
                    let pixel = try #require(Self.pixel(image, x: real.minX + real.width * fx,
                                                        y: real.minY + real.height * fy))
                    #expect(pixel.g > 200 && pixel.r < 60 && pixel.b < 60, "covered at frame \(frame)")
                }
            }
        }
    }

    // MARK: - Refusals

    @Test func aFlatPatchHasNothingToFollow() async throws {
        let footage = FollowingFootage(frames: 10) { _ in
            ({ context in
                context.setFillColor(CGColor(gray: 0.5, alpha: 1))
                context.fill(CGRect(origin: .zero, size: FollowingFootage.size))
            }, CGRect(x: 100, y: 100, width: 200, height: 50))
        }
        await #expect(throws: MaskFollower.Failure.nothingToFollow) {
            _ = try await follow(footage, from: 0)
        }
    }

    @Test func followingCanBeCancelled() async throws {
        let footage = FollowingFootage.moving(frames: 90) { CGPoint(x: 100 + 5 * $0, y: 300) }
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("footage.mov")
        try await footage.write(to: url)
        let mask = BlurRegion(start: .zero, duration: frameTime(90), rect: normalised(footage.truth(0)))
        var timeline = Timeline(sourceDuration: frameTime(90))
        timeline.blurs = [mask]
        let rate = rate
        let task = Task {
            try await MaskFollower.follow(mask, in: timeline, from: .zero, videoURL: url, frameRate: rate)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    // MARK: - Reading pixels

    /// A pixel by its place in the picture, top-left origin.
    static func pixel(_ image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int)? {
        let x = Int(x.rounded(.down)), y = Int(y.rounded(.down))
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
}
