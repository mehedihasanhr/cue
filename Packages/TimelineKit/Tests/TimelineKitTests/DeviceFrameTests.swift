import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// iPhone and iPad frames, as stored values: what a project from before them opens as,
/// what a project with one opens as in a build that knows only some of it, and that a
/// look and the Undo menu carry them.
@Suite("Device frames")
struct DeviceFrameTests {
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

    @Test("A window saved before devices existed keeps its kind and appearance and gets the device defaults")
    func windowFromBeforeDevices() throws {
        let style = FrameStyle(padding: 0.09)
        let decoded = try roundTrip(style, as: FrameStyle.self) {
            // Exactly what a build from before devices wrote: two keys and nothing else.
            $0["chrome"] = ["kind": "browser", "appearance": "dark"]
        }
        #expect(decoded.chrome.kind == .browser)
        #expect(decoded.chrome.appearance == .dark)
        #expect(decoded.chrome.finish == .black)
        #expect(decoded.chrome.orientation == .automatic)
        #expect(decoded.chrome.showsCamera)
        #expect(decoded.padding == 0.09, "and nothing else about the frame moved")
    }

    @Test("A frame saved before any window existed opens with no device")
    func frameFromBeforeChrome() throws {
        let decoded = try roundTrip(FrameStyle(), as: FrameStyle.self) { $0.removeValue(forKey: "chrome") }
        #expect(decoded.chrome == WindowChrome())
        #expect(!decoded.chrome.kind.isDevice)
    }

    @Test("A whole timeline from before devices decodes with no device")
    func timelineFromBeforeDevices() throws {
        var timeline = Timeline(sourceDuration: time(4))
        timeline.style.chrome = WindowChrome(kind: .window)
        let data = try JSONEncoder().encode(timeline)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var style = try #require(object["style"] as? [String: Any])
        style["chrome"] = ["kind": "window", "appearance": "light"]
        object["style"] = style
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.style.chrome == WindowChrome(kind: .window))
    }

    @Test("A device survives a round trip with every one of its settings")
    func roundTripsEverything() throws {
        let chrome = WindowChrome(kind: .iPad, appearance: .dark, finish: .natural,
                                  orientation: .landscape, showsCamera: false)
        #expect(try roundTrip(chrome, as: WindowChrome.self) == chrome)
        #expect(try roundTrip(WindowChrome(kind: .iPhone), as: WindowChrome.self).kind == .iPhone)
    }

    @Test("A finish or orientation this build does not know falls back alone")
    func unknownDeviceValues() throws {
        let chrome = WindowChrome(kind: .iPhone, finish: .silver, orientation: .portrait, showsCamera: false)
        let decoded = try roundTrip(chrome, as: WindowChrome.self) {
            $0["finish"] = "rose gold"
            $0["orientation"] = "upside down"
        }
        #expect(decoded.kind == .iPhone)
        #expect(decoded.finish == .black)
        #expect(decoded.orientation == .automatic)
        #expect(!decoded.showsCamera, "the field that did decode is kept")
    }

    // MARK: - Orientation

    @Test("Automatic lies a device on its side for a wide picture and stands it up for a tall or square one")
    func automaticOrientation() {
        #expect(WindowChrome.Orientation.automatic.isLandscape(width: 1_920, height: 1_080))
        #expect(!WindowChrome.Orientation.automatic.isLandscape(width: 1_080, height: 1_920))
        #expect(!WindowChrome.Orientation.automatic.isLandscape(width: 1_000, height: 1_000))
        #expect(!WindowChrome.Orientation.portrait.isLandscape(width: 1_920, height: 1_080))
        #expect(WindowChrome.Orientation.landscape.isLandscape(width: 1_080, height: 1_920))
    }

    @Test("Only the phone and the tablet are devices")
    func kinds() {
        #expect(WindowChrome.Kind.allCases.filter(\.isDevice) == [.iPhone, .iPad])
        #expect(WindowChrome(kind: .iPad).isVisible)
    }

    // MARK: - Undo and looks

    @Test("Each device change is one named step, and repeating it is not an edit")
    func commands() {
        var timeline = Timeline(sourceDuration: time(5))
        let phone = Commands.setWindowChrome(.iPhone)
        #expect(phone.name == "Device Frame")
        #expect(phone.apply(to: &timeline))
        #expect(!phone.apply(to: &timeline))

        #expect(Commands.setDeviceFinish(.silver).apply(to: &timeline))
        #expect(Commands.setDeviceOrientation(.portrait).apply(to: &timeline))
        let hide = Commands.setDeviceCamera(false)
        #expect(hide.name == "Hide Device Camera")
        #expect(hide.apply(to: &timeline))
        #expect(timeline.style.chrome == WindowChrome(kind: .iPhone, finish: .silver,
                                                      orientation: .portrait, showsCamera: false))
    }

    @Test("A look carries the device, its finish, which way up it is and its camera")
    func lookCarriesDevice() throws {
        var source = Timeline(sourceDuration: time(5))
        source.style.chrome = WindowChrome(kind: .iPad, finish: .silver, orientation: .landscape, showsCamera: false)
        let look = try #require(Look.decoded(from: try Look(name: "Tablet", capturing: source).encoded()))
        var target = Timeline(sourceDuration: time(5))
        look.apply(to: &target)
        #expect(target.style.chrome == source.style.chrome)
    }
}
