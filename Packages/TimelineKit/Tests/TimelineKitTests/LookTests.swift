import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// A look: what it takes from a project, what it puts on one, and what its file does
/// across builds.
struct LookTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A project that is wearing nothing the factory gave it.
    private func dressed() -> Timeline {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.style.background = .color(ColorValue(r: 0.1, g: 0.2, b: 0.3))
        timeline.style.padding = 0.11
        timeline.style.cornerRadius = 0.033
        timeline.style.shadowRadius = 0.044
        timeline.style.shadowOpacity = 0.55
        timeline.style.backgroundBlur = 0.01
        timeline.style.aspect = .custom
        timeline.style.customAspect = CustomAspect(width: 5, height: 4)
        timeline.style.borderWidth = 0.01
        timeline.style.borderColor = ColorValue(r: 1, g: 0.5, b: 0)
        timeline.style.crop = CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        timeline.cursor.scale = 2.2
        timeline.cursor.isVisible = false
        timeline.cursor.clickStyle = .glow
        timeline.captionStyle.typeface = .serif
        timeline.captionStyle.fontSize = 0.07
        timeline.camera.zoomsWholeFrame = false
        timeline.camera.follow = 0.4
        timeline.webcam.isEnabled = true
        timeline.webcam.corner = .topLeft
        timeline.webcam.size = 0.3
        timeline.zooms = [ZoomRegion(start: time(1), duration: time(3))]
        return timeline
    }

    // MARK: - What a look is

    @Test func aLookTakesTheDressingAndLeavesTheRecordingsOwnThingsAlone() {
        let source = dressed()
        let look = Look(name: "Mine", capturing: source)
        var plain = Timeline(sourceDuration: time(60))
        plain.blurs = [BlurRegion(start: .zero, duration: time(2), rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))]
        look.apply(to: &plain)

        #expect(plain.style.background == source.style.background)
        #expect(plain.style.padding == 0.11)
        #expect(plain.style.aspect == .custom)
        #expect(plain.style.customAspect == CustomAspect(width: 5, height: 4))
        #expect(plain.style.borderWidth == 0.01)
        #expect(plain.cursor.scale == 2.2)
        #expect(plain.cursor.isVisible == false, "no pointer is a way a video can be dressed")
        #expect(plain.cursor.clickStyle == .glow)
        #expect(plain.captionStyle.typeface == .serif)
        #expect(plain.camera.zoomsWholeFrame == false)
        #expect(plain.webcam.corner == .topLeft)
        #expect(plain.webcam.size == 0.3)

        #expect(plain.style.crop == nil, "a crop belongs to one recording")
        #expect(plain.zooms.isEmpty, "nothing with a time on it")
        #expect(plain.blurs.count == 1)
        #expect(plain.webcam.isEnabled == false, "a look never switches a bubble on with nothing behind it")
        #expect(plain.duration == time(60))
    }

    @Test func aPictureInsideTheProjectIsLeftOutOfTheLook() {
        var source = dressed()
        source.style.background = .image(path: "Backgrounds/mine.heic")
        let look = Look(name: "Mine", capturing: source)
        #expect(look.frame.background == nil)

        var other = Timeline(sourceDuration: time(10))
        other.style.background = .color(.black)
        look.apply(to: &other)
        #expect(other.style.background == .color(.black), "applying keeps whatever background the project had")
        #expect(other.style.padding == 0.11)
    }

    @Test func aLookSaysOnlyWhatItSays() {
        var look = Look(name: "Padding only")
        look.frame.padding = 0.2
        var timeline = dressed()
        let before = timeline
        look.apply(to: &timeline)
        #expect(timeline.style.padding == 0.2)
        timeline.style.padding = before.style.padding
        #expect(timeline == before, "nothing else moved")
    }

    @Test func aProjectMatchesTheLookItIsWearing() {
        let source = dressed()
        let look = Look(name: "Mine", capturing: source)
        #expect(look.matches(source))
        var changed = source
        changed.style.padding += 0.01
        #expect(!look.matches(changed))
        // The recording's own things do not come into it.
        var cropped = source
        cropped.style.crop = nil
        cropped.zooms = []
        #expect(look.matches(cropped))
        #expect(!Look(name: "Nothing").matches(source), "an empty look is worn by nobody")
        #expect(Look(name: "Nothing").isEmpty)
    }

    // MARK: - The file

    @Test func theFileCarriesAVersionAndComesBackTheSame() throws {
        let look = Look(name: "Mine", capturing: dressed())
        let data = try look.encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == Look.currentVersion)
        #expect(object["name"] as? String == "Mine")
        #expect(object["frame"] is [String: Any])
        #expect(object["pointer"] is [String: Any])
        #expect(object["captions"] is [String: Any])
        #expect(object["camera"] is [String: Any])
        #expect(object["webcam"] is [String: Any])

        let back = try #require(Look.decoded(from: data))
        #expect(back == look)
        #expect(back.matches(dressed()), "what was written is what is read, to the last digit")
    }

    /// A file from a newer build: keys this build has never heard of, and a value it
    /// cannot read. Both are skipped; everything it *can* read is kept.
    @Test func unknownFieldsAreIgnoredAndUnreadableOnesAreMissing() throws {
        let json = """
        {"version": 7, "name": "Future", "hologram": {"depth": 3},
         "frame": {"padding": 0.15, "aspect": "ultrawide21x9", "lighting": "soft"},
         "pointer": {"clickStyle": "sparkle", "scale": 1.9},
         "captions": "none",
         "camera": {"follow": 0.5}}
        """
        let look = try #require(Look.decoded(from: Data(json.utf8)))
        #expect(look.name == "Future")
        #expect(look.frame.padding == 0.15)
        #expect(look.frame.aspect == nil, "a shape this build cannot draw is treated as unsaid")
        #expect(look.pointer.scale == 1.9)
        #expect(look.pointer.clickStyle == nil)
        #expect(look.captions.isEmpty, "a part that is not a part is an empty part")
        #expect(look.camera.follow == 0.5)

        var timeline = dressed()
        let before = timeline
        look.apply(to: &timeline)
        #expect(timeline.style.padding == 0.15)
        #expect(timeline.style.aspect == before.style.aspect, "missing keeps the project's own")
        #expect(timeline.cursor.clickStyle == before.cursor.clickStyle)
        #expect(timeline.cursor.scale == 1.9)
    }

    /// A file from an older build: fewer keys. The ones it lacks keep the project's value.
    @Test func anOlderFileAppliesToANewerProjectWithoutResettingAnything() throws {
        let json = #"{"version": 1, "name": "Old", "frame": {"padding": 0.02, "cornerRadius": 0.05}}"#
        let look = try #require(Look.decoded(from: Data(json.utf8)))
        var timeline = dressed()
        let before = timeline
        look.apply(to: &timeline)
        #expect(timeline.style.padding == 0.02)
        #expect(timeline.style.cornerRadius == 0.05)
        #expect(timeline.style.borderWidth == before.style.borderWidth)
        #expect(timeline.style.background == before.style.background)
        #expect(timeline.cursor == before.cursor)
        #expect(timeline.captionStyle == before.captionStyle)
    }

    @Test func somethingThatIsNotALookIsRefused() {
        #expect(Look.decoded(from: Data("[1, 2, 3]".utf8)) == nil)
        #expect(Look.decoded(from: Data("not json".utf8)) == nil)
        #expect(Look.decoded(from: Data()) == nil)
        let empty = Look.decoded(from: Data("{}".utf8))
        #expect(empty?.isEmpty == true)
        #expect(empty?.name == "")
    }

    @Test func aLookThatDoesNotSayItsVersionIsStillALook() throws {
        let look = try #require(Look.decoded(from: Data(#"{"frame": {"padding": 0.09}}"#.utf8)))
        #expect(look.frame.padding == 0.09)
    }

    // MARK: - The command

    @Test func applyingALookIsOneEditThatIsRefusedWhenAlreadyWorn() {
        var timeline = Timeline(sourceDuration: time(30))
        let look = Look(name: "Mine", capturing: dressed())
        #expect(Commands.ApplyLook(look).apply(to: &timeline))
        #expect(look.matches(timeline))
        #expect(Commands.ApplyLook(look).apply(to: &timeline) == false, "nothing to do, so no undo entry")
        #expect(Commands.ApplyLook(look).name == "Apply Look")
    }

    @MainActor
    @Test func undoingAnAppliedLookTakesAllOfItBack() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KlikStudioTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try RecordingPackage.create(named: "Take", in: folder)
        try package.write(RecordingManifest(name: "Take", duration: 30))
        let document = try EditorDocument(package: package)
        let before = document.timeline

        document.apply(Commands.ApplyLook(Look(name: "Mine", capturing: dressed())))
        #expect(document.timeline.style.padding == 0.11)
        #expect(document.timeline.cursor.scale == 2.2)
        #expect(document.undoName == "Apply Look")
        document.undo()
        #expect(document.timeline == before)
    }

    // MARK: - The built-in ones

    @Test func theBuiltInLooksAreAFewClearlyDifferentFrames() {
        let looks = Look.builtIn
        #expect(looks.count >= 4 && looks.count <= 6)
        #expect(Set(looks.map(\.name)).count == looks.count, "no two share a name")
        for (index, look) in looks.enumerated() {
            #expect(!look.isEmpty)
            #expect(!look.frame.isEmpty, "\(look.name) dresses the frame")
            #expect(look.pointer.isEmpty && look.captions.isEmpty && look.camera.isEmpty && look.webcam.isEmpty,
                    "\(look.name) leaves the pointer, captions and camera to the person")
            for other in looks[(index + 1)...] {
                #expect(look.frame != other.frame, "\(look.name) and \(other.name) look the same")
            }
        }
        #expect(Set(Look.builtInNames) == Set(looks.map(\.name)))
    }

    @Test func aFreshProjectIsWearingTheFirstBuiltInLook() throws {
        let studio = try #require(Look.builtIn.first)
        #expect(studio.matches(Timeline(sourceDuration: time(30))))
        #expect(Look.builtIn.dropFirst().allSatisfy { !$0.matches(Timeline(sourceDuration: time(30))) })
    }
}
