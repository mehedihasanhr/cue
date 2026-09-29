import CoreGraphics
import Foundation
import TimelineKit

extension SceneBuilder {
    /// The border for a frame, or `nil` when the style has none.
    ///
    /// Measured against the shorter side of the *video frame* rather than of the output,
    /// like the corner radius — the two are drawn together at the picture's edge, and a
    /// border that was thick against a 9:16 frame and thin against a 16:9 one would make
    /// the same setting mean two things. Held to `FrameStyle.borderWidthRange`, because a
    /// project is a file and a file can ask for a border wider than the picture.
    func borderLayer(_ style: FrameStyle, frame: CGSize) -> BorderLayer? {
        let width = min(max(style.borderWidth, FrameStyle.borderWidthRange.lowerBound),
                        FrameStyle.borderWidthRange.upperBound)
        guard width > 0, style.borderColor.a > 0 else { return nil }
        let pixels = Double(min(frame.width, frame.height)) * width
        guard pixels > 0 else { return nil }
        return BorderLayer(width: pixels, color: style.borderColor)
    }
}
