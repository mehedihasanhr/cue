import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// Where the picture and the camera go in each camera layout, and what a frame looks like
/// on the way from one to another.
@Suite("Camera layouts, placed and drawn")
struct CameraLayoutRenderTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// 1600 × 1000, so the shorter side is a round 1000.
    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 1)
    }

    /// The bubble on, nothing else in the way, and one layout from 2 s to 8 s.
    private func timeline(_ layout: CameraLayout? = nil,
                          _ configure: (inout Timeline) -> Void = { _ in }) -> Timeline {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.style.background = .color(ColorValue(r: 0, g: 0, b: 1))
        timeline.webcam.isEnabled = true
        timeline.webcam.size = 0.2
        timeline.webcam.roundness = 0
        timeline.webcam.shadowOpacity = 0
        timeline.webcam.isMirrored = false
        timeline.webcam.reactsToZoom = false
        if let layout {
            timeline.cameraLayouts = [CameraLayoutRegion(start: time(2), duration: time(6), layout: layout)]
        }
        configure(&timeline)
        return timeline
    }

    private let middle = 5.0
    private var halfWayIn: Double { 2 + Timeline.cameraLayoutTransition / 2 }

    // MARK: - Nothing changes without a lane

    @Test("A stretch marked Bubble describes exactly the frame no lane does")
    func bubbleIsTheOldFrame() {
        let plain = builder().descriptor(for: timeline(), at: time(middle))
        let marked = builder().descriptor(for: timeline(.bubble), at: time(middle))
        #expect(plain == marked)
        #expect(plain.videoOpacity == 1)
    }

    @Test("With the camera off a layout changes nothing at all")
    func cameraOffIgnoresTheLane() {
        var off = timeline(.sideBySide)
        off.webcam.isEnabled = false
        var bare = timeline()
        bare.webcam.isEnabled = false
        #expect(builder().descriptor(for: off, at: time(middle)) == builder().descriptor(for: bare, at: time(middle)))
    }

    // MARK: - Hidden

    @Test("Hidden describes no camera, and the picture where it always was")
    func hidden() {
        let scene = builder().descriptor(for: timeline(.hidden), at: time(middle))
        #expect(scene.webcam == nil)
        #expect(scene.videoFrame == builder().descriptor(for: timeline(), at: time(middle)).videoFrame)
    }

    @Test("Going, the bubble fades and shrinks about its own middle")
    func hiding() throws {
        let bubble = try #require(builder().descriptor(for: timeline(), at: time(middle)).webcam)
        let going = try #require(builder().descriptor(for: timeline(.hidden), at: time(halfWayIn)).webcam)
        #expect(abs(going.opacity - 0.5) < 0.01)
        #expect(going.rect.width < bubble.rect.width)
        #expect(abs(going.rect.midX - bubble.rect.midX) < 1e-9)
        #expect(abs(going.rect.midY - bubble.rect.midY) < 1e-9)
        #expect(going.isBubble, "still the bubble: the keys may go on keeping clear of it")
    }

    // MARK: - Camera only

    @Test("Camera Only fills the frame inside the padding, and the screen goes")
    func cameraOnly() throws {
        let edit = timeline(.cameraOnly) {
            $0.style.padding = 0.05
            $0.style.cornerRadius = 0.04
        }
        let scene = builder().descriptor(for: edit, at: time(middle))
        let camera = try #require(scene.webcam)
        // Padding is 5% of the shorter side, 50 px, on every edge.
        #expect(abs(camera.rect.minX * 1_600 - 50) < 0.001)
        #expect(abs(camera.rect.minY * 1_000 - 50) < 0.001)
        #expect(abs(camera.rect.width * 1_600 - 1_500) < 0.001)
        #expect(abs(camera.rect.height * 1_000 - 900) < 0.001)
        #expect(abs(camera.cornerRadius - 900 * 0.04) < 0.001, "the frame's own corners")
        #expect(scene.videoOpacity == 0)
        #expect(scene.shadowOpacity == 0, "no shadow cast by a picture that is not there")
        #expect(!camera.isBubble)
    }

    @Test("The pointer and its clicks belong to the screen, and go with it")
    func pointerGoesWithTheScreen() {
        var edit = timeline(.cameraOnly)
        edit.cursor.isVisible = true
        let samples = (0...200).map { CursorSample(t: Double($0) * 0.1, x: 400, y: 300, shape: .arrow) }
        let track = CursorTrack(samples: samples)
        let shown = builder().descriptor(for: timeline(), at: time(middle), cursor: track)
        let gone = builder().descriptor(for: edit, at: time(middle), cursor: track)
        let going = builder().descriptor(for: edit, at: time(halfWayIn), cursor: track)
        #expect(shown.cursor != nil)
        #expect(gone.cursor == nil)
        #expect(abs((going.cursor?.opacity ?? 0) - 0.5) < 0.01)
    }

    // MARK: - Side by side

    @Test("Side by side splits a wide frame: the screen on one side, the camera on the other")
    func sideBySideWide() throws {
        let scene = builder().descriptor(for: timeline(.sideBySide), at: time(middle))
        let camera = try #require(scene.webcam)
        let screen = scene.videoFrame
        let pane = camera.pixelRect(in: scene.outputSize)
        // The gap is 2.5% of 1000; the screen gets 68% of what is left, fitted.
        #expect(abs(screen.width - 1_575 * 0.68) < 0.01)
        #expect(abs(screen.height - 1_575 * 0.68 * 1_000 / 1_600) < 0.01)
        #expect(pane.minX >= screen.maxX + 25 - 0.01, "the camera to the right, a gap between")
        #expect(abs(pane.height - screen.height) < 0.01, "and as tall as the screen")
        #expect(abs(pane.midY - screen.midY) < 0.01, "level with it")
        #expect(pane.width <= pane.height + 0.01, "never wider than it is tall")
        #expect(scene.videoOpacity == 1)
        #expect(!camera.isBubble)
    }

    /// The handset is drawn round the picture wherever the layout puts it, so it is the
    /// handset that is fitted into the screen's half: it stays inside the space, clear of
    /// the gap, and the camera sits beside it rather than under its edge.
    @Test("A device frame round half a split stays in its half", arguments: [
        WindowChrome.Kind.iPhone, .iPad,
    ])
    func sideBySideFitsTheDevice(kind: WindowChrome.Kind) throws {
        let wide = timeline(.sideBySide) { $0.style.chrome = WindowChrome(kind: kind) }
        var tall = wide
        tall.style.aspect = .vertical9x16
        for timeline in [wide, tall] {
            let scene = builder().descriptor(for: timeline, at: time(middle))
            // Both in output pixels with Core Image's bottom-left origin.
            let camera = try #require(scene.webcam).pixelRect(in: scene.outputSize)
            let device = try #require(scene.deviceGeometry)
            let body = device.body
            let output = CGRect(origin: .zero, size: scene.outputSize)
            let size = scene.outputSize
            #expect(output.insetBy(dx: -0.01, dy: -0.01).contains(body), "\(kind) inside the frame at \(size)")
            #expect(!body.insetBy(dx: 1, dy: 1).intersects(camera), "\(kind) clear of the camera at \(size)")
            // The picture is still in the middle of its screen.
            #expect(abs(device.screen.midX - scene.videoFrame.midX) < 0.5)
            #expect(abs(device.screen.midY - scene.videoFrame.midY) < 0.5)
        }
    }

    @Test("A bubble parked on the left goes side by side on the left")
    func sideBySideFollowsTheBubble() throws {
        let scene = builder().descriptor(for: timeline(.sideBySide) { $0.webcam.corner = .topLeft },
                                         at: time(middle))
        let pane = try #require(scene.webcam).pixelRect(in: scene.outputSize)
        #expect(pane.maxX <= scene.videoFrame.minX + 0.01)
    }

    @Test("A tall frame stacks them instead")
    func sideBySideTall() throws {
        let edit = timeline(.sideBySide) { $0.style.aspect = .vertical9x16 }
        let scene = builder().descriptor(for: edit, at: time(middle))
        let pane = try #require(scene.webcam).pixelRect(in: scene.outputSize)
        let screen = scene.videoFrame
        // Core Image's y runs up: the default bottom-right bubble puts the camera below.
        #expect(pane.maxY <= screen.minY + 0.01)
        #expect(abs(pane.width - screen.width) < 0.01)
    }

    @Test("Everything measured off the picture follows it into its half")
    func pictureStyleFollows() {
        let edit = timeline(.sideBySide) {
            $0.style.cornerRadius = 0.05
            $0.style.borderWidth = 0.01
            $0.style.borderColor = .white
        }
        let scene = builder().descriptor(for: edit, at: time(middle))
        let shorter = min(scene.videoFrame.width, scene.videoFrame.height)
        #expect(abs(scene.cornerRadius - shorter * 0.05) < 0.001)
        #expect(abs((scene.border?.width ?? 0) - shorter * 0.01) < 0.001)
    }

    // MARK: - On the way

    @Test("Half-way into a split, the picture is half-way to its half")
    func transition() {
        let before = builder().descriptor(for: timeline(), at: time(1)).videoFrame
        let after = builder().descriptor(for: timeline(.sideBySide), at: time(middle)).videoFrame
        let during = builder().descriptor(for: timeline(.sideBySide), at: time(halfWayIn)).videoFrame
        #expect(abs(during.width - (before.width + after.width) / 2) < 0.5)
        #expect(abs(during.minX - (before.minX + after.minX) / 2) < 0.5)
    }

    /// The bubble grows by seven-eighths of the frame's width over 21 frames at 60 fps; the
    /// ease is at its steepest twice the average, so no frame may move more than a tenth.
    @Test("A change is continuous: no frame jumps")
    func continuous() throws {
        let edit = timeline(.cameraOnly)
        var last: CGRect?
        for step in 0..<180 {
            let moment = 1.5 + Double(step) / 60
            let rect = try #require(builder().descriptor(for: edit, at: time(moment)).webcam).rect
            if let last {
                #expect(abs(rect.width - last.width) < 0.1, "jumped at \(moment)")
                #expect(abs(rect.minX - last.minX) < 0.1, "jumped at \(moment)")
            }
            last = rect
        }
    }

    // MARK: - The keys keep clear of a bubble, not of a pane

    @Test("The keys step out of a bubble's way but not a pane's")
    func keysClearOnlyABubble() {
        let renderer = SceneRenderer()
        let bubble = builder().descriptor(for: timeline(), at: time(middle))
        let pane = builder().descriptor(for: timeline(.cameraOnly), at: time(middle))
        let fading = builder().descriptor(for: timeline(.hidden), at: time(2 + Timeline.cameraLayoutTransition * 0.8))
        #expect(renderer.keysAvoid(bubble).count == 1)
        #expect(renderer.keysAvoid(pane).isEmpty)
        #expect(renderer.keysAvoid(fading).isEmpty, "a bubble mostly gone is nothing to step round")
    }

    /// The final rect is what is avoided: a bubble moved by a layout on its way somewhere
    /// is avoided where it is drawn now, not where its settings park it.
    @Test("The keys clear the bubble where it is drawn")
    func keysClearTheDrawnRect() throws {
        let scene = builder().descriptor(for: timeline(.hidden), at: time(2.05))
        let drawn = try #require(scene.webcam)
        #expect(SceneRenderer().keysAvoid(scene) == [SceneRenderer.outputRect(of: drawn.rect, in: scene.outputSize)])
    }

    // MARK: - Pixels

    @Test("Camera Only draws the camera over the whole frame and none of the screen")
    func cameraOnlyPixels() throws {
        let scene = builder().descriptor(for: timeline(.cameraOnly), at: time(middle))
        let image = try #require(SceneRenderer().cgImage(for: scene,
                                                         source: solid(CIColor(red: 1, green: 0, blue: 0), size: videoSize),
                                                         webcam: solid(CIColor(red: 0, green: 1, blue: 0),
                                                                       size: CGSize(width: 640, height: 480))))
        for (x, y) in [(0.1, 0.1), (0.5, 0.5), (0.9, 0.9)] {
            let sample = try #require(pixel(image, x: Int(x * Double(image.width)), y: Int(y * Double(image.height))))
            #expect(sample.g > 200 && sample.r < 40, "at \(x), \(y): \(sample)")
        }
    }

    @Test("Side by side draws both, each in its own half")
    func sideBySidePixels() throws {
        let scene = builder().descriptor(for: timeline(.sideBySide), at: time(middle))
        let image = try #require(SceneRenderer().cgImage(for: scene,
                                                         source: solid(CIColor(red: 1, green: 0, blue: 0), size: videoSize),
                                                         webcam: solid(CIColor(red: 0, green: 1, blue: 0),
                                                                       size: CGSize(width: 640, height: 480))))
        let row = image.height / 2
        let pane = try #require(scene.webcam).rect
        let screen = try #require(pixel(image, x: Int(scene.videoFrame.midX), y: row))
        let camera = try #require(pixel(image, x: Int(pane.midX * Double(image.width)), y: row))
        #expect(screen.r > 200 && screen.g < 40, "the screen on the left: \(screen)")
        #expect(camera.g > 200 && camera.r < 40, "the camera on the right: \(camera)")
    }

    @Test("A hidden stretch draws exactly the frame a camera switched off does")
    func hiddenPixels() throws {
        var off = timeline()
        off.webcam.isEnabled = false
        let renderer = SceneRenderer()
        let screen = solid(CIColor(red: 1, green: 0, blue: 0), size: videoSize)
        let camera = solid(CIColor(red: 0, green: 1, blue: 0), size: CGSize(width: 640, height: 480))
        let hidden = try #require(renderer.cgImage(for: builder().descriptor(for: timeline(.hidden), at: time(middle)),
                                                   source: screen, webcam: camera))
        let bare = try #require(renderer.cgImage(for: builder().descriptor(for: off, at: time(middle)),
                                                 source: screen, webcam: camera))
        #expect(try bytes(hidden) == bytes(bare))
    }

    // MARK: - Sources and pixels

    private func solid(_ colour: CIColor, size: CGSize) -> CIImage {
        CIImage(color: colour).cropped(to: CGRect(origin: .zero, size: size))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func bytes(_ image: CGImage) throws -> Data {
        let data = try #require(image.dataProvider?.data)
        return Data(referencing: data as NSData)
    }
}
