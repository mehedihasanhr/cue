import CoreMedia
import Foundation
import RecordKit

/// A key press shown in the video: a shortcut, or one of the named keys on its own.
///
/// A region like any other — it is selected, moved, trimmed, copied and deleted by the
/// code every other lane uses — and what it holds is exactly what the recorder was allowed
/// to write down: which modifiers were held and the name of the key. Nothing here can ever
/// be a letter somebody typed, because `KeyRecorder` never wrote one.
///
/// Made from the recording when a project is first opened, and editable from then on: the
/// keys are text in the inspector, so a shortcut the recorder could not see — one pressed
/// while Cue Studio itself was in front — can be added by hand.
public struct KeyCue: TimelineRegion {
    public let id: UUID
    public var start: CMTime
    public var duration: CMTime
    public var modifiers: KeyModifiers
    /// The key, by the name the recorder gave it — "K", "Return", "F5", "Space" — or
    /// whatever was typed into the inspector.
    public var key: String
    /// How many times in a row it was pressed: "⌘Z ×3".
    public var count: Int
    /// Kept on the lane, drawn nowhere — not in the preview and not in the export.
    public var isHidden: Bool

    /// How long a press stays on screen. Long enough to be read, short enough that the
    /// next one is not queued behind it.
    public static let defaultDuration = CMTime(value: 720, timescale: 600)

    public init(id: UUID = UUID(),
                start: CMTime,
                duration: CMTime = KeyCue.defaultDuration,
                modifiers: KeyModifiers = [],
                key: String,
                count: Int = 1,
                isHidden: Bool = false) {
        self.id = id
        self.start = start
        self.duration = duration
        self.modifiers = modifiers
        self.key = key
        self.count = count
        self.isHidden = isHidden
        sanitise()
    }

    /// Read field by field, for the reason `Timeline.init(from:)` gives: one cue that will
    /// not decode must not cost the project the whole lane, and a field added later reads
    /// as its default in a project written before it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        id = value(.id, default: UUID())
        start = value(.start, default: .zero)
        duration = value(.duration, default: KeyCue.defaultDuration)
        modifiers = value(.modifiers, default: [])
        key = value(.key, default: "")
        count = value(.count, default: 1)
        isHidden = value(.isHidden, default: false)
        sanitise()
    }

    enum CodingKeys: String, CodingKey {
        case id, start, duration, modifiers, key, count, isHidden
    }

    /// Makes every value one the renderer can draw: a count of at least one, a key
    /// with no stray space around it.
    public mutating func sanitise() {
        if !start.isNumeric || start.seconds.isNaN || start < .zero { start = .zero }
        if !duration.isNumeric || duration.seconds.isNaN || duration < .zero { duration = .zero }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        count = min(max(count, 1), 999)
    }

    // MARK: - What it says

    /// The named key this is, when it is one — read by any spelling, so a key typed into
    /// the inspector as "esc" is Escape.
    public var namedKey: NamedKey? { NamedKey(name: key) }

    /// A named key with nothing held, or with only ⇧: Return, an arrow, Tab. Shown only
    /// when the project asks for them — see `KeyStyle.showsNamedKeysAlone`.
    public var isNamedKeyAlone: Bool {
        modifiers.isDisjoint(with: .operating) && namedKey != nil
    }

    /// Whether there is anything to draw.
    public var isEmpty: Bool { key.isEmpty && modifiers.isEmpty }

    /// What is printed on the key's cap: the symbol for a named key, the name for
    /// everything else.
    public var keySymbol: String { namedKey?.symbol ?? key }

    /// The keycaps in reading order: the modifiers' symbols, then the key's.
    public var caps: [String] {
        let held = modifiers.symbols
        return key.isEmpty ? held : held + [keySymbol]
    }

    /// What the chip and the menu call it, and what the inspector shows to be edited:
    /// "⌘⇧K", "⌘Z ×3", "⏎".
    public var title: String {
        let combo = caps.joined()
        return count > 1 ? "\(combo) ×\(count)" : combo
    }

    /// What a person meant by the keys they typed: "⌘⇧K", "cmd shift k",
    /// "ctrl-alt-delete", "⌘Z ×3".
    ///
    /// Symbols and words both work, in any order, with spaces, `+` or `-` between them.
    /// A named key is read by any spelling and stored by its name; a single character is
    /// stored capitalised, the way it is printed on the key. `nil` when nothing was typed.
    public static func parse(_ text: String) -> (modifiers: KeyModifiers, key: String, count: Int)? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }

        // A count at the end: "×3", or "x3" after a space so that ⌘X stays a key.
        var count = 1
        if let match = rest.range(of: #"(?:×\s*|\s+[x×]\s*)(\d{1,3})\s*$"#, options: .regularExpression) {
            let digits = rest[match].filter(\.isNumber)
            count = Int(digits) ?? 1
            rest.removeSubrange(match)
        }

        // The modifier symbols, wherever they are.
        var modifiers: KeyModifiers = []
        for modifier in KeyModifiers.inDisplayOrder where rest.contains(modifier.symbol) {
            modifiers.insert(modifier)
            rest = rest.replacingOccurrences(of: modifier.symbol, with: " ")
        }

        // A key that is itself one of the separators: "⌘-", "cmd +".
        var key: String?
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.last, "+-".contains(last) {
            key = String(last)
            rest = String(trimmed.dropLast())
        }

        // Words: modifiers by name, the rest is the key.
        var others: [String] = []
        for word in rest.split(whereSeparator: { $0.isWhitespace || $0 == "+" }) {
            let pieces = word.count > 1 && word.contains("-") ? word.split(separator: "-").map(String.init) : [String(word)]
            for piece in pieces {
                if let modifier = Self.modifierWords[piece.lowercased()] {
                    modifiers.insert(modifier)
                } else if piece.lowercased() != "fn" {
                    others.append(piece)
                }
            }
        }
        if key == nil, !others.isEmpty { key = others.joined(separator: " ") }

        var name = key ?? ""
        if let named = NamedKey(name: name) {
            name = named.rawValue
        } else if name.lowercased() == KeyLabels.space.lowercased() || name == "␣" {
            name = KeyLabels.space
        } else if name.count == 1 {
            name = name.uppercased()
        }
        guard !name.isEmpty || !modifiers.isEmpty else { return nil }
        return (modifiers, name, max(1, count))
    }

    private static let modifierWords: [String: KeyModifiers] = [
        "cmd": .command, "command": .command,
        "ctrl": .control, "control": .control, "ctl": .control,
        "opt": .option, "option": .option, "alt": .option,
        "shift": .shift, "shft": .shift,
    ]
}

/// How the pressed keys are drawn, for the whole project.
///
/// One style for every cue rather than per-cue styling, for the reason captions have one:
/// keycaps that change size or place from press to press are a fault, and the things
/// people want to change — where they sit, so they miss the thing being demonstrated,
/// and how they look — are here.
public struct KeyStyle: Codable, Equatable, Sendable {
    public enum Position: String, Codable, Sendable, CaseIterable {
        case bottomCenter, bottomLeft, bottomRight, topCenter, topLeft, topRight

        public var title: String {
            switch self {
            case .bottomCenter: "Bottom"
            case .bottomLeft: "Bottom left"
            case .bottomRight: "Bottom right"
            case .topCenter: "Top"
            case .topLeft: "Top left"
            case .topRight: "Top right"
            }
        }

        /// Which edge the keys sit against, which is what decides whether they share it
        /// with the captions.
        public var isTop: Bool {
            switch self {
            case .topCenter, .topLeft, .topRight: true
            case .bottomCenter, .bottomLeft, .bottomRight: false
            }
        }

        /// Where along the edge: 0 the left, 0.5 the middle, 1 the right.
        public var horizontal: Double {
            switch self {
            case .bottomLeft, .topLeft: 0
            case .bottomCenter, .topCenter: 0.5
            case .bottomRight, .topRight: 1
            }
        }
    }

    /// What a press looks like.
    public enum Look: String, Codable, Sendable, CaseIterable {
        /// A key for each key, drawn like the keys themselves. The default.
        case keycaps
        /// One plate with the whole shortcut on it.
        case pill
        /// The words alone, edged so they read on anything.
        case text

        public var title: String {
            switch self {
            case .keycaps: "Keycaps"
            case .pill: "Pill"
            case .text: "Text"
            }
        }
    }

    public var isVisible: Bool
    public var position: Position
    /// The height of a key, as a fraction of the shorter side of the output — like the
    /// padding, so it reads the same at 1080p, at 4K and in a 9:16 reframe.
    public var size: Double
    public var look: Look
    /// Show Return, Tab, Escape, Delete and the arrows when they are pressed with
    /// nothing held. Off, because on their own they are mostly noise: every line break
    /// and every step through a list would put a key on screen.
    public var showsNamedKeysAlone: Bool

    public static let sizeRange: ClosedRange<Double> = 0.03...0.14

    public init(isVisible: Bool = true,
                position: Position = .bottomCenter,
                size: Double = 0.07,
                look: Look = .keycaps,
                showsNamedKeysAlone: Bool = false) {
        self.isVisible = isVisible
        self.position = position
        self.size = size
        self.look = look
        self.showsNamedKeysAlone = showsNamedKeysAlone
    }

    /// Field by field, for the reason `CursorStyle.init(from:)` gives: the first setting
    /// added here must not cost a project written before it the whole style.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        isVisible = value(.isVisible, default: true)
        position = value(.position, default: .bottomCenter)
        size = value(.size, default: 0.07)
        look = value(.look, default: .keycaps)
        showsNamedKeysAlone = value(.showsNamedKeysAlone, default: false)
    }

    enum CodingKeys: String, CodingKey {
        case isVisible, position, size, look, showsNamedKeysAlone
    }

    /// The same values, clamped to what the renderer can draw. A project is a file, and
    /// a file can say `size: 40`.
    public var sanitised: KeyStyle {
        var copy = self
        copy.size = size.isFinite
            ? min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
            : 0.07
        return copy
    }
}

public extension Timeline {
    /// Whether a cue is drawn at all: not hidden, not empty, and — for a named key on its
    /// own — only when the style asks for those.
    ///
    /// On the model rather than in the renderer because the lane asks the same question:
    /// a cue the style has switched off is not on the lane either, so the lane and the
    /// picture cannot disagree about what is there.
    func isShown(_ cue: KeyCue) -> Bool {
        guard !cue.isHidden, !cue.isEmpty else { return false }
        return keyStyle.showsNamedKeysAlone || !cue.isNamedKeyAlone
    }

    /// The cues the lane draws, in order.
    var shownKeyCues: [KeyCue] { keyCues.filter { isShown($0) } }

    /// The press on screen at a moment, or `nil`.
    ///
    /// Where two overlap the later one wins, because that is the one pressed last: it is
    /// what lets a press cut the one before it short without the file having to say so.
    func keyCue(at time: CMTime) -> KeyCue? {
        guard keyStyle.isVisible, !keyCues.isEmpty else { return nil }
        var best: KeyCue?
        for cue in keyCues where cue.contains(time) && isShown(cue) {
            if best == nil || cue.start >= best!.start { best = cue }
        }
        return best
    }
}
