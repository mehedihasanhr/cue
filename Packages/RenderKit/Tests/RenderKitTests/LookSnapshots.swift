import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Testing
import TimelineKit
import UniformTypeIdentifiers
@testable import RenderKit

/// Pictures of the perspective presets, the moving backgrounds and the colour presets, for
/// looking at rather than asserting on.
///
/// Off by default; pointed at a folder it writes one PNG per case there —
///
///     CUE_LOOKS_DIR=/tmp/looks swift test --filter LookSnapshots
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CUE_LOOKS_DIR"] != nil,
                "set CUE_LOOKS_DIR to a folder to write the pictures"),
       .serialized)
struct LookSnapshots {
    private let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CUE_LOOKS_DIR"] ?? "/tmp")
    private let videoSize = CGSize(width: 1_920, height: 1_080)

    private func timeline() -> Timeline {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))
        timeline.style.padding = 0.1
        timeline.style.chrome = WindowChrome(kind: .window, appearance: .light)
        timeline.style.borderWidth = 0.004
        timeline.style.borderColor = ColorValue(r: 1, g: 1, b: 1, a: 0.6)
        timeline.cursor.isVisible = false
        return timeline
    }

    private func source() -> CIImage {
        CIImage(cgImage: FollowingFootage.page(height: Int(videoSize.height), seed: 7))
            .transformed(by: CGAffineTransform(scaleX: videoSize.width / FollowingFootage.size.width, y: 1))
    }

    private func write(_ timeline: Timeline, at seconds: Double = 1, name: String) throws {
        let builder = SceneBuilder(videoSize: videoSize)
        var scene = builder.descriptor(for: timeline, at: CMTime(seconds: seconds, preferredTimescale: 600))
        // A pointer and a note on the picture, so their turning can be seen.
        scene.cursor = CursorLayer(position: CGPoint(x: 0.3, y: 0.35), shape: .arrow, scale: 1.4)
        scene.annotations = [AnnotationLayer(kind: .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1, y: 1)),
                                             rect: CGRect(x: 0.4, y: 0.45, width: 0.15, height: 0.12),
                                             color: ColorValue(r: 1, g: 0.3, b: 0.2), fontSize: 0.04, opacity: 1)]
        let image = try #require(SceneRenderer().cgImage(for: scene, source: source()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func perspectivePresets() throws {
        for preset in FramePerspective.Preset.allCases {
            var timeline = timeline()
            timeline.style.perspective = FramePerspective().with(preset)
            try write(timeline, name: "perspective-\(preset.rawValue)")
        }
    }

    @Test func movingBackgrounds() throws {
        for kind in AnimatedBackground.Kind.allCases {
            for seconds in [0.0, 6.0] {
                var timeline = timeline()
                timeline.style.background = .animated(AnimatedBackground(kind: kind))
                try write(timeline, at: seconds, name: "background-\(kind.rawValue)-\(Int(seconds))s")
            }
        }
    }

    @Test func colourPresets() throws {
        for preset in ColorGrade.Preset.allCases {
            var timeline = timeline()
            timeline.style.grade = ColorGrade().with(preset)
            try write(timeline, name: "colour-\(preset.rawValue)")
        }
    }
}
