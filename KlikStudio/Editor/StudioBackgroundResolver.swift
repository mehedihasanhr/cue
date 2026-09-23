import BackgroundKit
import Foundation
import RenderKit
import TimelineKit

/// The app's answer to "what is this background, actually?".
///
/// RenderKit asks; BackgroundKit knows. Keeping the two apart is what lets the
/// compositor link no wallpaper catalogue and no open panel — and what will let the
/// exporter resolve exactly what the preview resolved, since this holds no state and
/// consults nothing that changes between the two.
struct StudioBackgroundResolver: BackgroundResolving {
    private let base = DefaultBackgroundResolver()
    private let wallpapers: WallpaperResolver

    init(wallpapers: WallpaperResolver = .shared) {
        self.wallpapers = wallpapers
    }

    func layer(for background: FrameStyle.Background, packageURL: URL?) -> BackgroundLayer {
        guard case .wallpaper(let raw) = background else {
            return base.layer(for: background, packageURL: packageURL)
        }
        guard let id = WallpaperID(rawValue: raw),
              let source = wallpapers.source(for: id) else { return .missing }

        switch source {
        case .procedural(let preset):
            return .gradient(stops: Self.stops(of: preset), angle: 0.25)
        case .file(let url):
            return .image(url: url)
        }
    }

    /// A catalogue gradient's colours, spread evenly from one end to the other.
    static func stops(of preset: GradientPreset) -> [GradientStop] {
        let colors = preset.colors
        guard colors.count > 1 else {
            return colors.map { GradientStop(color: $0.colorValue, location: 0) }
        }
        return colors.enumerated().map { index, colour in
            GradientStop(color: colour.colorValue, location: Double(index) / Double(colors.count - 1))
        }
    }
}

nonisolated extension RGBA {
    /// The same colour, in the type the document stores.
    ///
    /// Two colour types rather than one because they belong to different layers: `RGBA`
    /// knows about `NSColor` and `ColorValue` is deliberately free of AppKit so a
    /// timeline can be decoded anywhere.
    var colorValue: ColorValue { ColorValue(r: r, g: g, b: b, a: a) }
}

nonisolated extension ColorValue {
    var rgba: RGBA { RGBA(r: r, g: g, b: b, a: a) }
}
