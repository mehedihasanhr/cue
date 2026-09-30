import CoreGraphics
import Foundation
import TimelineKit

/// The phone or tablet drawn round the picture.
///
/// Like `ChromeLayer`, this says *what* to draw and not where: every rectangle of the
/// handset is worked out from the picture's edge (`SceneDescriptor.deviceGeometry`), so it
/// follows the picture wherever the camera takes it and can never disagree with it. The
/// orientation is resolved here rather than left as "automatic", so the renderer has
/// nothing to decide.
public struct DeviceLayer: Equatable, Sendable {
    public enum Model: Sendable, Equatable {
        case iPhone, iPad
    }

    public var model: Model
    public var finish: WindowChrome.Finish
    /// Lying on its side.
    public var isLandscape: Bool
    /// The pill at the top of a phone's screen, or the dot in a tablet's bezel.
    public var showsCamera: Bool

    public init(model: Model, finish: WindowChrome.Finish = .black,
                isLandscape: Bool = false, showsCamera: Bool = true) {
        self.model = model
        self.finish = finish
        self.isLandscape = isLandscape
        self.showsCamera = showsCamera
    }

    /// The layer a style asks for, held the way the picture of `size` needs it — or `nil`
    /// for a style whose frame is a window or nothing.
    public init?(_ chrome: WindowChrome, pictureSize size: CGSize) {
        let model: Model
        switch chrome.kind {
        case .iPhone: model = .iPhone
        case .iPad: model = .iPad
        case .none, .window, .browser: return nil
        }
        self.init(model: model, finish: chrome.finish,
                  isLandscape: chrome.orientation.isLandscape(width: size.width, height: size.height),
                  showsCamera: chrome.showsCamera)
    }
}

/// Where each part of a handset goes, for a picture at a given place.
///
/// Every measurement is a fraction of the *screen's* shorter side, so the same device
/// comes out at 720p and at 4K and grows with a zoom as one piece. The proportions are
/// near enough the real things' to read as them at a glance — a phone's screen a little
/// over twice as tall as it is wide with deep corners and a thin bezel, a tablet's close
/// to four by three with a wider bezel and gentle corners — without copying anybody's
/// drawing of either.
///
/// The picture is fitted *inside* the screen and keeps its own shape: a recording the
/// shape of the screen fills it, and one that is not leaves black above and below or
/// either side, the colour of a screen showing nothing, as a real device letterboxes a
/// video. Nothing is stretched and nothing is cut off.
public struct DeviceGeometry: Equatable, Sendable {
    /// The whole handset: the metal rim and everything inside it.
    public let body: CGRect
    public let bodyRadius: Double
    /// How wide the rim is, inside `body`.
    public let rim: Double
    /// The lit glass the picture is fitted into.
    public let screen: CGRect
    public let screenRadius: Double
    /// The camera: a pill across the top of a phone's screen, or a dot in a tablet's
    /// bezel. `nil` when it is hidden. Its radius is half its shorter side.
    public let camera: CGRect?
    /// Whether the camera is a cut-out in the screen (a phone's) rather than a lens in the
    /// bezel (a tablet's), which is drawn with a glint.
    public let cameraIsInScreen: Bool

    /// The shape of each device's screen, width over height, held upright.
    static func screenAspect(_ model: DeviceLayer.Model) -> Double {
        switch model {
        case .iPhone: 1_179.0 / 2_556.0
        case .iPad: 1_668.0 / 2_388.0
        }
    }

    /// How deeply the screen's corners are rounded, over its shorter side.
    static func screenRadiusFraction(_ model: DeviceLayer.Model) -> Double {
        switch model {
        case .iPhone: 0.14
        case .iPad: 0.035
        }
    }

    /// The black border between the screen and the rim, rim included, over the screen's
    /// shorter side.
    static func bezelFraction(_ model: DeviceLayer.Model) -> Double {
        switch model {
        case .iPhone: 0.05
        case .iPad: 0.055
        }
    }

    /// The rim of coloured metal round the outside, over the screen's shorter side.
    static func rimFraction(_ model: DeviceLayer.Model) -> Double {
        switch model {
        case .iPhone: 0.014
        case .iPad: 0.009
        }
    }

    /// The handset for a picture at `picture`, the picture centred on its screen.
    public init(_ layer: DeviceLayer, around picture: CGRect) {
        let upright = Self.screenAspect(layer.model)
        let aspect = layer.isLandscape ? 1 / upright : upright
        // The smallest screen of the device's shape that holds the whole picture.
        var size = CGSize(width: picture.width, height: picture.height)
        if picture.height > 0, picture.width / picture.height > aspect {
            size.height = picture.width / aspect
        } else {
            size.width = picture.height * aspect
        }
        let screen = CGRect(x: picture.midX - size.width / 2, y: picture.midY - size.height / 2,
                            width: size.width, height: size.height)
        let shorter = min(size.width, size.height)
        let bezel = shorter * Self.bezelFraction(layer.model)
        self.screen = screen
        screenRadius = shorter * Self.screenRadiusFraction(layer.model)
        body = screen.insetBy(dx: -bezel, dy: -bezel)
        // Concentric with the screen's corners, so the bezel is the same width all round.
        bodyRadius = screenRadius + bezel
        rim = shorter * Self.rimFraction(layer.model)

        cameraIsInScreen = layer.model == .iPhone
        guard layer.showsCamera else {
            camera = nil
            return
        }
        switch layer.model {
        case .iPhone:
            // The pill, a little in from the screen's top edge — or its left one, lying down.
            let length = shorter * 0.32, thickness = shorter * 0.094, margin = shorter * 0.03
            camera = layer.isLandscape
                ? CGRect(x: screen.minX + margin, y: screen.midY - length / 2, width: thickness, height: length)
                : CGRect(x: screen.midX - length / 2, y: screen.maxY - margin - thickness,
                         width: length, height: thickness)
        case .iPad:
            // A lens in the middle of the black glass along the top, whichever way up the
            // tablet is held: that is where anybody looking at one expects it.
            let diameter = shorter * 0.014
            let middle = (bezel - rim) / 2
            camera = CGRect(x: screen.midX - diameter / 2, y: screen.maxY + middle - diameter / 2,
                            width: diameter, height: diameter)
        }
    }

    /// The size of the whole handset round a picture of `size` — what the framing fits
    /// into the padding. Linear in `size`, which is what lets the framing solve for the
    /// picture's scale with one division.
    public static func bodySize(_ layer: DeviceLayer, picture size: CGSize) -> CGSize {
        DeviceGeometry(layer, around: CGRect(origin: .zero, size: size)).body.size
    }
}

public extension SceneDescriptor {
    /// Where the handset is drawn this frame, in output pixels with Core Image's origin, or
    /// `nil` when there is none.
    ///
    /// Round the picture's edge, like the window's bar sits on it: grown and moved with the
    /// picture when the whole frame zooms, and standing still round the hole the padding
    /// left while only the contents magnify inside it.
    var deviceGeometry: DeviceGeometry? {
        guard let device, pictureEdge.width > 1, pictureEdge.height > 1 else { return nil }
        return DeviceGeometry(device, around: pictureEdge)
    }

    /// The radius of what casts the shadow: the handset's corners when there is one, the
    /// picture's otherwise.
    var shadowCornerRadius: Double {
        deviceGeometry?.bodyRadius ?? cornerRadius
    }
}
