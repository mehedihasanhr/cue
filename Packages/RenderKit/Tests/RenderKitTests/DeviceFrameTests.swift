import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// A phone or a tablet round the picture: room made for it inside the padding, a rim and a
/// bezel drawn round a screen with rounded corners, the picture fitted into the screen with
/// black either side, and all of it carried by the camera, the shadow and the perspective.
@Suite("Device frames")
struct DeviceFrameRenderTests {
    private let wide = CGSize(width: 1_600, height: 1_000)
    private let red = ColorValue(r: 1, g: 0, b: 0)
    private let blue = ColorValue(r: 0, g: 0, b: 1)
    private let black = ColorValue(r: 0, g: 0, b: 0)
    private let glass = ColorValue(r: 0.03, g: 0.03, b: 0.035)
    private let silver = ColorValue(r: 0.84, g: 0.85, b: 0.86)

    private func timeline(_ kind: WindowChrome.Kind,
                          finish: WindowChrome.Finish = .black,
                          orientation: WindowChrome.Orientation = .automatic,
                          camera: Bool = true) -> Timeline {
        var timeline = Timeline(sourceDuration: DressingFixtures.time(20))
        timeline.style.padding = 0.1
        timeline.style.cornerRadius = 0.03
        timeline.style.shadowOpacity = 0
        timeline.style.background = .color(blue)
        timeline.style.chrome = WindowChrome(kind: kind, finish: finish, orientation: orientation, showsCamera: camera)
        timeline.cursor.isVisible = false
        return timeline
    }

    private func scene(_ timeline: Timeline, size: CGSize? = nil, at seconds: Double = 1) -> SceneDescriptor {
        SceneBuilder(videoSize: size ?? wide).descriptor(for: timeline, at: DressingFixtures.time(seconds))
    }

    private func render(_ timeline: Timeline, size: CGSize? = nil,
                        at seconds: Double = 1) throws -> (SceneDescriptor, DressingPixels) {
        let size = size ?? wide
        return try DressingFixtures.render(timeline, at: seconds, source: DressingFixtures.flat(red, size: size),
                                           videoSize: size)
    }

    /// A point in Core Image's bottom-left space, as whole pixels from the top-left.
    private func pixel(_ point: CGPoint, in scene: SceneDescriptor) -> (Int, Int) {
        (Int(point.x.rounded(.down)), Int((scene.outputSize.height - point.y).rounded(.down)))
    }

    private func colour(_ pixels: DressingPixels, _ point: CGPoint, in scene: SceneDescriptor) -> ColorValue {
        let (x, y) = pixel(point, in: scene)
        return pixels.colour(x, y)
    }

    private func isClose(_ pixels: DressingPixels, _ point: CGPoint, in scene: SceneDescriptor,
                         to colour: ColorValue, within tolerance: Double = 0.04) -> Bool {
        let (x, y) = pixel(point, in: scene)
        return pixels.isClose(x, y, to: colour, within: tolerance)
    }

    // MARK: - Room for it

    @Test("The whole handset fits the padding, centred, and the picture keeps its shape")
    func fitsThePadding() throws {
        for kind in [WindowChrome.Kind.iPhone, .iPad] {
            let scene = scene(timeline(kind))
            let device = try #require(scene.deviceGeometry)
            #expect(scene.chrome == nil, "a device is not a window bar")
            #expect(scene.chromeBarFrame == nil)
            // 10% padding of the shorter side, 100 pixels, on a 1600 × 1000 output.
            #expect(device.body.minX >= 99.5 && device.body.maxX <= 1_500.5)
            #expect(device.body.minY >= 99.5 && device.body.maxY <= 900.5)
            #expect(abs(device.body.width - 1_400) < 0.5 || abs(device.body.height - 800) < 0.5,
                    "it fills the padding one way or the other")
            #expect(abs(device.body.midX - 800) < 0.5 && abs(device.body.midY - 500) < 0.5)
            #expect(abs(scene.videoFrame.width / scene.videoFrame.height - 1.6) < 0.001)
            #expect(device.screen.contains(scene.videoFrame.insetBy(dx: 0.01, dy: 0.01)))
        }
    }

    @Test("Automatic turns a phone on its side for a wide recording and upright for a tall one")
    func automaticOrientation() throws {
        let lying = try #require(scene(timeline(.iPhone)).deviceGeometry)
        #expect(lying.screen.width > lying.screen.height)
        let tall = try #require(scene(timeline(.iPhone), size: CGSize(width: 1_000, height: 1_600)).deviceGeometry)
        #expect(tall.screen.height > tall.screen.width)
        let forced = try #require(scene(timeline(.iPhone, orientation: .portrait)).deviceGeometry)
        #expect(forced.screen.height > forced.screen.width, "portrait is portrait whatever the recording")
        let screenAspect = forced.screen.width / forced.screen.height
        #expect(abs(screenAspect - DeviceGeometry.screenAspect(.iPhone)) < 0.001)
    }

    @Test("The picture fits the screen: it fills one way and leaves black the other")
    func pictureFitsTheScreen() throws {
        // A 16:10 picture in a phone lying down, whose screen is wider still: the picture
        // fills the height and leaves black at the ends.
        let scene = scene(timeline(.iPhone))
        let device = try #require(scene.deviceGeometry)
        #expect(abs(scene.videoFrame.height - device.screen.height) < 0.01)
        #expect(scene.videoFrame.width < device.screen.width - 10)
    }

    // MARK: - Drawn

    @Test("A phone: a black bezel round the picture, black gaps in the screen, rounded corners outside")
    func phonePixels() throws {
        let (scene, pixels) = try render(timeline(.iPhone, camera: false))
        let device = try #require(scene.deviceGeometry)

        // The picture, in the middle of the screen.
        #expect(isClose(pixels, CGPoint(x: scene.videoFrame.midX, y: scene.videoFrame.midY), in: scene, to: red))
        // The bezel: black glass between the screen and the rim.
        let bezel = CGPoint(x: device.body.midX, y: (device.screen.maxY + device.body.maxY - device.rim) / 2)
        #expect(isClose(pixels, bezel, in: scene, to: glass, within: 0.03),
                "the bezel: \(colour(pixels, bezel, in: scene))")
        // The screen beside the picture, where the picture is too narrow to reach: black.
        let gap = CGPoint(x: (device.screen.maxX + scene.videoFrame.maxX) / 2, y: device.screen.midY)
        #expect(isClose(pixels, gap, in: scene, to: black, within: 0.02), "the gap: \(colour(pixels, gap, in: scene))")
        // The body's corner is round: the background shows in the very corner of its box.
        let corner = CGPoint(x: device.body.minX + 2, y: device.body.maxY - 2)
        #expect(isClose(pixels, corner, in: scene, to: blue), "the corner: \(colour(pixels, corner, in: scene))")
        // And the rim is there along its straight side.
        let rim = CGPoint(x: device.body.midX, y: device.body.maxY - device.rim * 0.3)
        #expect(isClose(pixels, rim, in: scene, to: ColorValue(r: 0.2, g: 0.2, b: 0.21), within: 0.05),
                "the rim: \(colour(pixels, rim, in: scene))")
    }

    @Test("The screen's corners are rounded: a picture that fills the screen loses its corners to the bezel")
    func screenCornersAreRounded() throws {
        // A recording exactly the shape of an upright phone's screen fills it corner to corner.
        let size = CGSize(width: 1_179, height: 2_556)
        let (scene, pixels) = try render(timeline(.iPhone, camera: false), size: size)
        let device = try #require(scene.deviceGeometry)
        #expect(abs(scene.videoFrame.width - device.screen.width) < 0.5)
        let inCorner = CGPoint(x: device.screen.minX + 2, y: device.screen.maxY - 2)
        #expect(!isClose(pixels, inCorner, in: scene, to: red, within: 0.3),
                "the screen's corner is cut round: \(colour(pixels, inCorner, in: scene))")
        let alongEdge = CGPoint(x: device.screen.minX + 2, y: device.screen.midY)
        #expect(isClose(pixels, alongEdge, in: scene, to: red), "but its straight side is picture")
    }

    @Test("The phone's camera pill sits over the top of the picture")
    func dynamicIsland() throws {
        let size = CGSize(width: 1_179, height: 2_556)
        let (scene, pixels) = try render(timeline(.iPhone), size: size)
        let device = try #require(scene.deviceGeometry)
        let pill = try #require(device.camera)
        #expect(device.screen.contains(pill))
        #expect(isClose(pixels, CGPoint(x: pill.midX, y: pill.midY), in: scene, to: black, within: 0.02))
        let beside = CGPoint(x: pill.maxX + pill.height, y: pill.midY)
        #expect(isClose(pixels, beside, in: scene, to: red), "the picture either side of it")

        let (hiddenScene, hidden) = try render(timeline(.iPhone, camera: false), size: size)
        #expect(hiddenScene.deviceGeometry?.camera == nil)
        #expect(isClose(hidden, CGPoint(x: pill.midX, y: pill.midY), in: hiddenScene, to: red),
                "hidden, the picture shows where it was")
    }

    @Test("Lying down, the pill moves to the left edge of the screen")
    func landscapeIsland() throws {
        let device = try #require(scene(timeline(.iPhone, orientation: .landscape)).deviceGeometry)
        let pill = try #require(device.camera)
        #expect(pill.height > pill.width)
        #expect(pill.midX < device.screen.minX + device.screen.width * 0.1)
    }

    @Test("A silver tablet: a silver rim, a black bezel, and a camera in the bezel")
    func silverTablet() throws {
        let (scene, pixels) = try render(timeline(.iPad, finish: .silver))
        let device = try #require(scene.deviceGeometry)
        let rim = CGPoint(x: device.body.minX + device.rim * 0.3, y: device.body.midY)
        #expect(isClose(pixels, rim, in: scene, to: silver, within: 0.05), "the rim: \(colour(pixels, rim, in: scene))")
        let lens = try #require(device.camera)
        #expect(!device.screen.intersects(lens), "the tablet's camera is in the bezel")
        #expect(device.body.contains(lens))
        let bezel = CGPoint(x: device.screen.minX - (device.screen.minX - device.body.minX) / 2 + device.rim / 2,
                            y: device.screen.midY)
        #expect(isClose(pixels, bezel, in: scene, to: glass, within: 0.03), "the bezel: \(colour(pixels, bezel, in: scene))")
        #expect(isClose(pixels, CGPoint(x: scene.videoFrame.midX, y: scene.videoFrame.midY), in: scene, to: red))
    }

    @Test("A device takes the place of the border")
    func noBorderOnADevice() {
        var edit = timeline(.iPad)
        edit.style.borderWidth = 0.02
        #expect(scene(edit).border == nil)
        edit.style.chrome.kind = .none
        #expect(scene(edit).border != nil)
    }

    // MARK: - Shadow, perspective, camera

    @Test("The handset casts the shadow, with its own corners")
    func shadowIsTheDevice() throws {
        let scene = scene(timeline(.iPhone))
        let device = try #require(scene.deviceGeometry)
        #expect(scene.shadowCaster == device.body)
        #expect(scene.shadowCornerRadius == device.bodyRadius)

        var shaded = timeline(.iPhone)
        shaded.style.shadowOpacity = 0.9
        shaded.style.shadowRadius = 0.02
        let (lit, pixels) = try render(shaded)
        let body = try #require(lit.deviceGeometry).body
        let below = CGPoint(x: body.midX, y: body.minY - 6)
        let shadow = colour(pixels, below, in: lit)
        #expect(shadow.b < 0.9, "darker than the background just under the device: \(shadow)")
    }

    @Test("A perspective turns the whole handset as one piece")
    func perspectiveTurnsTheDevice() throws {
        var edit = timeline(.iPhone)
        edit.style.perspective = FramePerspective(turn: 20, lean: 8)
        let scene = scene(edit)
        let projection = try #require(scene.perspectiveProjection)
        let device = try #require(scene.deviceGeometry)
        #expect(projection.plane == device.body)
        let (_, pixels) = try render(edit)
        let middle = projection.project(CGPoint(x: scene.videoFrame.midX, y: scene.videoFrame.midY))
        #expect(isClose(pixels, middle, in: scene, to: red), "the picture is still in the middle of the turned screen")
    }

    private func zoomed(_ timeline: Timeline, wholeFrame: Bool) -> Timeline {
        var timeline = timeline
        timeline.camera.zoomsWholeFrame = wholeFrame
        timeline.zooms = [ZoomRegion(start: .zero, duration: DressingFixtures.time(10), scale: 2,
                                     center: CGPoint(x: 0.5, y: 0.5), easing: .linear,
                                     transition: DressingFixtures.time(0.1), followsCursor: false)]
        return timeline
    }

    @Test("An inner zoom magnifies inside the screen and leaves the device where it was")
    func innerZoom() throws {
        let flat = try #require(scene(timeline(.iPad)).deviceGeometry)
        let (scene, pixels) = try render(zoomed(timeline(.iPad), wholeFrame: false), at: 5)
        #expect(scene.zoom == 2)
        let device = try #require(scene.deviceGeometry)
        #expect(device == flat)
        let bezel = CGPoint(x: device.body.midX, y: (device.screen.minY + device.body.minY + device.rim) / 2)
        #expect(isClose(pixels, bezel, in: scene, to: glass, within: 0.03), "the bezel stays: \(colour(pixels, bezel, in: scene))")
        #expect(isClose(pixels, CGPoint(x: device.screen.midX, y: device.screen.midY), in: scene, to: red))
    }

    @Test("A whole-frame zoom grows the device with the picture")
    func wholeFrameZoom() throws {
        let flat = try #require(scene(timeline(.iPad)).deviceGeometry)
        let scene = scene(zoomed(timeline(.iPad), wholeFrame: true), at: 5)
        let device = try #require(scene.deviceGeometry)
        #expect(abs(device.body.width - flat.body.width * 2) < 0.01)
        #expect(abs(device.bodyRadius - flat.bodyRadius * 2) < 0.01)
    }

    @Test("A preview-sized frame draws the same device, smaller")
    func scaledDescriptor() throws {
        let scene = scene(timeline(.iPhone))
        let full = try #require(scene.deviceGeometry)
        let half = try #require(scene.scaled(by: 0.5).deviceGeometry)
        #expect(abs(half.body.width - full.body.width / 2) < 0.01)
        #expect(abs(half.screenRadius - full.screenRadius / 2) < 0.01)
    }
}

/// The export goes through the exporter's own renderer on its own thread: the handset has
/// to be in the file, not only in the preview.
@Suite("Device frames in an export", .serialized, .timeLimit(.minutes(3)))
struct DeviceFrameExportTests {
    @Test("An exported frame has the device round the picture")
    func exported() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        let size = CGSize(width: 320, height: 180)
        try await ExportTests.writeSilentVideo(to: source, size: size, frames: 30, frameRate: 30)

        var edit = Timeline(sourceDuration: DressingFixtures.time(1))
        edit.style.background = .color(ColorValue(r: 1, g: 1, b: 1))
        edit.style.padding = 0.1
        edit.style.shadowOpacity = 0
        edit.style.chrome = WindowChrome(kind: .iPhone, finish: .silver)
        edit.cursor.isVisible = false
        let builder = SceneBuilder(videoSize: size)
        let exporter = VideoExporter(timeline: edit, builder: builder, cursor: nil,
                                     videoURL: source, packageURL: nil, settings: ExportSettings())
        let file = folder.appendingPathComponent("device.mp4")
        try await exporter.export(to: file)

        let pixels = try await DressingFixtures.frame(of: file, at: 0.5)
        let scene = builder.descriptor(for: edit, at: DressingFixtures.time(0.5))
        let device = try #require(scene.deviceGeometry)
        // The file is the scene scaled up round its margin, so positions are scaled with it.
        let k = Double(pixels.width) / scene.outputSize.width
        let height = scene.outputSize.height
        // The bezel's black, above the screen, and the white background outside the body.
        let bezelY = Int(k * (height - (device.screen.maxY + device.body.maxY - device.rim) / 2))
        let bezel = pixels.colour(Int(k * device.body.midX), bezelY)
        #expect(max(bezel.r, bezel.g, bezel.b) < 0.12, "the bezel is in the file: \(bezel)")
        let outside = pixels.colour(Int(k * device.body.midX), Int(k * (height - device.body.maxY)) - 4)
        #expect(min(outside.r, outside.g, outside.b) > 0.9, "the background round it: \(outside)")
        // And the picture: the fixture's blue-ish frame colour, not black.
        let middle = pixels.colour(Int(k * scene.videoFrame.midX), Int(k * (height - scene.videoFrame.midY)))
        #expect(middle.g > 0.25, "the picture is in the screen: \(middle)")
    }
}
