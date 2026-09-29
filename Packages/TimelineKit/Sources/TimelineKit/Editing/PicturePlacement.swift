import CoreGraphics

extension AnnotationItem {
    /// Where a picture goes when it is first laid on the frame, as a fraction of it.
    ///
    /// Its own shape, whatever shape the frame is: a width is chosen and the height follows
    /// from the picture's proportions and the frame's. A picture laid in the middle takes
    /// a third of the width; a logo a tenth, in the bottom right-hand corner, clear of the
    /// edge by the same distance down the side as along the bottom. However tall and thin
    /// it is, a picture is never more than four-fifths of the frame's height and a logo
    /// never more than a fifth.
    public static func pictureRect(pixelSize: CGSize, frame: CGSize, asLogo: Bool) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0, frame.width > 0, frame.height > 0 else {
            return CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        }
        let pictureShape = pixelSize.width / pixelSize.height
        let frameShape = frame.width / frame.height
        var width = asLogo ? 0.1 : 1.0 / 3
        var height = width * frameShape / pictureShape
        let tallest = asLogo ? 0.2 : 0.8
        if height > tallest {
            height = tallest
            width = height * pictureShape / frameShape
        }
        guard asLogo else {
            return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
        }
        let margin = 0.035 * min(frame.width, frame.height)
        return CGRect(x: 1 - width - margin / frame.width,
                      y: 1 - height - margin / frame.height,
                      width: width, height: height)
    }
}
