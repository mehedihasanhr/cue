import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Transparent backgrounds, gradients of one's own, window frames and zoom motion blur, as
/// stored values: what an old project opens as, what a bad value resets to, and that a
/// look carries all of them.
@Suite("Frame dressing")
struct FrameDressingTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Encodes a value, lets the test change its JSON as a dictionary, and decodes it back.
    private func roundTrip<T: Codable>(_ value: T, as type: T.Type,
                                       _ change: (inout [String: Any]) -> Void = { _ in }) throws -> T {
        let data = try JSONEncoder().encode(value)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        let edited = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(T.self, from: edited)
    }

    // MARK: - Old projects

    @Test("A frame saved before window frames existed opens with none")
    func frameWithoutChrome() throws {
        var style = FrameStyle()
        style.padding = 0.11
        let decoded = try roundTrip(style, as: FrameStyle.self) { $0.removeValue(forKey: "chrome") }
        #expect(decoded.chrome == WindowChrome())
        #expect(!decoded.chrome.isVisible)
        #expect(decoded.padding == 0.11, "and nothing else about the frame moved")
    }

    @Test("A window kind this build does not know is no window, and costs nothing else")
    func unknownChromeResetsAlone() throws {
        var style = FrameStyle()
        style.padding = 0.13
        style.chrome = WindowChrome(kind: .browser, appearance: .dark)
        let decoded = try roundTrip(style, as: FrameStyle.self) {
            $0["chrome"] = ["kind": "tablet", "appearance": "dark"]
        }
        #expect(decoded.chrome.kind == .none)
        #expect(decoded.chrome.appearance == .dark, "the field that did decode is kept")
        #expect(decoded.padding == 0.13)
    }

    @Test("A camera saved before motion blur existed opens with it off")
    func cameraWithoutMotionBlur() throws {
        var camera = CameraStyle()
        camera.follow = 0.4
        let decoded = try roundTrip(camera, as: CameraStyle.self) { $0.removeValue(forKey: "motionBlur") }
        #expect(!decoded.motionBlur, "an approved film must look the same when it is opened again")
        #expect(decoded.follow == 0.4)
        #expect(CameraStyle().motionBlur, "a new project has it on")
    }

    @Test("A project with no camera at all has no motion blur")
    func timelineWithoutCamera() throws {
        let timeline = Timeline(sourceDuration: time(5))
        let decoded = try roundTrip(timeline, as: Timeline.self) { $0.removeValue(forKey: "camera") }
        #expect(!decoded.camera.motionBlur)
    }

    @Test("Clamping the camera keeps motion blur as it was")
    func sanitisedKeepsMotionBlur() {
        #expect(!CameraStyle(motionBlur: false).sanitised.motionBlur)
        #expect(CameraStyle(motionBlur: true).sanitised.motionBlur)
    }

    // MARK: - Backgrounds

    @Test("A transparent background and a gradient of one's own survive a save")
    func backgroundsRoundTrip() throws {
        var style = FrameStyle(background: .transparent)
        #expect(try roundTrip(style, as: FrameStyle.self).background == .transparent)

        let gradient = BackgroundGradient(stops: [.init(color: .white, location: 0),
                                                  .init(color: ColorValue(r: 1, g: 0, b: 0), location: 0.3),
                                                  .init(color: .black, location: 1)],
                                          shape: .radial, angle: 0.1)
        style.background = .customGradient(gradient)
        #expect(try roundTrip(style, as: FrameStyle.self).background == .customGradient(gradient))
    }

    @Test("A background this build cannot read costs only the background")
    func unreadableBackgroundResetsAlone() throws {
        var style = FrameStyle()
        style.cornerRadius = 0.05
        let decoded = try roundTrip(style, as: FrameStyle.self) { $0["background"] = ["hologram": [:]] }
        #expect(decoded.background == FrameStyle().background)
        #expect(decoded.cornerRadius == 0.05)
    }

    @Test("A gradient is held to two or three stops, in order, between the ends")
    func gradientIsTidied() throws {
        let many = (0..<7).map { BackgroundGradient.Stop(color: .white, location: Double(6 - $0) / 6) }
        let tidied = BackgroundGradient(stops: many)
        #expect(tidied.stops.count == 3)
        #expect(tidied.stops.map(\.location) == tidied.stops.map(\.location).sorted())

        let one = BackgroundGradient(stops: [.init(color: .black, location: 7)])
        #expect(one.stops.count == 2, "a single colour is a flat gradient, not a crash")
        #expect(one.stops.allSatisfy { (0...1).contains($0.location) })

        #expect(BackgroundGradient(stops: []).stops == BackgroundGradient.defaultStops)
    }

    @Test("A gradient with a shape this build does not know draws as a linear one")
    func unknownGradientShape() throws {
        let gradient = BackgroundGradient(shape: .radial, angle: 0.4)
        let decoded = try roundTrip(gradient, as: BackgroundGradient.self) { $0["shape"] = "conic" }
        #expect(decoded.shape == .linear)
        #expect(decoded.angle == 0.4)
        #expect(decoded.stops == gradient.stops)
    }

    @Test("Adding a third colour puts the mix of the other two in the middle")
    func addingAStopChangesNothingVisible() {
        let two = BackgroundGradient(stops: [.init(color: ColorValue(r: 1, g: 0, b: 0), location: 0),
                                             .init(color: ColorValue(r: 0, g: 0, b: 1), location: 1)])
        let three = two.withStopCount(3)
        #expect(three.stops.count == 3)
        #expect(three.stops[1].location == 0.5)
        #expect(three.stops[1].color == ColorValue(r: 0.5, g: 0, b: 0.5))
        #expect(three.withStopCount(2) == two, "and taking it away keeps the ends")
    }

    @Test("Editing a stock gradient starts from its own colours")
    func editableGradient() {
        let stock = FrameStyle.Background.gradient(from: .white, to: .black, angle: 0.3)
        let editable = stock.editableGradient
        #expect(editable.stops.map(\.color) == [.white, .black])
        #expect(editable.angle == 0.3)
        #expect(FrameStyle.Background.transparent.isTransparent)
        #expect(!stock.isTransparent)
    }

    // MARK: - Undo

    @Test("Each change is one named, undoable step, and repeating it is not an edit")
    func commandsAreNamed() {
        var timeline = Timeline(sourceDuration: time(5))

        let window = Commands.setWindowChrome(.window)
        #expect(window.name == "Window Frame")
        #expect(window.apply(to: &timeline))
        #expect(!window.apply(to: &timeline))
        #expect(Commands.setWindowChrome(.none).name == "Remove Window Frame")

        let dark = Commands.setWindowAppearance(.dark)
        #expect(dark.apply(to: &timeline))
        #expect(timeline.style.chrome == WindowChrome(kind: .window, appearance: .dark))

        let clear = Commands.makeBackgroundTransparent()
        #expect(clear.name == "Transparent Background")
        #expect(clear.apply(to: &timeline))
        #expect(timeline.style.background.isTransparent)

        let gradient = Commands.setBackgroundGradient(BackgroundGradient(shape: .radial))
        #expect(gradient.name == "Gradient")
        #expect(gradient.apply(to: &timeline))

        let blur = Commands.setZoomMotionBlur(false)
        #expect(blur.name == "Turn Off Zoom Motion Blur")
        #expect(blur.apply(to: &timeline))
        #expect(!timeline.camera.motionBlur)
        #expect(Commands.setZoomMotionBlur(true).name == "Turn On Zoom Motion Blur")
    }

    // MARK: - Looks

    @Test("Every frame setting but the crop is in a look")
    func frameFidelity() {
        let names = { (value: Any) in Set(Mirror(reflecting: value).children.compactMap(\.label)) }
        // The crop is left out on purpose: it is a rectangle of one recording. See `Look`.
        let style = names(FrameStyle()).subtracting(["crop"])
        let carried = names(Look.Frame(FrameStyle()))
        #expect(style.subtracting(carried).isEmpty, "missing from Look.Frame: \(style.subtracting(carried).sorted())")
    }

    @Test("A look carries the window, the background and the camera's motion blur")
    func lookCarriesDressing() throws {
        var source = Timeline(sourceDuration: time(5))
        source.style.chrome = WindowChrome(kind: .browser, appearance: .dark)
        source.style.background = .customGradient(BackgroundGradient(shape: .radial))
        source.camera.motionBlur = false

        let look = try #require(Look.decoded(from: try Look(name: "Dressed", capturing: source).encoded()))
        var target = Timeline(sourceDuration: time(5))
        look.apply(to: &target)
        #expect(target.style.chrome == source.style.chrome)
        #expect(target.style.background == source.style.background)
        #expect(!target.camera.motionBlur)

        source.style.background = .transparent
        let clear = try #require(Look.decoded(from: try Look(name: "Clear", capturing: source).encoded()))
        clear.apply(to: &target)
        #expect(target.style.background == .transparent)
    }

    @Test("The factory look takes a window frame away, and still matches a new project")
    func studioLookHasNoWindow() throws {
        let studio = try #require(Look.builtIn.first { $0.name == "Studio" })
        var timeline = Timeline(sourceDuration: time(5))
        #expect(studio.matches(timeline))
        timeline.style.chrome.kind = .window
        studio.apply(to: &timeline)
        #expect(timeline.style.chrome.kind == .none)
    }
}
