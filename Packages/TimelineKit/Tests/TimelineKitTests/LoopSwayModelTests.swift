import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// The looping pointer, the leaning arrow and the whole video held zoomed in, as the
/// document stores them and as the arithmetic behind them answers.
@Suite("Loop, sway and whole-video zoom: the model")
struct LoopSwayModelTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    // MARK: - Loop timing

    @Test func aLoopThatIsOffNeverMovesThePointer() {
        let loop = PointerLoop(isEnabled: false, duration: 1)
        for t in stride(from: 0.0, through: 10, by: 0.25) {
            #expect(loop.blend(at: t, length: 10) == 0)
        }
    }

    @Test func theJourneyHomeFillsTheLastStretchAndNoMore() {
        let loop = PointerLoop(isEnabled: true, duration: 1.5)
        #expect(loop.blend(at: 0, length: 10) == 0)
        #expect(loop.blend(at: 8.5, length: 10) == 0, "the journey has not begun")
        #expect(loop.blend(at: 10, length: 10) == 1, "home on the last moment")
        #expect(abs(loop.blend(at: 9.25, length: 10) - 0.5) < 1e-9, "halfway, halfway home")
        // Never backwards, never past home.
        var previous = 0.0
        for t in stride(from: 8.5, through: 10, by: 0.01) {
            let blend = loop.blend(at: t, length: 10)
            #expect(blend >= previous - 1e-12)
            #expect((0...1).contains(blend))
            previous = blend
        }
    }

    @Test func theJourneyLeavesAndArrivesWithoutAKink() {
        let loop = PointerLoop(isEnabled: true, duration: 1)
        let h = 1e-4
        // Speed at both ends is nothing: the path is left and the home arrived at at rest.
        #expect(abs(loop.blend(at: 9 + h, length: 10) - loop.blend(at: 9, length: 10)) / h < 1e-3)
        #expect(abs(loop.blend(at: 10, length: 10) - loop.blend(at: 10 - h, length: 10)) / h < 1e-3)
    }

    @Test func aShortVideoGivesHalfOfItselfToTheJourney() {
        let loop = PointerLoop(isEnabled: true, duration: 2)
        #expect(loop.blend(at: 1.49, length: 3) == 0)
        #expect(loop.blend(at: 1.6, length: 3) > 0)
        #expect(loop.blend(at: 3, length: 3) == 1)
    }

    @Test func theTimelineAsksAtItsOwnLength() {
        var timeline = Timeline(sourceDuration: time(10))
        #expect(timeline.pointerLoopBlend(at: time(9.99)) == 0)
        timeline.cursor.loop = PointerLoop(isEnabled: true, duration: 1)
        #expect(timeline.pointerLoopBlend(at: time(9.99)) > 0.99)
        #expect(timeline.pointerLoopBlend(at: time(8)) == 0)
    }

    @Test func aLoopCannotAskForAJourneyTheSliderCouldNot() throws {
        #expect(PointerLoop(duration: 40).duration == PointerLoop.durationRange.upperBound)
        #expect(PointerLoop(duration: 0.01).duration == PointerLoop.durationRange.lowerBound)
        #expect(PointerLoop(duration: .nan).duration == 1)
        let decoded = try JSONDecoder().decode(PointerLoop.self, from: Data(#"{"isEnabled":true,"duration":9}"#.utf8))
        #expect(decoded.isEnabled)
        #expect(decoded.duration == 2)
        #expect(decoded.bringsCameraBack, "missing, so the default")
    }

    // MARK: - Sway

    @Test func theSpringsResponseAddsUpToOne() {
        var total = 0.0
        let step = 1e-4
        for index in 0..<Int(3 / step) {
            total += PointerSway.response((Double(index) + 0.5) * step) * step
        }
        #expect(abs(total - 1) < 0.01, "\(total)")
    }

    @Test func aStillPointerStandsUpright() {
        let sway = PointerSway(isEnabled: true, strength: 1)
        let angle = sway.angle(at: 5, position: { _ in CGPoint(x: 300, y: 200) }, frameWidth: 800)
        #expect(angle == 0)
    }

    @Test func aPointerTravellingRightLeansOneWayAndLeftTheOther() {
        let sway = PointerSway(isEnabled: true, strength: 1)
        let right = sway.angle(at: 5, position: { CGPoint(x: $0 * 400, y: 200) }, frameWidth: 800)
        let left = sway.angle(at: 5, position: { CGPoint(x: 4_000 - $0 * 400, y: 200) }, frameWidth: 800)
        #expect(right > 0)
        #expect(left < 0)
        #expect(abs(right + left) < 1e-9, "mirror images")
        // Steady travel settles on the lean its speed asks for.
        let asked = sway.target(forSpeed: 0.5)
        #expect(abs(right - asked) < asked * 0.05, "\(right) against \(asked)")
    }

    @Test func theLeanNeverPassesItsLimit() {
        let sway = PointerSway(isEnabled: true, strength: 1)
        let limit = PointerSway.maximumAngle * .pi / 180
        // A flick: still, then five frame widths a second for a tenth of a second, then still.
        let position: (Double) -> CGPoint? = { t in
            let moving = min(max(t - 4.9, 0), 0.1)
            return CGPoint(x: 100 + moving * 4_000, y: 200)
        }
        var largest = 0.0
        for t in stride(from: 4.8, through: 6, by: 1.0 / 60) {
            largest = max(largest, abs(sway.angle(at: t, position: position, frameWidth: 800)))
        }
        #expect(largest > limit * 0.3, "a flick is seen")
        #expect(largest <= limit * 1.25 + 1e-9)
    }

    @Test func theArrowStandsUpAgainOnceThePointerStops() {
        let sway = PointerSway(isEnabled: true, strength: 1)
        let position: (Double) -> CGPoint? = { t in CGPoint(x: min(t, 5) * 300, y: 200) }
        #expect(sway.angle(at: 4.9, position: position, frameWidth: 800) > 0.1)
        #expect(abs(sway.angle(at: 5.7, position: position, frameWidth: 800)) < 1e-9, "a spring's memory is finite")
    }

    @Test func aJumpIsNotAFlick() {
        let sway = PointerSway(isEnabled: true, strength: 1)
        // Still either side of a cut that moves the pointer across the whole frame.
        let position: (Double) -> CGPoint? = { t in CGPoint(x: t < 5 ? 50 : 750, y: 200) }
        #expect(sway.angle(at: 5.1, position: position, frameWidth: 800) == 0)
    }

    @Test func goingStraightUpOrDownDoesNotLean() {
        let sway = PointerSway(isEnabled: true, strength: 1)
        #expect(sway.angle(at: 5, position: { CGPoint(x: 300, y: $0 * 300) }, frameWidth: 800) == 0)
    }

    @Test func strengthScalesTheLean() {
        let gentle = PointerSway(isEnabled: true, strength: 0.25)
        let full = PointerSway(isEnabled: true, strength: 1)
        let path: (Double) -> CGPoint? = { CGPoint(x: $0 * 200, y: 0) }
        let a = gentle.angle(at: 3, position: path, frameWidth: 800)
        let b = full.angle(at: 3, position: path, frameWidth: 800)
        #expect(abs(a * 4 - b) < 1e-9)
        #expect(PointerSway(isEnabled: false).angle(at: 3, position: path, frameWidth: 800) == 0)
    }

    // MARK: - The document

    @Test func aProjectWrittenBeforeThemHasNeither() throws {
        let style = try JSONDecoder().decode(CursorStyle.self, from: Data(#"{"scale": 2}"#.utf8))
        #expect(style.scale == 2)
        #expect(style.loop == PointerLoop())
        #expect(!style.loop.isEnabled)
        #expect(style.sway == PointerSway())
        let camera = try JSONDecoder().decode(CameraStyle.self, from: Data(#"{"follow": 0.5}"#.utf8))
        #expect(camera.wholeVideoZoom == 1)
        #expect(!camera.holdsWholeVideoZoomed)
    }

    @Test func theyRoundTrip() throws {
        var style = CursorStyle()
        style.loop = PointerLoop(isEnabled: true, duration: 1.5, bringsCameraBack: false)
        style.sway = PointerSway(isEnabled: true, strength: 0.3)
        let back = try JSONDecoder().decode(CursorStyle.self, from: JSONEncoder().encode(style))
        #expect(back == style)
        var camera = CameraStyle()
        camera.wholeVideoZoom = 2.5
        #expect(try JSONDecoder().decode(CameraStyle.self, from: JSONEncoder().encode(camera)) == camera)
    }

    @Test func aFileCannotHoldTheVideoAtFortyTimes() {
        var camera = CameraStyle()
        camera.wholeVideoZoom = 40
        #expect(camera.sanitised.wholeVideoZoom == CameraStyle.wholeVideoZoomRange.upperBound)
        camera.wholeVideoZoom = 0.2
        #expect(camera.sanitised.wholeVideoZoom == 1)
        camera.wholeVideoZoom = .infinity
        #expect(camera.sanitised.wholeVideoZoom == 1)
    }

    @Test func aLookCarriesAllThree() {
        var source = Timeline(sourceDuration: time(10))
        source.cursor.loop = PointerLoop(isEnabled: true, duration: 0.75)
        source.cursor.sway = PointerSway(isEnabled: true, strength: 0.9)
        source.camera.wholeVideoZoom = 1.8
        let look = Look(name: "Hero", capturing: source)
        var target = Timeline(sourceDuration: time(10))
        look.apply(to: &target)
        #expect(target.cursor.loop == source.cursor.loop)
        #expect(target.cursor.sway == source.cursor.sway)
        #expect(target.camera.wholeVideoZoom == 1.8)
    }

    @Test func aLookFileCannotHoldTheVideoFurtherInThanTheSlider() throws {
        let json = #"{ "name": "Deep", "camera": { "wholeVideoZoom": 12 } }"#
        let look = try #require(Look.decoded(from: Data(json.utf8)))
        var target = Timeline(sourceDuration: time(10))
        look.apply(to: &target)
        #expect(target.camera.wholeVideoZoom == CameraStyle.wholeVideoZoomRange.upperBound)
    }
}
