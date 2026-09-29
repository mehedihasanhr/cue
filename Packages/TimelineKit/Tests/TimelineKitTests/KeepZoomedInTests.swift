import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Staying zoomed in across a gap between two zooms, and travelling to the second.
struct KeepZoomedInTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    private func zoom(start: Double, duration: Double, scale: Double = 2) -> ZoomRegion {
        ZoomRegion(start: time(start), duration: time(duration), scale: scale,
                   center: CGPoint(x: 0.5, y: 0.5), easing: .easeInOut, transition: time(0.5),
                   followsCursor: false)
    }

    @Test func aGapWithinTheSettingStaysZoomedIn() throws {
        let zooms = [zoom(start: 2, duration: 4), zoom(start: 9, duration: 4, scale: 3)]
        #expect(ZoomLane.glides(in: zooms).isEmpty, "three seconds is too far to glide on its own")
        let glide = try #require(ZoomLane.glides(in: zooms, keepingZoomedFor: 4).first)
        #expect(glide.isKeptZoomedIn)
        #expect(glide.start == time(5.5), "takes over where the first would have started pulling back")
        #expect(glide.moveStart == time(8.5), "sets off as late as a glide between touching zooms would")
        #expect(glide.end == time(9.5), "arrives where the second would have finished pushing in")
        // Held on the first shot through the gap, never out to the whole picture.
        for t in stride(from: 5.5, through: 8.5, by: 0.25) {
            #expect(glide.scale(at: time(t)) == 2)
        }
        #expect(glide.scale(at: time(9.5)) == 3)
        #expect(glide.scale(at: time(9)) > 2 && glide.scale(at: time(9)) < 3)
    }

    @Test func aGapBeyondTheSettingStillPullsBack() {
        let zooms = [zoom(start: 2, duration: 4), zoom(start: 11, duration: 4)]
        #expect(ZoomLane.glides(in: zooms, keepingZoomedFor: 4).isEmpty)
    }

    @Test func closeZoomsGlideAsBefore() throws {
        let glide = try #require(ZoomLane.glides(in: [zoom(start: 2, duration: 4), zoom(start: 6, duration: 4)],
                                                 keepingZoomedFor: 4).first)
        #expect(!glide.isKeptZoomedIn)
        #expect(glide.moveStart == glide.start)
    }

    @Test func onlyWhileGliding() {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.zooms = [zoom(start: 2, duration: 4), zoom(start: 9, duration: 4)]
        timeline.camera.keepsZoomedInFor = 4
        timeline.camera.glidesBetweenZooms = true
        #expect(timeline.zoomGlide(at: time(7)) != nil)
        timeline.camera.glidesBetweenZooms = false
        #expect(timeline.zoomGlide(at: time(7)) == nil)
        timeline.camera.glidesBetweenZooms = true
        timeline.camera.keepsZoomedInFor = 0
        #expect(timeline.zoomGlide(at: time(7)) == nil)
    }

    @Test func oldProjectsAndBadValues() throws {
        let old = try JSONDecoder().decode(CameraStyle.self, from: Data(#"{"steadiness":0.7,"glidesBetweenZooms":true}"#.utf8))
        #expect(old.keepsZoomedInFor == 0)
        let bad = try JSONDecoder().decode(CameraStyle.self, from: Data(#"{"keepsZoomedInFor":"soon"}"#.utf8))
        #expect(bad.keepsZoomedInFor == 0)
        #expect(CameraStyle(keepsZoomedInFor: -3).sanitised.keepsZoomedInFor == 0)
        #expect(CameraStyle(keepsZoomedInFor: 500).sanitised.keepsZoomedInFor == 30)
        let saved = try JSONDecoder().decode(CameraStyle.self, from: JSONEncoder().encode(CameraStyle(keepsZoomedInFor: 4)))
        #expect(saved.keepsZoomedInFor == 4)
    }
}
