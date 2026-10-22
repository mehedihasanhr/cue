import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import RecordKit
import SwiftUI

/// The editor's menu shortcuts as somebody has set them — see `EditorShortcuts`, which
/// holds the defaults and the rules.
///
/// Its own object, reached as `settings.editorShortcuts`, for the reason
/// `RecorderPreferences` is one: one feature's worth of state that changes together.
/// Observable, so the menu bar — which SwiftUI rebuilds from `EditorCommands` whenever
/// what it read changes — picks up a new shortcut the moment Settings takes it, with no
/// relaunch and no notification to forget to post.
@MainActor
@Observable
final class EditorShortcutPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    /// Under `editor.`, so Reset All Settings puts every shortcut back with the rest.
    private static let key = "editor.shortcuts"

    var shortcuts: EditorShortcuts {
        didSet { defaults.set(try? JSONEncoder().encode(shortcuts), forKey: Self.key) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcuts = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(EditorShortcuts.self, from: $0) } ?? .defaults
    }

    subscript(command: EditorCommand) -> KeyCombo? {
        get { shortcuts[command] }
        set { shortcuts[command] = newValue }
    }

    /// What a menu item is given for this command, or `nil` for none.
    func menuShortcut(for command: EditorCommand) -> KeyboardShortcut? {
        shortcuts[command]?.keyboardShortcut
    }
}

extension KeyCombo {
    /// The same shortcut in SwiftUI's terms, for a menu item — `nil` for a key a menu cannot
    /// show.
    ///
    /// The keys with names of their own go through SwiftUI's constants rather than through
    /// a character, so Delete, the arrows, Home and End reach the menu exactly as the
    /// `.keyboardShortcut(.delete)` they replace did.
    var keyboardShortcut: KeyboardShortcut? {
        keyEquivalent.map { KeyboardShortcut($0, modifiers: eventModifiers) }
    }

    var keyEquivalent: KeyEquivalent? {
        switch Int(keyCode) {
        case kVK_Delete: return .delete
        case kVK_ForwardDelete: return .deleteForward
        case kVK_LeftArrow: return .leftArrow
        case kVK_RightArrow: return .rightArrow
        case kVK_UpArrow: return .upArrow
        case kVK_DownArrow: return .downArrow
        case kVK_Home: return .home
        case kVK_End: return .end
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        case kVK_Return: return .return
        case kVK_Tab: return .tab
        case kVK_Space: return .space
        case kVK_Escape: return .escape
        default:
            if let index = KeyCombo.functionKeyOrder.firstIndex(of: Int(keyCode)),
               let scalar = Unicode.Scalar(NSF1FunctionKey + index) {
                return KeyEquivalent(Character(scalar))
            }
            return menuKeyEquivalent.first.map { KeyEquivalent($0) }
        }
    }

    /// The character this key types with no ⌘, ⌃ or ⌥ held — what `TypingGuard` hands back
    /// to a text field — or `nil` for a key that types nothing or is held with one of them.
    var typedCharacter: String? {
        guard !hasCommand, !hasControl, !hasOption, typesText else { return nil }
        guard hasShift else { return keyName.lowercased() }
        // ⇧ with a letter is its capital; ⇧ with a digit or a mark depends on the layout,
        // and a guess would type the wrong character into somebody's caption.
        return keyName.first?.isLetter == true ? keyName.uppercased() : nil
    }
}

extension View {
    /// The command's shortcut as it is set now, or none.
    func editorShortcut(_ command: EditorCommand, _ shortcuts: EditorShortcutPreferences) -> some View {
        keyboardShortcut(shortcuts.menuShortcut(for: command))
    }
}

extension TypingGuard {
    /// The same guard, for a shortcut that may have been changed: the character the
    /// shortcut types, when it types one, goes to the field being edited. A shortcut held
    /// with ⌘, ⌃ or ⌥ types nothing, so there is nothing to hand back and the command runs.
    @MainActor
    static func consumed(_ combo: KeyCombo?) -> Bool {
        guard let character = combo?.typedCharacter else { return false }
        return consumed(character)
    }
}
