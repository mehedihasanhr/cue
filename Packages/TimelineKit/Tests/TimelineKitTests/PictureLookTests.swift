import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// The perspective, the colour grade and the moving backgrounds as stored settings: they
/// decode from files that do not have them, are held to what can be drawn, travel with a
/// look where they should, and are changed by named, undoable commands.
struct PictureLookTests {
    private func timeline() -> Timeline {
        Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
    }

    // MARK: - Old files

    @Test func aProjectWrittenBeforeTheseDecodesFlatAndUngraded() throws {
        var old = timeline()
        old.style.padding = 0.13
        let data = try JSONEncoder().encode(old)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var style = try #require(json["style"] as? [String: Any])
        style.removeValue(forKey: "perspective")
        style.removeValue(forKey: "grade")
        json["style"] = style
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Timeline.self, from: stripped)
        #expect(decoded.style.padding == 0.13, "the rest of the style survives")
        #expect(decoded.style.perspective == FramePerspective())
        #expect(decoded.style.perspective.isFlat)
        #expect(decoded.style.grade == ColorGrade())
        #expect(decoded.style.grade.isNeutral)
    }

    @Test func partsDecodeFieldByField() throws {
        let grade = try JSONDecoder().decode(ColorGrade.self, from: Data(#"{ "saturation": 0.4, "tint": "pink" }"#.utf8))
        #expect(grade.saturation == 0.4)
        #expect(grade.tint == 0, "an unreadable field is the default, not the whole grade lost")
        #expect(grade.lutIntensity == 1)

        let animation = try JSONDecoder().decode(AnimatedBackground.self,
                                                 from: Data(#"{ "kind": "lava", "speed": 40, "colors": [] }"#.utf8))
        #expect(animation.kind == .drift, "a kind this build does not know draws as the first")
        #expect(animation.speed == AnimatedBackground.speedRange.upperBound)
        #expect(animation.colors.count >= 2)
    }

    @Test func aMovingBackgroundHasTwoOrThreeColours() {
        #expect(AnimatedBackground(colors: [.white]).colors == [.white, .white])
        let many = [ColorValue.white, .black, ColorValue(r: 1, g: 0, b: 0), ColorValue(r: 0, g: 1, b: 0)]
        #expect(AnimatedBackground(colors: many).colors.count == 3)
    }

    // MARK: - Presets

    @Test func perspectivePresetsKeepTheOtherSettings() {
        var perspective = FramePerspective(depthShadow: 0.9, straightensWhenZoomed: false)
        perspective = perspective.with(.leanBack)
        #expect(perspective.lean > 0)
        #expect(perspective.turn == 0)
        #expect(perspective.depthShadow == 0.9)
        #expect(!perspective.straightensWhenZoomed)
        #expect(perspective.preset == .leanBack)
        #expect(FramePerspective().preset == .flat)
        perspective.turn += 1
        #expect(perspective.preset == nil, "moved off a preset is Custom")
    }

    @Test func tiltLeftSendsTheLeftEdgeAway() {
        #expect(FramePerspective().with(.tiltLeft).turn > 0)
        #expect(FramePerspective().with(.tiltRight).turn < 0)
    }

    // MARK: - Commands

    @Test func commandsAreNamedAndUndoable() {
        var edit = timeline()
        let before = edit
        #expect(Commands.applyPerspectivePreset(.isometric).apply(to: &edit))
        #expect(Commands.applyPerspectivePreset(.isometric).name == "Perspective: Isometric")
        #expect(!edit.style.perspective.isFlat)
        #expect(!Commands.applyPerspectivePreset(.isometric).apply(to: &edit), "the same again changes nothing")

        #expect(Commands.setStraightensWhenZoomed(false).apply(to: &edit))
        #expect(!edit.style.perspective.straightensWhenZoomed)

        #expect(Commands.applyColorPreset(.warm).apply(to: &edit))
        #expect(edit.style.grade.temperature > 0)

        let lut = LUTReference(path: "LUTs/a.cube", name: "A")
        #expect(Commands.setLUT(lut).apply(to: &edit))
        #expect(edit.style.grade.lut == lut)
        #expect(Commands.setLUT(nil).name == "Remove LUT")

        #expect(Commands.setAnimatedBackground(AnimatedBackground(kind: .aurora)).apply(to: &edit))
        #expect(edit.style.background.editableAnimation.kind == .aurora)
        #expect(Commands.setVideoBackground(path: "Backgrounds/a.mov").apply(to: &edit))
        #expect(edit.style.background.videoPath == "Backgrounds/a.mov")
        #expect(edit != before)
    }

    @Test func theSlidersAreHeldToTheirRanges() {
        var edit = timeline()
        _ = Commands.setPerspective(FramePerspective(turn: 80, lean: -80, rotation: 50)).apply(to: &edit)
        #expect(edit.style.perspective.turn == FramePerspective.turnRange.upperBound)
        #expect(edit.style.perspective.lean == FramePerspective.leanRange.lowerBound)
        #expect(edit.style.perspective.rotation == FramePerspective.rotationRange.upperBound)
        _ = Commands.setColorGrade(ColorGrade(brightness: 3, lutIntensity: -1)).apply(to: &edit)
        #expect(edit.style.grade.brightness == 1)
        #expect(edit.style.grade.lutIntensity == 0)
    }

    // MARK: - Looks

    @Test func aLookCarriesThePerspectiveAndTheGradeButNotTheTable() {
        var source = timeline()
        source.style.perspective = FramePerspective(depthShadow: 0.2).with(.tiltRight)
        source.style.grade = ColorGrade(contrast: 0.3, lut: LUTReference(path: "LUTs/mine.cube", name: "Mine"),
                                        lutIntensity: 0.6)
        source.style.background = .animated(AnimatedBackground(kind: .grain, speed: 2))
        let look = Look(name: "Tilted", capturing: source)
        #expect(look.frame.grade?.lut == nil, "the table stays with the recording it was loaded into")

        var target = timeline()
        let theirs = LUTReference(path: "LUTs/theirs.cube", name: "Theirs")
        target.style.grade.lut = theirs
        look.apply(to: &target)
        #expect(target.style.perspective == source.style.perspective)
        #expect(target.style.grade.contrast == 0.3)
        #expect(target.style.grade.lutIntensity == 0.6)
        #expect(target.style.grade.lut == theirs, "and the project's own table is kept")
        #expect(target.style.background == source.style.background, "a moving background travels")
        #expect(look.matches(target))
    }

    @Test func aLookLeavesABackgroundMovieBehind() {
        var source = timeline()
        source.style.background = .video(path: "Backgrounds/loop.mov")
        let look = Look(name: "Movie", capturing: source)
        #expect(look.frame.background == nil)
    }

    @Test func aLookFileIsHeldToTheSliders() throws {
        let json = #"{ "name": "Wild", "frame": { "perspective": { "turn": 400 }, "grade": { "saturation": -9, "lut": { "path": "x", "name": "x" } } } }"#
        let look = try #require(Look.decoded(from: Data(json.utf8)))
        #expect(look.frame.perspective?.turn == FramePerspective.turnRange.upperBound)
        #expect(look.frame.grade?.saturation == -1)
        #expect(look.frame.grade?.lut == nil, "a look file cannot point at a table")
    }

    @Test func aLookRoundTrips() throws {
        var source = timeline()
        source.style.perspective = FramePerspective().with(.isometric)
        source.style.grade = ColorGrade().with(.vivid)
        let look = Look(name: "Round", capturing: source)
        let decoded = try #require(Look.decoded(from: look.encoded()))
        #expect(decoded.frame.perspective == look.frame.perspective)
        #expect(decoded.frame.grade == look.frame.grade)
    }
}
