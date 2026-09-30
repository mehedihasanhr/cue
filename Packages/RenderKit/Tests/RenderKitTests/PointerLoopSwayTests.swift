import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// A looping pointer and a leaning arrow, reaching the frame.
struct PointerLoopSwayTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    /// 800 × 500 points, two pixels to a point.
    private let builder = SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000), displayScale: 2)

    private func timeline(length: Double = 10, _ change: (inout Timeline) -> Void = { _ in }) -> Timeline {
        var timeline = Timeline(sourceDuration: time(length))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.smoothing = 0
        timeline.cursor.clickEffect = false
        timeline.camera.motionBlur = false
        change(&timeline)
        return timeline
    }

    /// From the left of the picture to the right over ten seconds, at a walk.
    private var walk: CursorTrack {
        CursorTrack(samples: (0...1_000).map { step in
            let t = Double(step) / 100
            return CursorSample(t: t, x: 100 + t * 60, y: 250, shape: .arrow)
        })
    }

    private func pointer(_ timeline: Timeline, at seconds: Double, track: CursorTrack? = nil) -> CursorLayer? {
        builder.descriptor(for: timeline, at: time(seconds), cursor: track ?? walk).cursor
    }

    // MARK: - Loop

    @Test func theLastFrameHasThePointerWhereTheFirstHadIt() throws {
        let looping = timeline { $0.cursor.loop = PointerLoop(isEnabled: true, duration: 1) }
        let first = try #require(pointer(looping, at: 0))
        let last = try #require(pointer(looping, at: 10 - 1.0 / 600))
        #expect(abs(first.position.x - last.position.x) < 0.001)
        #expect(abs(first.position.y - last.position.y) < 0.001)
        // Without the loop the last frame is most of the picture away.
        let plain = try #require(pointer(timeline(), at: 10 - 1.0 / 600))
        #expect(plain.position.x - first.position.x > 0.6)
    }

    @Test func beforeTheJourneyThePointerIsTheRecordedOne() {
        let looping = timeline { $0.cursor.loop = PointerLoop(isEnabled: true, duration: 1.5) }
        for seconds in [0.0, 3, 8, 8.49] {
            #expect(pointer(looping, at: seconds) == pointer(timeline(), at: seconds), "at \(seconds)")
        }
    }

    @Test func theJourneyHomeHasNoJumpInIt() throws {
        let looping = timeline { $0.cursor.loop = PointerLoop(isEnabled: true, duration: 0.5) }
        var previous = try #require(pointer(looping, at: 9)).position.x
        var largest = 0.0
        for frame in (9 * 60 + 1)..<(10 * 60) {
            let x = try #require(pointer(looping, at: Double(frame) / 60)).position.x
            largest = max(largest, abs(x - previous))
            previous = x
        }
        // Three-quarters of the frame in half a second, eased: the fastest step is a few
        // per cent of the frame, never the whole distance at once.
        #expect(largest < 0.06, "\(largest)")
    }

    @Test func aPointerHiddenAtTheStartFadesOutOnTheWayHome() throws {
        var looping = timeline { $0.cursor.loop = PointerLoop(isEnabled: true, duration: 1) }
        looping.cursorRegions = [CursorRegion(start: .zero, duration: time(2), transition: .zero)]
        #expect(pointer(looping, at: 0) == nil)
        #expect(pointer(looping, at: 5)?.opacity == 1)
        #expect(pointer(looping, at: 10 - 1.0 / 600) == nil, "gone, as it is on the first frame")
    }

    @Test func theCameraComesHomeWithThePointer() throws {
        func shot(_ bringsCameraBack: Bool, at seconds: Double) -> (Double, CGPoint) {
            let held = timeline {
                $0.camera.wholeVideoZoom = 2
                $0.cursor.loop = PointerLoop(isEnabled: true, duration: 1, bringsCameraBack: bringsCameraBack)
            }
            let scene = builder.descriptor(for: held, at: time(seconds), cursor: walk)
            return (scene.zoom, scene.zoomCenter)
        }
        let first = shot(true, at: 0)
        let last = shot(true, at: 10 - 1.0 / 600)
        #expect(abs(first.0 - last.0) < 0.001)
        #expect(abs(first.1.x - last.1.x) < 0.001)
        let stayed = shot(false, at: 10 - 1.0 / 600)
        // Left, off, to its own devices: it still keeps the homecoming pointer in shot, so it
        // is dragged some of the way back, but not onto the first frame's shot.
        #expect(stayed.1.x - first.1.x > 0.05, "left nearer where the pointer took it")
    }

    // MARK: - Sway

    private func swaying(_ change: (inout Timeline) -> Void = { _ in }) -> Timeline {
        timeline {
            $0.cursor.sway = PointerSway(isEnabled: true, strength: 1)
            change(&$0)
        }
    }

    /// Still for two seconds, across to the right in one, still, back to the left in one.
    private var dash: CursorTrack {
        CursorTrack(samples: (0...1_000).map { step in
            let t = Double(step) / 100
            let x: Double = switch t {
            case ..<2: 100
            case ..<3: 100 + (t - 2) * 500
            case ..<5: 600
            case ..<6: 600 - (t - 5) * 500
            default: 100
            }
            return CursorSample(t: t, x: x, y: 250, shape: .arrow)
        })
    }

    @Test func theArrowLeansIntoItsTravelAndStandsUpWhenItStops() throws {
        let timeline = swaying()
        #expect(try #require(pointer(timeline, at: 1, track: dash)).tilt == 0, "still")
        #expect(try #require(pointer(timeline, at: 2.6, track: dash)).tilt > 0.1, "going right")
        #expect(abs(try #require(pointer(timeline, at: 4, track: dash)).tilt) < 1e-9, "stopped long enough")
        #expect(try #require(pointer(timeline, at: 5.6, track: dash)).tilt < -0.1, "going left")
    }

    @Test func theLeanIsTheSameHoweverTheMomentIsReached() throws {
        let timeline = swaying()
        let forwards = try (0..<120).map { try #require(pointer(timeline, at: 2 + Double($0) / 60, track: dash)).tilt }
        let backwards = try (0..<120).reversed().map { try #require(pointer(timeline, at: 2 + Double($0) / 60, track: dash)).tilt }
        #expect(forwards == Array(backwards.reversed()))
    }

    @Test func onlyAPointerWithABodyLeans() throws {
        let beam = CursorTrack(samples: dash.samples.map {
            CursorSample(t: $0.t, x: $0.x, y: $0.y, shape: .iBeam)
        })
        #expect(try #require(pointer(swaying(), at: 2.6, track: beam)).tilt == 0, "an I-beam")
        let dot = swaying { $0.cursor.appearance = .dot }
        #expect(try #require(pointer(dot, at: 2.6, track: dash)).tilt == 0, "a dot")
        let large = swaying { $0.cursor.appearance = .largeArrow }
        #expect(try #require(pointer(large, at: 2.6, track: beam)).tilt > 0.1, "Klik's own arrow, whatever the shape")
        #expect(try #require(pointer(timeline(), at: 2.6, track: dash)).tilt == 0, "and not unless asked")
    }

    @Test func aHeldPointerStandsUp() throws {
        var held = swaying()
        held.cursorRegions = [CursorRegion(start: time(1.5), duration: time(3), isHidden: false, isHeld: true)]
        #expect(abs(try #require(pointer(held, at: 2.7, track: dash)).tilt) < 0.02)
    }

    @Test func aLeaningArrowIsDrawnLeaning() throws {
        let timeline = swaying()
        var scene = builder.descriptor(for: timeline, at: time(2.6), cursor: dash)
        let leaning = try picture(scene)
        scene.cursor?.tilt = 0
        let upright = try picture(scene)
        #expect(leaning != upright)
    }

    private func picture(_ scene: SceneDescriptor) throws -> [UInt8] {
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: scene.outputSize))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: black))
        var bytes = [UInt8](repeating: 0, count: 160 * 100 * 4)
        let context = try #require(CGContext(data: &bytes, width: 160, height: 100, bitsPerComponent: 8,
                                             bytesPerRow: 160 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 100))
        return bytes
    }
}
