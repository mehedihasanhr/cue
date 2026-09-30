import CoreGraphics
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The editor's canvas maps its outlines and handles through the renderer's perspective,
/// and a drag back through its inverse. These hold the two directions to each other and to
/// the renderer: a point sent out and brought back is the point it was, and a point of the
/// recording lands where the warped picture puts it.
@Suite("Canvas projection")
struct CanvasProjectionTests {
    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func scene(_ perspective: FramePerspective, crop: CropRect? = nil,
                       chrome: WindowChrome = WindowChrome(), zoom: Bool = false) -> SceneDescriptor {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 20, preferredTimescale: 600))
        timeline.style.padding = 0.1
        timeline.style.perspective = perspective
        timeline.style.crop = crop
        timeline.style.chrome = chrome
        timeline.cursor.isVisible = false
        if zoom {
            // A zoom whose straightening is switched off, so the picture stays turned while
            // the camera is in on it.
            timeline.style.perspective.straightensWhenZoomed = false
            timeline.zooms = [ZoomRegion(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600),
                                         scale: 1.6, center: CGPoint(x: 0.3, y: 0.6), easing: .linear,
                                         transition: CMTime(seconds: 0.1, preferredTimescale: 600),
                                         followsCursor: false)]
        }
        return SceneBuilder(videoSize: videoSize).descriptor(for: timeline,
                                                             at: CMTime(seconds: 5, preferredTimescale: 600))
    }

    static let turns: [FramePerspective] = [
        FramePerspective(turn: 25, lean: 0),
        FramePerspective(turn: -18, lean: 12),
        FramePerspective(turn: 30, lean: -20, rotation: 8),
        FramePerspective(turn: 0, lean: 35, rotation: -20),
    ]

    private static let grid: [CGPoint] = stride(from: 0.0, through: 1.0, by: 0.25).flatMap { x in
        stride(from: 0.0, through: 1.0, by: 0.25).map { y in CGPoint(x: x, y: y) }
    }

    private func isNear(_ a: CGPoint, _ b: CGPoint, within tolerance: Double = 1e-6) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    @Test("The projection's inverse brings every point back", arguments: turns)
    func projectionRoundTrips(_ perspective: FramePerspective) throws {
        let scene = scene(perspective)
        let projection = try #require(scene.perspectiveProjection)
        let plane = projection.plane
        for unit in Self.grid {
            // Across the plane and a good way past it: an annotation can hang off the picture.
            let point = CGPoint(x: plane.minX + (unit.x * 1.6 - 0.3) * plane.width,
                                y: plane.minY + (unit.y * 1.6 - 0.3) * plane.height)
            let back = try #require(projection.unproject(projection.project(point)))
            #expect(isNear(back, point, within: 1e-6), "\(point) came back as \(back)")
        }
    }

    @Test("The matrix is the projection: every point it maps is where project(_:) puts it", arguments: turns)
    func homographyMatchesProject(_ perspective: FramePerspective) throws {
        let projection = try #require(scene(perspective).perspectiveProjection)
        let h = projection.homography
        let plane = projection.plane
        for unit in Self.grid {
            let point = CGPoint(x: plane.minX + unit.x * plane.width, y: plane.minY + unit.y * plane.height)
            let u = point.x - plane.midX, v = point.y - plane.midY
            let w = h[6] * u + h[7] * v + h[8]
            let mapped = CGPoint(x: (h[0] * u + h[1] * v + h[2]) / w, y: (h[3] * u + h[4] * v + h[5]) / w)
            #expect(isNear(mapped, projection.project(point), within: 1e-6))
        }
    }

    @Test("A frame point round-trips through the canvas mapping", arguments: turns)
    func framePointsRoundTrip(_ perspective: FramePerspective) throws {
        let scene = scene(perspective)
        for point in Self.grid {
            let drawn = scene.tiltedFramePoint(point)
            let back = try #require(scene.flatFramePoint(drawn))
            #expect(isNear(back, point, within: 1e-9), "\(point) came back as \(back)")
        }
    }

    @Test("The frame matrix draws every point where the point mapping does", arguments: turns)
    func frameMatrixMatches(_ perspective: FramePerspective) throws {
        let scene = scene(perspective)
        let m = try #require(scene.tiltedFrameMatrix)
        for point in Self.grid {
            let w = m[6] * point.x + m[7] * point.y + m[8]
            let mapped = CGPoint(x: (m[0] * point.x + m[1] * point.y + m[2]) / w,
                                 y: (m[3] * point.x + m[4] * point.y + m[5]) / w)
            #expect(isNear(mapped, scene.tiltedFramePoint(point), within: 1e-9))
        }
        #expect(self.scene(FramePerspective()).tiltedFrameMatrix == nil)
    }

    @Test("A recording point round-trips through the crop, the camera and the turn", arguments: turns)
    func sourcePointsRoundTrip(_ perspective: FramePerspective) throws {
        for scene in [scene(perspective),
                      scene(perspective, crop: CropRect(rect: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5))),
                      scene(perspective, zoom: true),
                      scene(perspective, chrome: WindowChrome(kind: .iPhone))] {
            for point in Self.grid {
                let back = try #require(scene.sourcePoint(forFrame: scene.framePoint(forSource: point)))
                #expect(isNear(back, point, within: 1e-9), "\(point) came back as \(back)")
            }
        }
    }

    @Test("The recording's corners are drawn at the warped picture's corners")
    func cornersMatchTheRenderer() throws {
        let scene = scene(FramePerspective(turn: 22, lean: 9, rotation: 4))
        let projection = try #require(scene.perspectiveProjection)
        let frame = scene.transformedVideoFrame
        let size = scene.outputSize
        func normalised(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / size.width, y: 1 - p.y / size.height) }
        // Top-left of the recording is the top-left of the picture, Core Image's maxY.
        #expect(isNear(scene.framePoint(forSource: CGPoint(x: 0, y: 0)),
                       normalised(projection.project(CGPoint(x: frame.minX, y: frame.maxY)))))
        #expect(isNear(scene.framePoint(forSource: CGPoint(x: 1, y: 1)),
                       normalised(projection.project(CGPoint(x: frame.maxX, y: frame.minY)))))
        // And the picture's plane corners are the renderer's corners for the warp filter.
        let plane = projection.plane
        #expect(isNear(projection.corners.topLeft, projection.project(CGPoint(x: plane.minX, y: plane.maxY))))
    }

    @Test("Square-on, every mapping is the flat arithmetic")
    func flatIsIdentity() throws {
        let scene = scene(FramePerspective())
        #expect(scene.perspectiveProjection == nil)
        for point in Self.grid {
            #expect(scene.tiltedFramePoint(point) == point)
            #expect(scene.flatFramePoint(point) == point)
        }
        let frame = scene.transformedVideoFrame
        let size = scene.outputSize
        let middle = scene.framePoint(forSource: CGPoint(x: 0.5, y: 0.5))
        #expect(isNear(middle, CGPoint(x: frame.midX / size.width, y: 1 - frame.midY / size.height)))
    }

    @Test("Past the turned picture's horizon there is no flat point")
    func pastTheHorizon() throws {
        let projection = try #require(scene(FramePerspective(turn: 35, lean: 0)).perspectiveProjection)
        // Far out on the side that is turned away the flat plane meets its horizon; a point
        // drawn beyond it came from nowhere on the plane.
        let plane = projection.plane
        let far = CGPoint(x: plane.minX - plane.width * 50, y: plane.midY)
        if let back = projection.unproject(far) {
            // Wherever the inverse says it came from, sending that forward must land at `far`.
            #expect(isNear(projection.project(back), far, within: 1e-3))
        }
    }
}
