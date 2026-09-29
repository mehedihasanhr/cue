import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// A look carries every pointer and caption setting there is.
///
/// Those two lists are written out field by field in `Look`, so a setting added to the
/// pointer or the captions is silently left out of every saved look until somebody
/// remembers to add it there too. These catch that: every stored field is counted, and
/// every one has to survive a look taken from one project and put on another.
@Suite("Looks keep every setting")
struct LookFidelityTests {
    private func fieldNames(of value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    @Test("Every pointer setting is in a look")
    func pointer() {
        let style = fieldNames(of: CursorStyle())
        let carried = fieldNames(of: Look.Pointer(CursorStyle()))
        #expect(style.subtracting(carried).isEmpty, "missing from Look.Pointer: \(style.subtracting(carried).sorted())")
    }

    @Test("Every caption setting is in a look")
    func captions() {
        let style = fieldNames(of: CaptionStyle())
        let carried = fieldNames(of: Look.Captions(CaptionStyle()))
        #expect(style.subtracting(carried).isEmpty, "missing from Look.Captions: \(style.subtracting(carried).sorted())")
    }

    @Test("Every camera setting is in a look")
    func camera() {
        let style = fieldNames(of: CameraStyle())
        let carried = fieldNames(of: Look.Camera(CameraStyle()))
        #expect(style.subtracting(carried).isEmpty, "missing from Look.Camera: \(style.subtracting(carried).sorted())")
    }

    /// The one frame setting a look leaves out on purpose: the crop, a rectangle of one
    /// particular recording.
    private static let frameSettingsNotInALook: Set<String> = ["crop"]

    @Test("Every frame setting is in a look")
    func frame() {
        let style = fieldNames(of: FrameStyle()).subtracting(Self.frameSettingsNotInALook)
        let carried = fieldNames(of: Look.Frame(FrameStyle()))
        #expect(style.subtracting(carried).isEmpty, "missing from Look.Frame: \(style.subtracting(carried).sorted())")
        #expect(Self.frameSettingsNotInALook.isSubset(of: fieldNames(of: FrameStyle())))
    }

    /// The two bubble settings a look leaves out on purpose, and nothing else.
    private static let webcamSettingsNotInALook: Set<String> = ["isEnabled", "crop"]

    @Test("Every camera bubble setting is in a look")
    func webcam() {
        // Whether the bubble is on is left out on purpose: a recording either has a camera
        // in it or it does not, and a look must not switch on a bubble with nothing behind
        // it. The camera's crop is left out for the screen crop's reason: it frames one
        // take's face. See the list at the top of `Look`.
        let style = fieldNames(of: WebcamSettings()).subtracting(Self.webcamSettingsNotInALook)
        let carried = fieldNames(of: Look.Webcam(WebcamSettings()))
        #expect(style.subtracting(carried).isEmpty, "missing from Look.Webcam: \(style.subtracting(carried).sorted())")
        // And the list of exceptions stays honest: a name here that is not a setting any
        // more would excuse a real one added under it later.
        #expect(Self.webcamSettingsNotInALook.isSubset(of: fieldNames(of: WebcamSettings())))
    }

    @Test("The camera's border and background travel with a look; its crop and switch do not")
    func webcamValues() {
        var source = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        source.webcam.borderWidth = 0.05
        source.webcam.borderColor = ColorValue(r: 1, g: 0.2, b: 0.1)
        source.webcam.background = .remove
        source.webcam.backgroundBlur = 0.8
        source.webcam.crop = WebcamCrop(zoom: 2, offset: CGPoint(x: 0.5, y: -0.5))
        source.webcam.isEnabled = true
        let look = Look(name: "Framed", capturing: source)

        var target = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        look.apply(to: &target)
        #expect(target.webcam.borderWidth == 0.05)
        #expect(target.webcam.borderColor == ColorValue(r: 1, g: 0.2, b: 0.1))
        #expect(target.webcam.background == .remove)
        #expect(target.webcam.backgroundBlur == 0.8)
        #expect(target.webcam.crop == WebcamCrop(), "the crop belongs to the take it framed")
        #expect(!target.webcam.isEnabled, "and a look never switches a camera on")
    }

    @Test("A look file cannot ask for a border the slider could not")
    func webcamBorderIsClamped() throws {
        let json = #"{ "name": "Wide", "webcam": { "borderWidth": 4, "backgroundBlur": -2 } }"#
        let look = try #require(Look.decoded(from: Data(json.utf8)))
        var target = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        look.apply(to: &target)
        #expect(target.webcam.borderWidth == WebcamSettings.borderWidthRange.upperBound)
        #expect(target.webcam.backgroundBlur == 0)
    }

    @Test("Click sounds travel with a look")
    func clickSounds() {
        var source = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        source.cursor.clickSound = true
        source.cursor.clickSoundKind = .crisp
        source.cursor.clickSoundVolume = 0.8
        let look = Look(name: "Loud", capturing: source)
        var target = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        look.apply(to: &target)
        #expect(target.cursor.clickSound)
        #expect(target.cursor.clickSoundKind == .crisp)
        #expect(target.cursor.clickSoundVolume == 0.8)
    }
}
