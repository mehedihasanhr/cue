/// The gradients both editors offer.
///
/// Generated rather than shipped as artwork: a gradient costs no bytes in the app, and
/// it is resolution-independent, so a 4K export gets a real 4K background instead of an
/// upscaled thumbnail.
public enum GradientPreset: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case ocean, sunset, aurora, candy, peach, lime, lavender, flame, mint, rose, sky, dusk,
         forest, gold, berry, steel, midnight, graphite, mono, snow

    public var id: String { rawValue }

    /// Two or three stops, top-leading to bottom-trailing.
    public var colors: [RGBA] {
        switch self {
        case .ocean: [RGBA(r: 0.27, g: 0.65, b: 1), RGBA(r: 0.36, g: 0.32, b: 0.9)]
        case .sunset: [RGBA(r: 1, g: 0.55, b: 0.35), RGBA(r: 0.98, g: 0.29, b: 0.53)]
        case .aurora: [RGBA(r: 0.2, g: 0.85, b: 0.7), RGBA(r: 0.3, g: 0.45, b: 0.95)]
        case .candy: [RGBA(r: 1, g: 0.6, b: 0.85), RGBA(r: 0.65, g: 0.5, b: 1)]
        case .peach: [RGBA(r: 1, g: 0.8, b: 0.6), RGBA(r: 1, g: 0.5, b: 0.55)]
        case .lime: [RGBA(r: 0.75, g: 0.95, b: 0.45), RGBA(r: 0.2, g: 0.75, b: 0.55)]
        case .lavender: [RGBA(r: 0.85, g: 0.8, b: 1), RGBA(r: 0.55, g: 0.45, b: 0.95)]
        case .flame: [RGBA(r: 1, g: 0.85, b: 0.3), RGBA(r: 1, g: 0.35, b: 0.2), RGBA(r: 0.6, g: 0.05, b: 0.3)]
        case .mint: [RGBA(r: 0.7, g: 1, b: 0.9), RGBA(r: 0.25, g: 0.8, b: 0.75)]
        case .rose: [RGBA(r: 1, g: 0.75, b: 0.8), RGBA(r: 0.9, g: 0.3, b: 0.5)]
        case .sky: [RGBA(r: 0.75, g: 0.9, b: 1), RGBA(r: 0.3, g: 0.6, b: 1)]
        case .dusk: [RGBA(r: 0.98, g: 0.6, b: 0.4), RGBA(r: 0.55, g: 0.3, b: 0.65), RGBA(r: 0.15, g: 0.15, b: 0.4)]
        case .forest: [RGBA(r: 0.35, g: 0.7, b: 0.45), RGBA(r: 0.05, g: 0.3, b: 0.25)]
        case .gold: [RGBA(r: 1, g: 0.9, b: 0.55), RGBA(r: 0.85, g: 0.6, b: 0.15)]
        case .berry: [RGBA(r: 0.8, g: 0.3, b: 0.7), RGBA(r: 0.3, g: 0.1, b: 0.5)]
        case .steel: [RGBA(r: 0.75, g: 0.8, b: 0.88), RGBA(r: 0.35, g: 0.42, b: 0.55)]
        case .midnight: [RGBA(r: 0.13, g: 0.15, b: 0.3), RGBA(r: 0.05, g: 0.05, b: 0.12)]
        case .graphite: [RGBA(r: 0.35, g: 0.36, b: 0.4), RGBA(r: 0.12, g: 0.12, b: 0.14)]
        case .mono: [RGBA(r: 0.2, g: 0.2, b: 0.22), RGBA(r: 0.02, g: 0.02, b: 0.03)]
        case .snow: [RGBA(r: 1, g: 1, b: 1), RGBA(r: 0.85, g: 0.88, b: 0.93)]
        }
    }
}

public extension GradientPreset {
    /// Sentence case, for a tooltip or a picker row.
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}
