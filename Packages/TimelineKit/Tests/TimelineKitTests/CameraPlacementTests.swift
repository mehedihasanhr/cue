import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// The camera moving and changing size over the video.
struct CameraPlacementTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    private let left = CameraPlacement(centre: CGPoint(x: 0.2, y: 0.2), size: 0.2)
    private let right = CameraPlacement(centre: CGPoint(x: 0.8, y: 0.8), size: 0.4)
    private let glide = Timeline.cameraMoveTransition

    private func timeline(length: Double = 60) -> Timeline {
        var timeline = Timeline(sourceDuration: time(length))
        timeline.webcam.isEnabled = true
        return timeline
    }

    @Test func aProjectWithNoMovesStaysWhereThePanelPutsIt() {
        #expect(timeline().cameraPlacement(at: time(10)) == .steady(nil))
    }

    @Test func aMoveHasArrivedAtTheFrameItWasMadeOn() {
        var t = timeline()
        #expect(Commands.PlaceCamera(at: time(10), placement: left).apply(to: &t))
        #expect(t.cameraPlacement(at: time(10)) == .steady(left))
    }

    @Test func itHoldsUntilTheEndOfTheVideo() {
        var t = timeline()
        _ = Commands.PlaceCamera(at: time(10), placement: left).apply(to: &t)
        #expect(t.cameraPlacement(at: time(40)) == .steady(left))
        #expect(t.cameraPlacement(at: time(59.99)) == .steady(left), "and does not glide back as the video ends")
    }

    @Test func beforeAMoveTheCameraIsWhereItWas() {
        var t = timeline()
        _ = Commands.PlaceCamera(at: time(10), placement: left).apply(to: &t)
        #expect(t.cameraPlacement(at: time(5)) == .steady(nil))
    }

    @Test func itCanMoveManyTimes() {
        var t = timeline()
        _ = Commands.PlaceCamera(at: time(10), placement: left).apply(to: &t)
        _ = Commands.PlaceCamera(at: time(20), placement: right).apply(to: &t)
        _ = Commands.PlaceCamera(at: time(30), placement: left).apply(to: &t)
        #expect(t.cameraLayouts.count == 3)
        #expect(t.cameraPlacement(at: time(15)) == .steady(left))
        #expect(t.cameraPlacement(at: time(25)) == .steady(right))
        #expect(t.cameraPlacement(at: time(45)) == .steady(left))
    }

    @Test func aMoveMadeBetweenTwoEndsWhereTheNextBegins() {
        var t = timeline()
        _ = Commands.PlaceCamera(at: time(30), placement: left).apply(to: &t)
        _ = Commands.PlaceCamera(at: time(10), placement: right).apply(to: &t)
        #expect(t.cameraPlacement(at: time(20)) == .steady(right))
        #expect(t.cameraPlacement(at: time(45)) == .steady(left))
    }

    @Test func theGlideIsContinuousAndEased() {
        var t = timeline()
        _ = Commands.PlaceCamera(at: time(10), placement: left).apply(to: &t)
        _ = Commands.PlaceCamera(at: time(20), placement: right).apply(to: &t)
        let start = 20 - glide
        #expect(t.cameraPlacement(at: time(start - 0.01)) == .steady(left))
        var last = 0.0
        for step in 1..<12 {
            let state = t.cameraPlacement(at: time(start + glide * Double(step) / 12))
            #expect(state.from == left && state.to == right)
            #expect(state.progress > last, "never jumps back")
            last = state.progress
        }
        let early = t.cameraPlacement(at: time(start + glide * 0.05)).progress
        #expect(early < 0.05, "sets off gently: eased, not linear")
    }

    @Test func aMoveTooCloseToTheLastChangesItInstead() {
        var t = timeline()
        _ = Commands.PlaceCamera(at: time(10), placement: left).apply(to: &t)
        _ = Commands.PlaceCamera(at: time(10.1), placement: right).apply(to: &t)
        #expect(t.cameraLayouts.count == 1)
        #expect(t.cameraPlacement(at: time(30)) == .steady(right))
    }

    @Test func aMoveAtTheVeryStartIsSimplyThere() {
        var t = timeline()
        _ = Commands.PlaceCamera(at: time(0), placement: left).apply(to: &t)
        #expect(t.cameraPlacement(at: time(0)) == .steady(left))
    }

    @Test func aStretchEndingEarlyGlidesBack() throws {
        var t = timeline()
        t.cameraLayouts = [CameraLayoutRegion(start: time(10), duration: time(5), layout: .bubble, placement: left)]
        let state = t.cameraPlacement(at: time(15 - glide / 2))
        #expect(state.from == left && state.to == nil && state.progress > 0)
        #expect(t.cameraPlacement(at: time(16)) == .steady(nil))
    }

    @Test func hidingTheCameraDoesNotMoveIt() {
        var t = timeline()
        _ = Commands.PlaceCamera(at: time(10), placement: left).apply(to: &t)
        t.cameraLayouts.append(CameraLayoutRegion(start: time(20), duration: time(5), layout: .hidden))
        t.cameraLayouts.sort { $0.start < $1.start }
        #expect(t.cameraPlacement(at: time(22)) == .steady(left))
        #expect(t.cameraLayout(at: time(22)).to == .hidden)
    }

    @Test func sizeFollowsTheGlide() {
        var t = timeline()
        _ = Commands.PlaceCamera(at: time(10), placement: left).apply(to: &t)
        _ = Commands.PlaceCamera(at: time(20), placement: right).apply(to: &t)
        #expect(t.webcamSize(at: time(15)) == 0.2)
        #expect(t.webcamSize(at: time(30)) == 0.4)
        let halfway = t.webcamSize(at: time(20 - glide / 2))
        #expect(abs(halfway - 0.3) < 0.001)
    }

    @Test func aPlacementSurvivesBeingSaved() throws {
        var t = timeline()
        _ = Commands.PlaceCamera(at: time(10), placement: left).apply(to: &t)
        let read = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(t))
        #expect(read.cameraPlacement(at: time(30)) == .steady(left))
    }

    @Test func aStretchWrittenBeforeMovesHasNoPlacement() throws {
        let original = CameraLayoutRegion(start: time(1), duration: time(5), layout: .hidden)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["placement"] = nil
        let read = try JSONDecoder().decode(CameraLayoutRegion.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(read.placement == nil && read.layout == .hidden)
    }

    @Test func settingNoPlacementHandsItBack() {
        var t = timeline()
        let id = UUID()
        _ = Commands.PlaceCamera(id: id, at: time(10), placement: left).apply(to: &t)
        #expect(Commands.SetCameraPlacement(id: id, placement: nil).apply(to: &t))
        #expect(t.cameraPlacement(at: time(30)) == .steady(nil))
    }
}
