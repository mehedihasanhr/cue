import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// What the camera bubble is before anybody touches it, and what a project written without
/// one reads as.
struct WebcamSettingsTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// The default is off, and that is the whole of the promise that an older recording
    /// renders as it always did: `SceneBuilder` describes no bubble when this is false, so
    /// the frame it builds has no webcam layer in it to draw.
    @Test func aFreshTimelineHasNoBubble() {
        #expect(!Timeline(sourceDuration: time(10)).webcam.isEnabled)
    }

    /// A project saved before the bubble could be drawn opens with it off and everything
    /// else intact.
    ///
    /// Written as JSON without the key rather than by encoding a `Timeline` and deleting it,
    /// because that is what is actually on disk in those files — and because an encoder that
    /// started writing the field would make the delete-it version pass for the wrong reason.
    @Test func aProjectWrittenBeforeTheBubbleDecodesWithoutOne() throws {
        let json = """
        {
          "formatVersion": 1,
          "sourceDuration": { "value": 6000, "timescale": 600, "flags": 1, "epoch": 0 },
          "clips": [],
          "zooms": [],
          "blurs": [],
          "annotations": [],
          "captions": [],
          "audio": []
        }
        """
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))

        #expect(!timeline.webcam.isEnabled)
        #expect(timeline.webcam.corner == .bottomRight)
        #expect(timeline.sourceDuration == time(10), "and the rest of the file still reads")
        #expect(timeline.clips.count == 1, "an empty clip list still means one clip of the whole take")
    }

    /// A webcam field written by a newer build — or hand-edited into nonsense — costs the
    /// bubble and nothing else. `Timeline` decodes one field at a time for exactly this, and
    /// losing a bubble must not lose every cut in the project.
    @Test func anUnreadableWebcamFieldLosesOnlyTheBubble() throws {
        let json = """
        {
          "sourceDuration": { "value": 6000, "timescale": 600, "flags": 1, "epoch": 0 },
          "webcam": "not an object at all",
          "captionStyle": { "isVisible": true, "fontSize": 0.04, "position": "top",
                            "color": { "r": 1, "g": 1, "b": 1, "a": 1 },
                            "backgroundOpacity": 0.5, "margin": 0.06 }
        }
        """
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))

        #expect(!timeline.webcam.isEnabled)
        #expect(timeline.captionStyle.position == .top, "the field beside it survived")
    }

    /// Round-trips, so a placed bubble is still where it was put after a save and a reopen.
    @Test func aPlacedBubbleSurvivesBeingWrittenAndReadBack() throws {
        var timeline = Timeline(sourceDuration: time(10))
        timeline.webcam.isEnabled = true
        timeline.webcam.corner = .custom
        timeline.webcam.position = CGPoint(x: 0.31, y: 0.62)
        timeline.webcam.size = 0.17
        timeline.webcam.roundness = 0.4
        timeline.webcam.isMirrored = false
        timeline.webcam.reactsToZoom = false

        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(decoded.webcam == timeline.webcam)
    }
}
