import AppKit
import Foundation

/// The keys held down alongside another key, as a set.
///
/// Its own type rather than `NSEvent.ModifierFlags`, for the reason `CursorShape` is not
/// `NSCursor`: a recording outlives the process and is read on another Mac, and AppKit's
/// bit values are AppKit's to change. On disk it is a list of names — `["command",
/// "shift"]` — which a person can read in a sidecar and a future build cannot misnumber.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// The ones that turn a key press into a shortcut. Shift is not among them: ⇧A is
    /// typing a capital letter, not operating the app.
    public static let operating: KeyModifiers = [.control, .option, .command]

    /// Each modifier, in the order the menu bar prints them: ⌃ ⌥ ⇧ ⌘.
    public static let inDisplayOrder: [KeyModifiers] = [.control, .option, .shift, .command]

    /// What each one is called on disk.
    static let names: [(modifier: KeyModifiers, name: String)] = [
        (.control, "control"), (.option, "option"), (.shift, "shift"), (.command, "command"),
    ]

    /// The symbol printed on the key, for one modifier at a time.
    public var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        default: ""
        }
    }

    /// The symbols of every modifier in the set, ⌃ ⌥ ⇧ ⌘, the way a menu shows them.
    public var symbols: [String] {
        Self.inDisplayOrder.filter { contains($0) }.map(\.symbol)
    }

    /// What was held during an event. Caps Lock and the fn key are left out: neither
    /// makes a shortcut, and neither is anything a viewer needs to be told about.
    public init(_ flags: NSEvent.ModifierFlags) {
        var set: KeyModifiers = []
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.shift) { set.insert(.shift) }
        if flags.contains(.command) { set.insert(.command) }
        self = set
    }
}

extension KeyModifiers: Codable {
    /// A list of names. A name this build does not know is skipped rather than refused,
    /// so a sidecar from a newer build still reads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let listed = try container.decode([String].self)
        var set: KeyModifiers = []
        for entry in Self.names where listed.contains(entry.name) { set.insert(entry.modifier) }
        self = set
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.names.filter { contains($0.modifier) }.map(\.name))
    }
}

/// The keys that are allowed to be written down by name even with nothing held.
///
/// Return, Tab, the arrows and their kind say what somebody *did* — confirmed, moved on,
/// went back — and nothing about what they wrote. That is the whole of the list, and it
/// is closed: a key that is not on it is a key whose press is recorded as a press and
/// nothing more.
public enum NamedKey: String, CaseIterable, Sendable {
    case `return` = "Return"
    case enter = "Enter"
    case tab = "Tab"
    case escape = "Escape"
    case delete = "Delete"
    case forwardDelete = "Forward Delete"
    case left = "Left"
    case right = "Right"
    case up = "Up"
    case down = "Down"
    case home = "Home"
    case end = "End"
    case pageUp = "Page Up"
    case pageDown = "Page Down"
    case f1 = "F1", f2 = "F2", f3 = "F3", f4 = "F4", f5 = "F5"
    case f6 = "F6", f7 = "F7", f8 = "F8", f9 = "F9", f10 = "F10"
    case f11 = "F11", f12 = "F12", f13 = "F13", f14 = "F14", f15 = "F15"
    case f16 = "F16", f17 = "F17", f18 = "F18", f19 = "F19", f20 = "F20"

    /// The key's virtual key code, which is the same on every layout: the code names
    /// the physical key, and these keys are in the same place on every keyboard.
    public var keyCode: UInt16 {
        switch self {
        case .return: 36
        case .enter: 76
        case .tab: 48
        case .escape: 53
        case .delete: 51
        case .forwardDelete: 117
        case .left: 123
        case .right: 124
        case .up: 126
        case .down: 125
        case .home: 115
        case .end: 119
        case .pageUp: 116
        case .pageDown: 121
        case .f1: 122
        case .f2: 120
        case .f3: 99
        case .f4: 118
        case .f5: 96
        case .f6: 97
        case .f7: 98
        case .f8: 100
        case .f9: 101
        case .f10: 109
        case .f11: 103
        case .f12: 111
        case .f13: 105
        case .f14: 107
        case .f15: 113
        case .f16: 106
        case .f17: 64
        case .f18: 79
        case .f19: 80
        case .f20: 90
        }
    }

    public init?(keyCode: UInt16) {
        guard let match = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = match
    }

    /// The key by its name, however it was capitalised or spaced: "page up", "PageUp",
    /// "esc" and "backspace" are all read.
    public init?(name: String) {
        let wanted = Self.folded(name)
        guard let match = Self.allCases.first(where: { Self.folded($0.rawValue) == wanted })
                ?? Self.aliases[wanted] else { return nil }
        self = match
    }

    private static let aliases: [String: NamedKey] = [
        "esc": .escape, "backspace": .delete, "del": .forwardDelete, "fwddelete": .forwardDelete,
        "ret": .return, "cr": .return, "pgup": .pageUp, "pgdn": .pageDown, "pgdown": .pageDown,
        "leftarrow": .left, "rightarrow": .right, "uparrow": .up, "downarrow": .down,
        "←": .left, "→": .right, "↑": .up, "↓": .down, "⏎": .return, "↩": .return, "⌤": .enter,
        "⇥": .tab, "⎋": .escape, "⌫": .delete, "⌦": .forwardDelete, "↖": .home, "↘": .end,
        "⇞": .pageUp, "⇟": .pageDown,
    ]

    private static func folded(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    /// The symbol drawn on the keycap.
    public var symbol: String {
        switch self {
        case .return: "⏎"
        case .enter: "⌤"
        case .tab: "⇥"
        case .escape: "⎋"
        case .delete: "⌫"
        case .forwardDelete: "⌦"
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        case .home: "↖"
        case .end: "↘"
        case .pageUp: "⇞"
        case .pageDown: "⇟"
        default: rawValue
        }
    }
}

/// A key going down, reduced to the four things the recorder is allowed to look at.
///
/// Built from an `NSEvent` in one place and nowhere else, so that the event's
/// `characters` — the text the press produced — is never read anywhere in this package.
/// The key code is here because a shortcut needs it; the privacy rule in `KeyRecorder`
/// decides whether it is ever turned into a name.
public struct KeyEvent: Equatable, Sendable {
    /// Seconds since the machine started, as `NSEvent.timestamp` counts them.
    public var timestamp: TimeInterval
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    /// A key being held down rather than pressed again.
    public var isRepeat: Bool

    public init(timestamp: TimeInterval, keyCode: UInt16, modifiers: KeyModifiers, isRepeat: Bool = false) {
        self.timestamp = timestamp
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }

    /// The one place an event is read. `event.characters` is not touched.
    @MainActor
    public init(_ event: NSEvent) {
        self.init(timestamp: event.timestamp,
                  keyCode: event.keyCode,
                  modifiers: KeyModifiers(event.modifierFlags),
                  isRepeat: event.isARepeat)
    }
}

/// What a key press may say about itself. The privacy rule, as one function.
///
/// A key is written down by name **only** when ⌘ or ⌃ is held, or when it is one of the
/// `NamedKey`s — with or without ⌥ and ⇧. ⌥ on its own does not make a shortcut of a
/// letter or a number, and ⇧ never does. Every other press is written as "a key went down
/// at this time" and nothing else: no name, no character, no modifiers. The label is
/// looked up only once that decision has been made, so a resolver that could name a
/// typed letter is never asked to.
///
/// ⌥ is left out because on most of the world's keyboards it is how characters are typed:
/// @ is ⌥L on a German keyboard, and brackets and braces are ⌥ on most European ones. An
/// email address typed in Munich would otherwise have left its @ in the recording.
public enum KeyRecorder {
    /// Whether a press of this key, with these held, may be named.
    public static func mayBeNamed(keyCode: UInt16, modifiers: KeyModifiers) -> Bool {
        !modifiers.isDisjoint(with: [.command, .control]) || NamedKey(keyCode: keyCode) != nil
    }

    /// The sample to write for a press at `t` on the recording's clock, or `nil` for a
    /// press that is not written at all.
    ///
    /// - Parameter label: what is printed on the key, for a key that may be named. Asked
    ///   only then — see the type's note. A key it cannot name is written as an
    ///   anonymous press rather than as a shortcut with no key on it.
    public static func sample(for event: KeyEvent, at t: Double, label: (UInt16) -> String?) -> InputSample? {
        // A held key is one press. Auto-repeat delivers thirty of them a second, and
        // "⌫ ×60" is not what a viewer needs to be told about a held Delete.
        guard !event.isRepeat else { return nil }
        guard mayBeNamed(keyCode: event.keyCode, modifiers: event.modifiers),
              let name = label(event.keyCode) else {
            return .key(t: t, modifiers: 0)
        }
        return .shortcut(t: t, modifiers: event.modifiers, key: name)
    }
}

/// What is printed on a key.
///
/// The person's own layout first, because a viewer of a French recording should see the
/// A that was pressed and not the Q that sits in that place on an American keyboard.
/// When the layout cannot say — an input method with no key layout, a key it has no
/// character for — the US name is used, which is at least a name.
public enum KeyLabels {
    /// The label for a key code, given a way of asking the current layout.
    ///
    /// - Parameter layout: the character the layout prints on the key, or `nil`. Injected
    ///   so the rule can be checked without a keyboard, and so a test never depends on
    ///   which layout the machine running it happens to have.
    public static func label(forKeyCode keyCode: UInt16, layout: (UInt16) -> String?) -> String? {
        if let named = NamedKey(keyCode: keyCode) { return named.rawValue }
        if keyCode == Self.spaceKeyCode { return Self.space }
        if let printed = layout(keyCode), let legible = Self.legible(printed) { return legible }
        return unitedStates[keyCode]
    }

    /// The name of the space bar, which prints nothing.
    public static let space = "Space"
    static let spaceKeyCode: UInt16 = 49

    /// A layout's answer as a keycap legend: one printable character, capitalised the way
    /// the key is. Whitespace and control characters are not legends.
    static func legible(_ printed: String) -> String? {
        let trimmed = printed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let scalar = trimmed.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
        return trimmed.uppercased()
    }

    /// The ANSI US layout, by key code. Letters and digits as printed, punctuation as
    /// printed unshifted.
    static let unitedStates: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 49: "Space", 50: "`",
        65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 78: "-", 81: "=",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        114: "Help",
    ]

    /// The US key code for a character, for tests and tools that want to press a key by
    /// what it prints. Letters and digits only, the way a test types a sentence.
    public static func unitedStatesKeyCode(for character: Character) -> UInt16? {
        let wanted = String(character).uppercased()
        return unitedStates.first { $0.value == wanted && $0.key < 60 }?.key
    }
}
