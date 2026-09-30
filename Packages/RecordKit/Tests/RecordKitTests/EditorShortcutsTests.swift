import Carbon.HIToolbox
import Foundation
import Testing
@testable import RecordKit

/// The editor's rebindable shortcuts: the defaults the menus always had, which keys may be
/// taken, and how a change is kept.
struct EditorShortcutsTests {
    private func combo(_ key: Int, _ modifiers: Int = 0) -> KeyCombo {
        KeyCombo(keyCode: UInt32(key), modifiers: UInt32(modifiers))
    }

    // MARK: - Defaults

    /// The keys the menus had before any of this, spot-checked across every menu.
    @Test func theDefaultsAreTheShortcutsTheMenusAlwaysHad() {
        let defaults = EditorShortcuts.defaults
        #expect(defaults[.save]?.displayString == "⌘S")
        #expect(defaults[.redo]?.displayString == "⇧⌘Z")
        #expect(defaults[.deleteSelection] == combo(kVK_Delete))
        #expect(defaults[.markStart]?.displayString == "I")
        #expect(defaults[.splitZoom]?.displayString == "⌥⌘B")
        #expect(defaults[.playPause]?.displayString == "Space")
        #expect(defaults[.previousCut]?.displayString == "⌥←")
        #expect(defaults[.previousMarker]?.displayString == "⌃;")
        #expect(defaults[.toolKeyboard]?.displayString == "⌘9")
        #expect(defaults[.fitTimeline]?.displayString == "⌘0")
        #expect(defaults[.lockZoom] == nil)
    }

    /// No two defaults share a key, and none clashes with macOS, this app's fixed menus or
    /// the recorder's default global shortcuts.
    @Test func noDefaultClashesWithAnything() {
        let combos = EditorCommand.allCases.compactMap(\.defaultShortcut)
        #expect(Set(combos).count == combos.count)
        #expect(EditorShortcuts.defaults.problems(recorder: .defaults).isEmpty)
    }

    /// Every command is in exactly one menu, and every menu has something in it.
    @Test func everyCommandBelongsToAMenu() {
        let grouped = EditorCommand.Menu.allCases.flatMap(\.commands)
        #expect(grouped.count == EditorCommand.allCases.count)
        #expect(EditorCommand.Menu.allCases.allSatisfy { !$0.commands.isEmpty })
        #expect(Set(EditorCommand.allCases.map(\.title)).count == EditorCommand.allCases.count)
    }

    // MARK: - Changing and resetting

    @Test func aChangeIsKeptAndResetPutsTheDefaultBack() {
        var shortcuts = EditorShortcuts.defaults
        shortcuts[.addZoom] = combo(kVK_ANSI_Z, controlKey)
        #expect(shortcuts[.addZoom]?.displayString == "⌃Z")
        #expect(shortcuts.isCustomised(.addZoom))
        #expect(!shortcuts.isDefault)
        shortcuts.reset(.addZoom)
        #expect(shortcuts[.addZoom]?.displayString == "⌘K")
        #expect(shortcuts.isDefault)
    }

    /// Set back to what it ships with, a command is not "changed" — so a later build's
    /// default reaches it.
    @Test func settingTheDefaultByHandIsNotAChange() {
        var shortcuts = EditorShortcuts.defaults
        shortcuts[.save] = combo(kVK_ANSI_S, cmdKey)
        #expect(!shortcuts.isCustomised(.save))
        #expect(shortcuts == .defaults)
    }

    /// Taking a shortcut away is a change, and survives being stored.
    @Test func aRemovedShortcutStaysRemoved() throws {
        var shortcuts = EditorShortcuts.defaults
        shortcuts[.playPause] = nil
        #expect(shortcuts[.playPause] == nil)
        #expect(shortcuts.isCustomised(.playPause))
        let decoded = try JSONDecoder().decode(EditorShortcuts.self, from: JSONEncoder().encode(shortcuts))
        #expect(decoded[.playPause] == nil)
        #expect(decoded == shortcuts)
    }

    /// Only the changes are stored, so an untouched command follows its default.
    @Test func onlyTheChangesAreStored() throws {
        var shortcuts = EditorShortcuts.defaults
        shortcuts[.lockZoom] = combo(kVK_ANSI_L, controlKey | cmdKey)
        let stored = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(shortcuts)) as? [String: Any])
        #expect(Set(stored.keys) == ["lockZoom"])
        let decoded = try JSONDecoder().decode(EditorShortcuts.self, from: JSONEncoder().encode(shortcuts))
        #expect(decoded[.lockZoom]?.displayString == "⌃⌘L")
        #expect(decoded[.save]?.displayString == "⌘S")
    }

    /// A command a newer build stored, and this one has never heard of, is skipped rather
    /// than costing the rest.
    @Test func anUnknownCommandIsSkippedNotFatal() throws {
        let json = #"{"notACommand":{"keyCode":1,"modifiers":256},"addZoom":{"keyCode":6,"modifiers":4096}}"#
        let decoded = try JSONDecoder().decode(EditorShortcuts.self, from: Data(json.utf8))
        #expect(decoded[.addZoom] == KeyCombo(keyCode: 6, modifiers: 4096))
        #expect(decoded.overrides.count == 1)
    }

    // MARK: - What may be used

    @Test func aKeyAnotherCommandHasIsRefused() {
        let shortcuts = EditorShortcuts.defaults
        #expect(shortcuts.problem(with: combo(kVK_ANSI_K, cmdKey), for: .lockZoom) == .usedBy(.addZoom))
        // Its own key is no clash with itself.
        #expect(shortcuts.problem(with: combo(kVK_ANSI_K, cmdKey), for: .addZoom) == nil)
    }

    @Test func macOSKeysAreRefused() {
        let problem = EditorShortcuts.defaults.problem(with: combo(kVK_Space, cmdKey), for: .lockZoom)
        #expect(problem == .system("Spotlight"))
    }

    @Test func thisAppsFixedMenusAreRefused() {
        let shortcuts = EditorShortcuts.defaults
        #expect(shortcuts.problem(with: combo(kVK_ANSI_Q, cmdKey), for: .lockZoom) == .app("quitting"))
        #expect(shortcuts.problem(with: combo(kVK_ANSI_P, shiftKey | cmdKey), for: .lockZoom) == .app("the Command Menu"))
        #expect(shortcuts.problem(with: combo(kVK_Escape), for: .lockZoom) == .app("cancelling"))
    }

    /// A global shortcut takes the key first, so while the recorder's are on they are
    /// refused — and while they are off, they are not.
    @Test func theRecordersGlobalShortcutsAreRefusedOnlyWhileOn() {
        let record = RecorderShortcuts.defaults[.record]!
        let shortcuts = EditorShortcuts.defaults
        #expect(shortcuts.problem(with: record, for: .lockZoom, recorder: .defaults) == .recorder(.record))
        #expect(shortcuts.problem(with: record, for: .lockZoom, recorder: nil) == nil)
    }

    @Test func optionWithALetterTypesACharacter() {
        let shortcuts = EditorShortcuts.defaults
        #expect(shortcuts.problem(with: combo(kVK_ANSI_L, optionKey), for: .lockZoom) == .typesCharacter)
        // An arrow does not type anything, which is why ⌥← is fine.
        #expect(shortcuts.problem(with: combo(kVK_UpArrow, optionKey), for: .lockZoom) == nil)
    }

    /// Plain keys and ⌘ alone are allowed here, unlike for the recorder: they are menu
    /// shortcuts, answered only while the editor is in front.
    @Test func plainKeysAndCommandAloneAreFineForAMenu() {
        let shortcuts = EditorShortcuts.defaults
        #expect(shortcuts.problem(with: combo(kVK_ANSI_G), for: .lockZoom) == nil)
        #expect(shortcuts.problem(with: combo(kVK_ANSI_G, cmdKey), for: .lockZoom) == nil)
    }

    /// Two commands made to share a key are both flagged.
    @Test func aClashIsFlaggedOnBothSides() {
        var shortcuts = EditorShortcuts.defaults
        shortcuts[.lockZoom] = combo(kVK_ANSI_S, cmdKey)
        let problems = shortcuts.problems()
        #expect(problems[.lockZoom] == .usedBy(.save))
        #expect(problems[.save] == .usedBy(.lockZoom))
    }

    /// Function keys are named for the key, not for where their scattered key codes sort.
    @Test func functionKeysAreNamedInOrder() {
        #expect(combo(kVK_F1).displayString == "F1")
        #expect(combo(kVK_F3).displayString == "F3")
        #expect(combo(kVK_F12).displayString == "F12")
        #expect(combo(kVK_F17).displayString == "F17")
    }

    // MARK: - The recorder's side

    /// Giving a global shortcut a key the editor uses is refused, with the editor named.
    @Test func aRecorderShortcutMayNotTakeAnEditorKey() {
        let problem = RecorderShortcuts.defaults.problem(with: combo(kVK_ANSI_K, controlKey | cmdKey),
                                                         for: .marker,
                                                         editor: EditorShortcuts(overrides: [.lockZoom: combo(kVK_ANSI_K, controlKey | cmdKey)]))
        #expect(problem == .editor(.lockZoom))
        #expect(problem?.message.contains("Lock or Unlock Zoom") == true)
        // The recorder's own rules still come first.
        #expect(RecorderShortcuts.defaults.problem(with: combo(kVK_ANSI_R), for: .record,
                                                   editor: .defaults) == .needsModifier)
    }
}
