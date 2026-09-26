import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// Drawing the pointer the recording actually had.
///
/// The drawn pointer is an approximation of a *stock* Apple pointer, and plenty of people
/// do not use one. These cover the two things that have to be right for the real one:
/// which picture is chosen, and where its point lands.
struct RecordedCursorTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 1_600, height: 1_000)

    /// A pointer sitting still in the middle. 1600×1000 pixels at 2× is 800×500 points.
    private func track(shape: CursorShape = .arrow) -> CursorTrack {
        CursorTrack(samples: (0...20).map {
            CursorSample(t: Double($0) / 10, x: 400, y: 250, shape: shape)
        })
    }

    private func timeline() -> Timeline {
        var timeline = Timeline(sourceDuration: time(10))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = true
        timeline.cursor.smoothing = 0
        return timeline
    }

    /// A one-colour square on disk, standing in for a cursor picture.
    private func picture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-\(UUID().uuidString).png")
        let context = try #require(CGContext(data: nil, width: 32, height: 32,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func index(_ url: URL, shape: CursorShape = .arrow,
                       hotspot: CGPoint = .zero) -> CursorArtworkIndex {
        CursorArtworkIndex(artwork: [shape: .init(url: url, hotspot: hotspot, aspect: 1)])
    }

    private func builder(_ artwork: CursorArtworkIndex) -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 2, cursorArtwork: artwork)
    }

    // MARK: - Which picture

    @Test func aRecordingWithArtworkDrawsIt() throws {
        let url = try picture()
        defer { try? FileManager.default.removeItem(at: url) }

        let scene = builder(index(url)).descriptor(for: timeline(), at: .zero, cursor: track())
        #expect(scene.cursor?.artwork?.url == url)
    }

    @Test func aRecordingWithoutArtworkDrawsTheDrawnOne() {
        let scene = builder(CursorArtworkIndex()).descriptor(for: timeline(), at: .zero, cursor: track())
        #expect(scene.cursor != nil)
        #expect(scene.cursor?.artwork == nil)
    }

    @Test func turningItOffFallsBackToTheDrawnOne() throws {
        let url = try picture()
        defer { try? FileManager.default.removeItem(at: url) }

        var edit = timeline()
        edit.cursor.usesRecordedArtwork = false
        let scene = builder(index(url)).descriptor(for: edit, at: .zero, cursor: track())
        #expect(scene.cursor?.artwork == nil)
    }

    /// A shape the tracker could only call `other` still looks like this Mac's pointer,
    /// because its own arrow is a better answer than a drawing of somebody else's.
    @Test func anUnknownShapeFallsBackToTheRecordedArrow() throws {
        let url = try picture()
        defer { try? FileManager.default.removeItem(at: url) }

        let scene = builder(index(url)).descriptor(for: timeline(), at: .zero,
                                                   cursor: track(shape: .other))
        #expect(scene.cursor?.artwork?.url == url)
    }

    @Test func anIndexWithNothingInItIsEmpty() {
        #expect(CursorArtworkIndex().isEmpty)
        #expect(CursorArtworkIndex().artwork(for: .arrow) == nil)
    }

    // MARK: - Where the point lands

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func black() -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(origin: .zero, size: videoSize))
    }

    /// The hotspot is the whole point of storing one. A top-left hotspot puts the picture
    /// below and right of the position; a centred one puts it around the position.
    @Test func theHotspotDecidesWhereThePictureSits() throws {
        let url = try picture()
        defer { try? FileManager.default.removeItem(at: url) }
        RecordedCursorArtwork.clearCache()

        var edit = timeline()
        edit.cursor.scale = 3
        let renderer = SceneRenderer()

        func green(atX x: Int, y: Int, hotspot: CGPoint) throws -> Bool {
            let scene = builder(index(url, hotspot: hotspot))
                .descriptor(for: edit, at: .zero, cursor: track())
            let image = try #require(renderer.cgImage(for: scene, source: black()))
            let sample = try #require(pixel(image, x: x, y: y))
            return sample.g > 100
        }

        let middleX = Int(videoSize.width / 2)
        let middleY = Int(videoSize.height / 2)
        // A little below and right of the pointer's position.
        let insetX = middleX + 20
        let insetY = middleY + 20

        #expect(try green(atX: insetX, y: insetY, hotspot: .zero),
                "with the point at its top-left, the picture hangs down and right")
        #expect(try !green(atX: middleX - 20, y: middleY - 20, hotspot: .zero),
                "and nothing is drawn above and left of it")
        #expect(try green(atX: middleX - 20, y: middleY - 20, hotspot: CGPoint(x: 0.5, y: 0.5)),
                "centred, the picture surrounds the position instead")
    }
}
