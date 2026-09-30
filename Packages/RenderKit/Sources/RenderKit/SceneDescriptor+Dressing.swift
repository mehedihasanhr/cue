import CoreGraphics
import Foundation
import TimelineKit

/// The window drawn round the picture: a bar across its top, with three dots in the
/// corner and, for a browser, an address field.
///
/// The builder has already made room for it — the picture is a little smaller so picture
/// and bar together fit where the picture alone used to — so all this says is what to
/// draw in that room. The bar's rectangle is not stored: it follows the picture, which
/// the camera moves, so it is asked of the descriptor (`chromeBarFrame`) rather than kept
/// as a second copy of the picture's position that could disagree with it.
public struct ChromeLayer: Equatable, Sendable {
    public var kind: WindowChrome.Kind
    public var appearance: WindowChrome.Appearance
    /// In output pixels, before the camera moves — like `SceneDescriptor.cornerRadius`.
    public var barHeight: Double

    public init(kind: WindowChrome.Kind, appearance: WindowChrome.Appearance, barHeight: Double) {
        self.kind = kind
        self.appearance = appearance
        self.barHeight = barHeight
    }
}

/// How the camera moved while this frame's shutter was open, for softening the picture
/// along it.
///
/// Worked out by the builder from where the camera is a moment before and a moment after
/// this frame — never from the frame drawn before — so it is the same whether the frame is
/// reached by playing or by scrubbing.
public struct CameraMotionLayer: Equatable, Sendable {
    /// How far the middle of the picture travels, in output pixels, Core Image's way up.
    public var travel: CGVector
    /// How much the picture grows, as a fraction of its own size: positive pushing in,
    /// negative pulling out.
    public var growth: Double
    /// The point it grows about, in output pixels, Core Image's way up.
    public var center: CGPoint

    public init(travel: CGVector, growth: Double, center: CGPoint) {
        self.travel = travel
        self.growth = growth
        self.center = center
    }

    func scaled(by factor: Double) -> CameraMotionLayer {
        CameraMotionLayer(travel: CGVector(dx: travel.dx * factor, dy: travel.dy * factor),
                          growth: growth,
                          center: CGPoint(x: center.x * factor, y: center.y * factor))
    }
}

public extension SceneDescriptor {
    /// The edge of the picture as it is drawn: the rectangle its corners are rounded on.
    ///
    /// When the whole frame zooms that is the picture grown and moved; when only its
    /// contents zoom it is the hole the padding left, which never moves. The same choice
    /// the border makes, and for the same reason: the frame is where the styling lives.
    var pictureEdge: CGRect {
        zoomsWholeFrame ? transformedVideoFrame : videoFrame
    }

    /// Where the window's bar is drawn, in output pixels with Core Image's origin, or
    /// `nil` when there is no window.
    ///
    /// Across the top of the picture's edge and exactly as wide. It grows with the camera
    /// when the whole frame zooms, like the corners and the shadow do, and otherwise stays
    /// put above the hole while the contents magnify beneath it.
    var chromeBarFrame: CGRect? {
        guard let chrome, chrome.kind != .none, chrome.barHeight > 0 else { return nil }
        let edge = pictureEdge
        let grown = zoomsWholeFrame && videoFrame.width > 0 ? edge.width / videoFrame.width : 1
        return CGRect(x: edge.minX, y: edge.maxY, width: edge.width, height: chrome.barHeight * grown)
    }

    /// What casts the shadow: the picture, and the bar above it when there is one — or the
    /// whole handset, when the picture is on a device.
    ///
    /// Also the plane a perspective turns (`perspectiveProjection`), so a phone is tilted
    /// as one piece, rim and all, and the overlay's handles are mapped through it too.
    var shadowCaster: CGRect {
        if let device = deviceGeometry { return device.body }
        let picture = transformedVideoFrame.intersection(visibleVideoFrame)
        guard let bar = chromeBarFrame else { return picture }
        let shown = bar.intersection(CGRect(origin: .zero, size: outputSize))
        guard !shown.isNull, !picture.isNull else { return picture }
        return picture.union(shown)
    }
}
