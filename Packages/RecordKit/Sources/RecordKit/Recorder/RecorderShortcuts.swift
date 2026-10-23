import Carbon.HIToolbox
import Foundation

/// The four things the recorder can be told to do from any app.
public enum RecorderAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case record, pause, restart, marker

    public var id: String { rawValue }

    /// What Settings calls it.
    public var title: String {
        switch self {
        case .record: "Start or stop recording"
        case .pause: "Pause or resume"
        case .restart: "Restart the take"
        case .marker: "Add a marker"
        }
    }

    /// ⌃⌥⌘ and a letter that says what it does. Three modifiers because two are not enough
    /// to stay out of other apps' way: ⌘⇧ and ⌥⌘ letters are menu shortcuts somewhere, and
    /// a global shortcut takes its key from every app while it is registered.
    /// Restart is T, for "take again": R is Record's.
    public var defaultShortcut: KeyCombo {
        let all = UInt32(controlKey | optionKey | cmdKey)
        return switch self {
        case .record: KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: all)
        case .pause: KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: all)
        case .restart: KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: all)
        case .marker: KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: all)
        }
    }

    /// Whether the shortcut is wanted in this state of the session.
    ///
    /// Record is always listening — it is how a take starts from another app. The other
    /// three mean nothing without a take, so they are registered only while one is under
    /// way: a global shortcut is a key taken away from every other app, and taking ⌃⌥⌘P
    /// all day for the minutes somebody is recording would be taking it for nothing.
    public func isWanted(in state: RecordingSession.State) -> Bool {
        switch self {
        case .record: true
        case .pause, .restart, .marker: state.isTaking
        }
    }
}

/// A key and the modifiers held with it, in Carbon's terms — what
/// `RegisterEventHotKey` takes, and what Settings stores.
public struct KeyCombo: Hashable, Codable, Sendable {
    public var keyCode: UInt32
    /// `cmdKey`, `shiftKey`, `optionKey`, `controlKey`, or'd together.
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var hasCommand: Bool { modifiers & UInt32(cmdKey) != 0 }
    public var hasOption: Bool { modifiers & UInt32(optionKey) != 0 }
    public var hasControl: Bool { modifiers & UInt32(controlKey) != 0 }
    public var hasShift: Bool { modifiers & UInt32(shiftKey) != 0 }

    public var isFunctionKey: Bool { Self.functionKeys.contains(Int(keyCode)) }

    /// "⌃⌥⌘R", in the order the system's own menus write modifiers.
    public var displayString: String {
        var text = ""
        if hasControl { text += "⌃" }
        if hasOption { text += "⌥" }
        if hasShift { text += "⇧" }
        if hasCommand { text += "⌘" }
        return text + keyName
    }

    /// The key's own name: its letter on a US layout, or its symbol.
    public var keyName: String {
        Self.names[Int(keyCode)] ?? "Key \(keyCode)"
    }

    /// What an `NSMenuItem` takes as its key equivalent, lower-case for a letter, so the
    /// menu shows the same shortcut Settings does. Empty for a key a menu cannot show.
    public var menuKeyEquivalent: String {
        if let special = Self.menuSpecials[Int(keyCode)] { return special }
        let name = keyName
        return name.count == 1 ? name.lowercased() : ""
    }

    /// F1 to F20, in that order. An array, because the order is the name: the key codes
    /// themselves are scattered — F3 is 99, F17 is 64 — and naming them by sorting the codes
    /// called F3 "F8" and F17 "F1".
    public static let functionKeyOrder: [Int] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let functionKeys = Set(functionKeyOrder)

    private static let names: [Int: String] = {
        var names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        for (index, key) in functionKeyOrder.enumerated() { names[key] = "F\(index + 1)" }
        return names
    }()

    private static let menuSpecials: [Int: String] = [
        kVK_Return: "\r", kVK_Tab: "\t", kVK_Space: " ", kVK_Delete: "\u{8}", kVK_Escape: "\u{1B}",
    ]
}

/// Why a shortcut cannot be used, in words Settings shows beside it.
public enum ShortcutProblem: Equatable, Sendable {
    /// No ⌘, ⌥ or ⌃, so it would take a key away from ordinary typing.
    case needsModifier
    /// Only ⌘ (with or without ⇧): apps use these for their menus.
    case commonInApps
    /// Only ⌥ (with or without ⇧): that types a character.
    case typesCharacter
    /// macOS has it — a screenshot, Spotlight, switching Spaces.
    case system(String)
    /// Another of the recorder's own shortcuts.
    case usedBy(RecorderAction)
    /// One of Cue's, which is usually running beside this app.
    case cue(String)
    /// One of the editor's menu shortcuts. A global shortcut takes the key before any menu
    /// sees it, so the editor would lose it for as long as the shortcut is registered.
    case editor(EditorCommand)

    public var message: String {
        switch self {
        case .needsModifier: "Add ⌘, ⌥ or ⌃, or it would take the key away from typing."
        case .commonInApps: "Apps use ⌘ shortcuts for their menus. Add ⌃ or ⌥."
        case .typesCharacter: "⌥ with a key types a character. Add ⌘ or ⌃."
        case .system(let name): "macOS uses this for \(name)."
        case .usedBy(let action): "Already used for \u{201C}\(action.title)\u{201D}."
        case .cue(let name): "Cue uses this for \(name)."
        case .editor(let command): "The editor uses this for \u{201C}\(command.title)\u{201D}."
        }
    }
}

/// The recorder's global shortcuts: which key does what, and whether a key may be used.
public struct RecorderShortcuts: Codable, Equatable, Sendable {
    /// `nil` for an action that has been given no shortcut.
    public var bindings: [RecorderAction: KeyCombo]

    public init(bindings: [RecorderAction: KeyCombo]) {
        self.bindings = bindings
    }

    public static let defaults = RecorderShortcuts(
        bindings: Dictionary(uniqueKeysWithValues: RecorderAction.allCases.map { ($0, $0.defaultShortcut) }))

    public subscript(action: RecorderAction) -> KeyCombo? {
        get { bindings[action] }
        set { bindings[action] = newValue }
    }

    /// What is wrong with giving `combo` to `action`, or `nil` when nothing is.
    ///
    /// Checked from the most specific answer to the most general: a key that takes typing
    /// away, then who already has it by name — macOS, Cue, another of these — and only
    /// then the shape of the modifiers, which is a rule of thumb rather than a clash.
    public func problem(with combo: KeyCombo, for action: RecorderAction) -> ShortcutProblem? {
        let plain = !combo.hasCommand && !combo.hasOption && !combo.hasControl
        if plain, !combo.isFunctionKey { return .needsModifier }
        if let name = Self.system[combo] { return .system(name) }
        if let name = Self.cue[combo] { return .cue(name) }
        if let other = bindings.first(where: { $0.key != action && $0.value == combo })?.key { return .usedBy(other) }
        guard !combo.isFunctionKey else { return nil }
        if combo.hasCommand, !combo.hasOption, !combo.hasControl { return .commonInApps }
        if combo.hasOption, !combo.hasCommand, !combo.hasControl { return .typesCharacter }
        return nil
    }

    /// The same question, asked with the editor's shortcuts in view as well — what
    /// Settings asks before it takes a new key. Kept apart from the one above because that
    /// one also decides what is registered, and a clash with a menu is a reason to refuse a
    /// change, not to take away a shortcut somebody already relies on.
    public func problem(with combo: KeyCombo, for action: RecorderAction,
                        editor: EditorShortcuts) -> ShortcutProblem? {
        if let problem = problem(with: combo, for: action) { return problem }
        return editor.command(using: combo).map { .editor($0) }
    }

    /// Every binding that has a problem as things stand — what Settings flags on opening.
    public var problems: [RecorderAction: ShortcutProblem] {
        var found: [RecorderAction: ShortcutProblem] = [:]
        for (action, combo) in bindings {
            if let problem = problem(with: combo, for: action) { found[action] = problem }
        }
        return found
    }

    // MARK: - Stored

    /// Read field by field, so a stored set missing an action gets that action's default
    /// rather than losing every shortcut, and an action a newer build added arrives bound.
    /// An action explicitly cleared is stored as `null` and stays cleared.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stored = try container.decode([String: KeyCombo?].self)
        var bindings: [RecorderAction: KeyCombo] = [:]
        for action in RecorderAction.allCases {
            if let entry = stored[action.rawValue] {
                if let combo = entry { bindings[action] = combo }
            } else {
                bindings[action] = action.defaultShortcut
            }
        }
        self.bindings = bindings
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let stored = Dictionary(uniqueKeysWithValues: RecorderAction.allCases.map { ($0.rawValue, bindings[$0]) })
        try container.encode(stored)
    }

    // MARK: - Taken

    private static func combo(_ key: Int, _ modifiers: Int) -> KeyCombo {
        KeyCombo(keyCode: UInt32(key), modifiers: UInt32(modifiers))
    }

    /// What macOS answers before any app: screenshots, Spotlight, the app switcher, Mission
    /// Control, the lock screen, and the accessibility toggles on ⌃⌥⌘ and ⌥⌘.
    static let system: [KeyCombo: String] = {
        let shiftCommand = shiftKey | cmdKey
        let controlShiftCommand = controlKey | shiftKey | cmdKey
        let controlOptionCommand = controlKey | optionKey | cmdKey
        var taken: [KeyCombo: String] = [
            combo(kVK_ANSI_3, shiftCommand): "screenshots",
            combo(kVK_ANSI_4, shiftCommand): "screenshots",
            combo(kVK_ANSI_5, shiftCommand): "screenshots",
            combo(kVK_ANSI_6, shiftCommand): "screenshots",
            combo(kVK_ANSI_3, controlShiftCommand): "screenshots",
            combo(kVK_ANSI_4, controlShiftCommand): "screenshots",
            combo(kVK_Space, cmdKey): "Spotlight",
            combo(kVK_Space, optionKey | cmdKey): "Finder search",
            combo(kVK_Space, controlKey): "input sources",
            combo(kVK_Tab, cmdKey): "switching apps",
            combo(kVK_ANSI_Grave, cmdKey): "switching windows",
            combo(kVK_ANSI_Q, controlKey | cmdKey): "locking the screen",
            combo(kVK_ANSI_F, controlKey | cmdKey): "full screen",
            combo(kVK_Escape, optionKey | cmdKey): "Force Quit",
            combo(kVK_ANSI_D, optionKey | cmdKey): "the Dock",
            combo(kVK_ANSI_8, optionKey | cmdKey): "Zoom",
            combo(kVK_ANSI_Equal, optionKey | cmdKey): "Zoom",
            combo(kVK_ANSI_Minus, optionKey | cmdKey): "Zoom",
            combo(kVK_ANSI_8, controlOptionCommand): "inverting colours",
            combo(kVK_ANSI_Comma, controlOptionCommand): "contrast",
            combo(kVK_ANSI_Period, controlOptionCommand): "contrast",
            combo(kVK_F5, optionKey | cmdKey): "Accessibility Shortcuts",
        ]
        for arrow in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow] {
            taken[combo(arrow, controlKey)] = "Mission Control"
        }
        return taken
    }()

    /// Cue's own defaults. Cue is the host this app is launched from, so the two are
    /// usually running together and the first to register a key keeps it.
    static let cue: [KeyCombo: String] = {
        let optionShift = optionKey | shiftKey
        let shiftCommand = shiftKey | cmdKey
        return [
            combo(kVK_ANSI_3, optionShift): "capturing the screen",
            combo(kVK_ANSI_4, optionShift): "capturing an area",
            combo(kVK_ANSI_5, optionShift): "scrolling capture",
            combo(kVK_ANSI_6, optionShift): "capturing a window",
            combo(kVK_ANSI_K, optionShift): "its panel",
            combo(kVK_ANSI_T, optionShift): "capturing text",
            combo(kVK_ANSI_P, optionShift): "picking a colour",
            combo(kVK_ANSI_N, optionShift): "a quick task",
            combo(kVK_ANSI_M, optionShift): "a quick note",
            combo(kVK_Space, optionShift): "its command palette",
            combo(kVK_ANSI_C, shiftCommand): "its clipboard list",
            combo(kVK_ANSI_V, shiftCommand): "paste next",
        ]
    }()
}
