import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// A window recording while its window was behind another: black, and no pointer.
struct WindowPresenceRenderTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private var builder: SceneBuilder {
        SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000), displayScale: 2,
                     picture: PictureTrack(presence: [PresenceSample(t: 0, front: true),
                                                      PresenceSample(t: 2, front: false),
                                                      PresenceSample(t: 5, front: true)]))
    }

    private var timeline: Timeline {
        var timeline = Timeline(sourceDuration: time(10))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        return timeline
    }

    private var track: CursorTrack {
        CursorTrack(samples: (0...1_000).map { CursorSample(t: Double($0) / 100, x: 400, y: 250, shape: .arrow) },
                    input: [])
    }

    @Test func behindIsBlackWithNoPointer() {
        let behind = builder.descriptor(for: timeline, at: time(3), cursor: track)
        #expect(behind.hidesPicture)
        #expect(behind.cursor == nil)
        for moment in [1.0, 6.0] {
            let inFront = builder.descriptor(for: timeline, at: time(moment), cursor: track)
            #expect(!inFront.hidesPicture, "at \(moment) s")
            #expect(inFront.cursor != nil, "at \(moment) s")
        }
    }

    @Test func aHiddenPictureIsDrawnBlack() throws {
        var scene = builder.descriptor(for: timeline, at: time(3), cursor: track)
        scene.background = .color(.init(r: 1, g: 1, b: 1, a: 1))
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1_600, height: 1_000))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: white))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // The middle of the picture, drawn into one pixel.
        let middle = CGPoint(x: scene.videoFrame.midX, y: scene.videoFrame.midY)
        context.draw(image, in: CGRect(x: -middle.x, y: -(CGFloat(image.height) - middle.y),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        #expect(pixel[0] < 10 && pixel[1] < 10 && pixel[2] < 10, "\(pixel)")
    }
}
