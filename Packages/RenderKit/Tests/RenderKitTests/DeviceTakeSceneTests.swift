import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// A frame of a recording of a connected iPhone: the phone round it, and no pointer in it,
/// because there never was one.
struct DeviceTakeSceneTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// An iPhone 15's screen, as a device take's file holds it, at the phone's own 3×.
    private let builder = SceneBuilder(videoSize: CGSize(width: 1_178, height: 2_556), displayScale: 3)

    private var deviceTake: Timeline {
        Timeline(sourceDuration: time(30))
            .dressed(for: RecordedDevice(name: "Phone", family: .iPhone))
    }

    @Test func aDeviceTakeIsDrawnInItsDeviceWithNoPointer() {
        for moment in [0.0, 5, 29.9] {
            let scene = builder.descriptor(for: deviceTake, at: time(moment), cursor: CursorTrack(samples: []))
            #expect(scene.cursor == nil, "an empty track draws no pointer at \(moment)s")
            #expect(scene.device != nil, "the phone goes round the picture")
            #expect(scene.chrome == nil)
        }
    }

    /// With no track handed over at all — the renderer's other way of saying "no pointer".
    @Test func noTrackAtAllIsTheSameAsAnEmptyOne() {
        let scene = builder.descriptor(for: deviceTake, at: time(3))
        #expect(scene.cursor == nil)
    }

    /// Zooms still work on a device take — added by hand, there being nothing to suggest
    /// them from — and the picture keeps its shape inside the phone.
    @Test func aDeviceTakeKeepsItsShape() {
        let scene = builder.descriptor(for: deviceTake, at: time(3), cursor: CursorTrack(samples: []))
        let ratio = scene.videoFrame.width / scene.videoFrame.height
        #expect(abs(ratio - 1_178.0 / 2_556.0) < 0.01)
    }
}
