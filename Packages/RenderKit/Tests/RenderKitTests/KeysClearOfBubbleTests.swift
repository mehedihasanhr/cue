import CoreGraphics
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The keys overlay never sits on the camera bubble.
struct KeysClearOfBubbleTests {
    private let output = CGSize(width: 1_920, height: 1_080)

    @Test func keysInTheBubblesCornerMoveClearOfIt() {
        // A bubble in the bottom-right corner, a fifth of the frame's height.
        let bubble = SceneRenderer.outputRect(of: CGRect(x: 0.78, y: 0.7, width: 0.18, height: 0.26), in: output)
        let layer = KeyLayer(caps: ["⌘", "K"], position: .bottomRight)
        let plate = CGSize(width: 260, height: 90)
        let unobstructed = KeycapArtwork.frame(for: plate, layer: layer, outputSize: output, clearing: [])
        #expect(unobstructed.intersects(bubble), "the case this is about")
        let placed = KeycapArtwork.frame(for: plate, layer: layer, outputSize: output, clearing: [bubble])
        #expect(!placed.intersects(bubble))
        #expect(CGRect(origin: .zero, size: output).contains(placed), "and still in shot")
    }

    @Test func aBubbleElsewhereLeavesTheKeysWhereTheyWere() {
        let bubble = SceneRenderer.outputRect(of: CGRect(x: 0.04, y: 0.04, width: 0.18, height: 0.26), in: output)
        let layer = KeyLayer(caps: ["⌘", "K"], position: .bottomRight)
        let plate = CGSize(width: 260, height: 90)
        #expect(KeycapArtwork.frame(for: plate, layer: layer, outputSize: output, clearing: [bubble])
                == KeycapArtwork.frame(for: plate, layer: layer, outputSize: output, clearing: []))
    }

    @Test func theBubblesRectangleIsTurnedTheRightWayUp() {
        let rect = SceneRenderer.outputRect(of: CGRect(x: 0, y: 0, width: 0.5, height: 0.25), in: output)
        #expect(rect == CGRect(x: 0, y: 810, width: 960, height: 270), "top-left in the model is top-left on the frame")
    }
}
