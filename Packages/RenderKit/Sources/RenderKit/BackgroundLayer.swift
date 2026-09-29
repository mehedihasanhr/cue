import CoreGraphics
import Foundation
import TimelineKit

/// One stop in a gradient.
public struct GradientStop: Equatable, Sendable {
    public var color: ColorValue
    /// 0 at the start of the sweep, 1 at the end.
    public var location: Double

    public init(color: ColorValue, location: Double) {
        self.color = color
        self.location = location
    }
}

/// A background with nothing left to look up.
///
/// The document stores a *choice* — including, for a wallpaper, a name that means
/// nothing without a catalogue. The renderer must not do that lookup: `SceneDescriptor`
/// is the thing the preview and the export are compared by, and a descriptor that still
/// needed resolving could describe two different pictures on two different days.
public enum BackgroundLayer: Equatable, Sendable {
    case color(ColorValue)
    /// Any number of stops. A two-stop model gradient is the ordinary case.
    case gradient(stops: [GradientStop], angle: Double)
    /// Absolute, resolved, and openable by the time it gets here.
    case image(url: URL)
    /// An id nothing could resolve — a wallpaper that is gone, or a resolver nobody
    /// supplied. Drawn as something visibly wrong rather than silently as black.
    case missing

    public static let fallbackColor = ColorValue(r: 0.08, g: 0.09, b: 0.12)
}

/// How a stored background becomes a drawable one.
///
/// RenderKit declares the need and the app satisfies it, so the compositor links no
/// wallpaper catalogue, no AppKit and no open panel.
public protocol BackgroundResolving: Sendable {
    /// - Parameter packageURL: the project, for backgrounds stored relative to it.
    func layer(for background: FrameStyle.Background, packageURL: URL?) -> BackgroundLayer
}

/// Everything the model can describe on its own, and nothing else.
///
/// A `.wallpaper` id resolves to `.missing` on purpose: forgetting to inject the real
/// resolver then produces a frame that is visibly wrong and a test that fails, rather
/// than an export that quietly differs from the preview.
public struct DefaultBackgroundResolver: BackgroundResolving, Sendable {
    public init() {}

    public func layer(for background: FrameStyle.Background, packageURL: URL?) -> BackgroundLayer {
        switch background {
        case .color(let color):
            return .color(color)
        case .gradient(let from, let to, let angle):
            return .gradient(stops: [GradientStop(color: from, location: 0),
                                     GradientStop(color: to, location: 1)],
                             angle: angle)
        case .image(let path):
            return .image(url: Self.url(forPath: path, packageURL: packageURL))
        case .wallpaper:
            return .missing
        }
    }

    /// A stored image path, which is package-relative by contract but was absolute in
    /// projects written before that was enforced.
    public static func url(forPath path: String, packageURL: URL?) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let packageURL else { return URL(fileURLWithPath: path) }
        return packageURL.appendingPathComponent(path)
    }
}
