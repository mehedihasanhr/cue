import CoreGraphics

extension SceneRenderer {
    /// A rectangle normalised to the finished frame with a top-left origin — how
    /// annotations and the camera bubble are placed — in output pixels with Core Image's
    /// bottom-left origin.
    static func outputRect(of normalised: CGRect, in outputSize: CGSize) -> CGRect {
        CGRect(x: normalised.minX * outputSize.width,
               y: (1 - normalised.maxY) * outputSize.height,
               width: normalised.width * outputSize.width,
               height: normalised.height * outputSize.height)
    }
}
