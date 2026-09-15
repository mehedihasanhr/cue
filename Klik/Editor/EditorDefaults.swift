import Foundation

/// The tool options every new editor window starts with. Edited in Settings › Editor;
/// optionally replaced by whatever was used last when an editor closes.
struct EditorDefaults: Codable, Equatable {
    var color: RGBA = .red
    var highlightColor: RGBA = .yellow
    var strokeWidth: CGFloat = 4
    var fillMode: FillMode = .none
    var shapeKind: ShapeKind = .rectangle
    var arrowStyle: ArrowStyle = .single
    var fontSize: CGFloat = TextStyle.defaultSize
    var fontWeight: CGFloat = TextStyle.defaultWeight
    var textBackground: TextBackground = .none
    var highlighterWidth: CGFloat = 18
    var blurKind: BlurKind = .blur
    var blurIntensity: CGFloat = 12
    var counterSize: CGFloat = 30
    /// When on, an editor starts from the options the previous one was closed with.
    var rememberLastUsed = false

    static let strokeRange: ClosedRange<CGFloat> = 1...20
    static let fontSizeRange: ClosedRange<CGFloat> = 8...96
    static let highlighterRange: ClosedRange<CGFloat> = 6...40
    static let blurRange: ClosedRange<CGFloat> = 2...40
    static let counterRange: ClosedRange<CGFloat> = 16...60

    init() {}

    // Missing keys fall back to the defaults, so settings saved by an older version load.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? color
        highlightColor = try c.decodeIfPresent(RGBA.self, forKey: .highlightColor) ?? highlightColor
        strokeWidth = try c.decodeIfPresent(CGFloat.self, forKey: .strokeWidth) ?? strokeWidth
        fillMode = try c.decodeIfPresent(FillMode.self, forKey: .fillMode) ?? fillMode
        shapeKind = try c.decodeIfPresent(ShapeKind.self, forKey: .shapeKind) ?? shapeKind
        arrowStyle = try c.decodeIfPresent(ArrowStyle.self, forKey: .arrowStyle) ?? arrowStyle
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? fontSize
        fontWeight = try c.decodeIfPresent(CGFloat.self, forKey: .fontWeight) ?? fontWeight
        textBackground = try c.decodeIfPresent(TextBackground.self, forKey: .textBackground) ?? textBackground
        highlighterWidth = try c.decodeIfPresent(CGFloat.self, forKey: .highlighterWidth) ?? highlighterWidth
        blurKind = try c.decodeIfPresent(BlurKind.self, forKey: .blurKind) ?? blurKind
        blurIntensity = try c.decodeIfPresent(CGFloat.self, forKey: .blurIntensity) ?? blurIntensity
        counterSize = try c.decodeIfPresent(CGFloat.self, forKey: .counterSize) ?? counterSize
        rememberLastUsed = try c.decodeIfPresent(Bool.self, forKey: .rememberLastUsed) ?? rememberLastUsed
    }

    // MARK: Storage

    private static let key = "editor.defaults"

    static func load(from defaults: UserDefaults = .standard) -> EditorDefaults {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(EditorDefaults.self, from: data)
        else { return EditorDefaults() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
