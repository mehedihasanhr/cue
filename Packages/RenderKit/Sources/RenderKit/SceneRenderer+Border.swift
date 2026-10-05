import CoreGraphics
import CoreImage
import Foundation
import TimelineKit

extension SceneRenderer {
    /// How wide the border is drawn in this frame, in output pixels: the described width,
    /// grown with a frame that zooms whole, as the corner radius is. Zero for none.
    func borderWidth(in scene: SceneDescriptor) -> CGFloat {
        guard let border = scene.border, border.color.a > 0 else { return 0 }
        let frame = scene.pictureEdge
        guard frame.width > 1, frame.height > 1 else { return 0 }
        let grown = scene.frameFollowsCamera && scene.videoFrame.width > 0
            ? frame.width / scene.videoFrame.width : 1
        let width = border.width * grown
        return width > 0.25 ? width : 0
    }

    /// The border, as a ring *outside* the picture's edge.
    ///
    /// Outside rather than over the picture's outermost pixels: a border is a frame put
    /// round the work, and one laid over its edge covered the very pixels — a menu bar, a
    /// toolbar — that are often what the recording is about. The picture keeps its size
    /// and place; the ring reaches out into the padding by its width.
    ///
    /// The ring goes round whatever is framed: the picture, and the window's bar above it
    /// when there is one, so a window is bordered as one piece. Its inner edge is the
    /// framed shape's own — the corner radius it has — and its outer edge is that shape
    /// grown by the width with the radius grown by the same amount, so the two arcs are
    /// concentric and the ring is one width all the way round.
    ///
    /// Drawn against the frame the border belongs to. When the whole frame zooms that is
    /// the grown, moved one, and the width grows with it; when only the contents zoom it is
    /// the hole the padding left, which is where the picture's edge stays.
    func outlined(_ video: CIImage, in scene: SceneDescriptor) -> CIImage {
        guard scene.deviceGeometry == nil, let border = scene.border else { return video }
        let width = borderWidth(in: scene)
        guard width > 0 else { return video }

        var framed = scene.pictureEdge
        if let bar = scene.chromeBarFrame { framed = framed.union(bar) }
        let grown = scene.frameFollowsCamera && scene.videoFrame.width > 0
            ? scene.pictureEdge.width / scene.videoFrame.width : 1
        let radius = max(0, min(scene.cornerRadius * grown, min(framed.width, framed.height) / 2))

        let colour = CIColor(red: border.color.r, green: border.color.g,
                             blue: border.color.b, alpha: border.color.a)
        let outer = Self.roundedRectangle(framed.insetBy(dx: -width, dy: -width),
                                          radius: radius + width, color: colour)
        let hole = Self.roundedRectangle(framed, radius: radius, color: .white)
        // Source-out keeps the outer shape only where the hole is transparent: the ring.
        let ring = outer.applyingFilter("CISourceOutCompositing", parameters: [
            kCIInputBackgroundImageKey: hole,
        ])
        return video.composited(over: ring)
    }
}
