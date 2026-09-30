import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TimelineKit

extension SceneRenderer {
    /// The picture with its corners rounded on its edge.
    ///
    /// On `SceneDescriptor.pictureEdge` rather than on the picture's own extent, and that
    /// is a fix. When only the contents zoom, the picture is magnified past the hole the
    /// padding left and then cut down to it; rounding the magnified picture put the curves
    /// out beyond the hole, where they were cut away, so the corners went square for as
    /// long as any zoom was in — the one setting whose whole promise is that the corners
    /// never move.
    ///
    /// With a window round the picture only the bottom corners are rounded: the top ones
    /// meet the bar, which takes the rounding instead.
    func roundedPicture(_ image: CIImage, in scene: SceneDescriptor) -> CIImage {
        // On a device the screen is the edge, and its corners are the device's.
        if let device = scene.deviceGeometry {
            return deviceScreenPicture(image, device: device)
        }
        let edge = scene.pictureEdge
        guard scene.cornerRadius > 0, scene.videoFrame.width > 0, edge.width > 1, edge.height > 1 else {
            return image
        }
        let radius = min(scene.cornerRadius * (edge.width / scene.videoFrame.width), min(edge.width, edge.height) / 2)
        guard radius > 0.5 else { return image }

        var mask = Self.roundedRectangle(edge, radius: radius, color: .white)
        if scene.chromeBarFrame != nil {
            // The top half square: a plain rectangle laid over the rounded one.
            let top = CGRect(x: edge.minX, y: edge.midY, width: edge.width, height: edge.height / 2)
            mask = CIImage(color: .white).cropped(to: top).composited(over: mask)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.maskImage = mask
        blend.backgroundImage = CIImage(color: .clear).cropped(to: image.extent)
        return blend.outputImage ?? image
    }

    /// The window's bar, laid over the top of the picture layer — or the device the picture
    /// is on, laid round it. See `deviced(_:in:)`.
    func chromed(_ video: CIImage, in scene: SceneDescriptor) -> CIImage {
        if scene.device != nil { return deviced(video, in: scene) }
        guard let chrome = scene.chrome, let bar = scene.chromeBarFrame,
              bar.width > 1, bar.height > 0.5 else { return video }
        let output = CGRect(origin: .zero, size: scene.outputSize)
        let edge = scene.pictureEdge
        let radius = scene.videoFrame.width > 0
            ? min(scene.cornerRadius * (edge.width / scene.videoFrame.width), bar.width / 2)
            : 0
        return chromeBar(chrome, in: bar, cornerRadius: radius)
            .cropped(to: output)
            .composited(over: video)
    }

    /// The bar itself, drawn from rounded rectangles so it is sharp at any size.
    ///
    /// Every measurement is a fraction of the bar's height, so the same bar comes out at
    /// 720p and at 4K, and grows with a zoom as one piece. The dots are the three a window
    /// has in its corner, in the colours everyone reads as close, minimise and zoom —
    /// drawn, not copied from anybody's artwork.
    func chromeBar(_ chrome: ChromeLayer, in bar: CGRect, cornerRadius: Double) -> CIImage {
        let isDark = chrome.appearance == .dark
        let palette = ChromePalette(isDark: isDark)

        // The bar with its top corners rounded to match the picture's, and its bottom
        // corners square where it meets the picture: a rounded rectangle reaching down
        // past the bar by one radius, cut back to the bar.
        let radius = max(0, min(cornerRadius, bar.height, bar.width / 2))
        let reach = CGRect(x: bar.minX, y: bar.minY - radius, width: bar.width, height: bar.height + radius)
        var image = Self.roundedRectangle(reach, radius: radius, color: palette.bar).cropped(to: bar)

        // A hairline where the bar meets the picture, as a real title bar has.
        let line = max(1, bar.height * 0.02)
        image = CIImage(color: palette.hairline)
            .cropped(to: CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: line))
            .composited(over: image)

        // The dots are sized off the bar a window would have, so a browser's taller bar
        // has the same dots in it rather than bigger ones.
        let unit = chrome.kind == .browser ? bar.height * (Self.windowBarFraction / Self.browserBarFraction) : bar.height
        let diameter = unit * 0.27
        let gap = diameter * 0.68
        var x = bar.minX + max(diameter * 1.1, radius * 0.6)
        let y = bar.midY - diameter / 2
        for colour in palette.dots {
            image = Self.roundedRectangle(CGRect(x: x, y: y, width: diameter, height: diameter),
                                          radius: diameter / 2, color: colour)
                .composited(over: image)
            x += diameter + gap
        }

        if chrome.kind == .browser {
            // The address field: a rounded field in the middle of the bar, with a short
            // rule standing in for an address. No words: whatever it said would be
            // somebody's site, and the video is about the picture under it.
            let leftOfField = x + gap
            let height = bar.height * 0.54
            let width = min(bar.width * 0.46, max(0, (bar.midX - leftOfField) * 2))
            if width > height * 2 {
                let field = CGRect(x: bar.midX - width / 2, y: bar.midY - height / 2, width: width, height: height)
                image = Self.roundedRectangle(field, radius: height * 0.3, color: palette.field)
                    .composited(over: image)
                let textHeight = height * 0.2
                let text = CGRect(x: field.midX - width * 0.16, y: field.midY - textHeight / 2,
                                  width: width * 0.32, height: textHeight)
                image = Self.roundedRectangle(text, radius: textHeight / 2, color: palette.address)
                    .composited(over: image)
            }
        }
        return image.cropped(to: bar)
    }

    /// The bar's height as a fraction of the shorter side of the picture, for each kind.
    ///
    /// Near what a real title bar is on a recorded screen — a little more, because a
    /// video is watched smaller than the screen it was made on. The builder makes room for
    /// exactly this much; see `SceneBuilder.chromeLayer`.
    static let windowBarFraction = 0.045
    static let browserBarFraction = 0.075

    static func barFraction(for kind: WindowChrome.Kind) -> Double {
        switch kind {
        // A device goes round the picture rather than above it: see `DeviceGeometry`.
        case .none, .iPhone, .iPad: 0
        case .window: windowBarFraction
        case .browser: browserBarFraction
        }
    }
}

/// The colours of the bar in each appearance: a light grey or a near-black, a hairline a
/// step darker, a field a step towards the middle, and the three dots.
private struct ChromePalette {
    let bar: CIColor
    let hairline: CIColor
    let field: CIColor
    let address: CIColor
    let dots: [CIColor]

    init(isDark: Bool) {
        bar = isDark ? CIColor(red: 0.17, green: 0.17, blue: 0.19) : CIColor(red: 0.93, green: 0.93, blue: 0.94)
        hairline = isDark ? CIColor(red: 0.07, green: 0.07, blue: 0.08) : CIColor(red: 0.8, green: 0.8, blue: 0.82)
        field = isDark ? CIColor(red: 0.26, green: 0.26, blue: 0.29) : CIColor(red: 0.85, green: 0.85, blue: 0.87)
        address = isDark ? CIColor(red: 0.5, green: 0.5, blue: 0.53) : CIColor(red: 0.62, green: 0.62, blue: 0.65)
        dots = [
            CIColor(red: 1.0, green: 0.37, blue: 0.34),
            CIColor(red: 1.0, green: 0.74, blue: 0.18),
            CIColor(red: 0.16, green: 0.79, blue: 0.25),
        ]
    }
}
