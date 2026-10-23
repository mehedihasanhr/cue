import AppKit

/// The result of a capture: a bitmap at native (Retina) resolution plus the
/// information needed to map it back to points.
struct CapturedImage {
    let cgImage: CGImage
    /// Pixels per point of the source display (2 on Retina).
    let scale: CGFloat
    let displayID: CGDirectDisplayID
    let capturedAt: Date

    var pixelSize: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }

    var pointSize: CGSize {
        CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
    }

    /// An `NSImage` sized in points, so it draws 1:1 on a display with the same scale.
    var nsImage: NSImage {
        NSImage(cgImage: cgImage, size: pointSize)
    }

    var dimensionsDescription: String {
        let px = pixelSize
        let pt = pointSize
        return "\(Int(px.width)) × \(Int(px.height)) px · \(Int(pt.width)) × \(Int(pt.height)) pt · @\(Int(scale))x"
    }

    /// Converts a rect in this image's point space (origin bottom-left, y up — i.e. the
    /// coordinate space of the screen it was captured from) to a pixel rect (origin top-left).
    func pixelRect(forPoints rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * scale,
            y: (pointSize.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        .integral
        .intersection(CGRect(origin: .zero, size: pixelSize))
    }

    /// The sub-image covering `rect` (point space, y up), or `nil` if it lies outside the image.
    func cropped(toPoints rect: CGRect) -> CapturedImage? {
        let pixels = pixelRect(forPoints: rect)
        guard !pixels.isEmpty, let cropped = cgImage.cropping(to: pixels) else { return nil }
        return CapturedImage(cgImage: cropped, scale: scale, displayID: displayID, capturedAt: capturedAt)
    }
}
