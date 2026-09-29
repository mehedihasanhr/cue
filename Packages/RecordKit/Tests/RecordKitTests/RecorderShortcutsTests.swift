import Carbon.HIToolbox
import Foundation
import Testing
@testable import RecordKit

/// The recorder's global shortcuts: what the keys are, which ones may be used, and what is
/// registered when. Nothing here registers a real shortcut — `FakeRegistrar` only writes
/// down what it was asked.
@MainActor
struct RecorderShortcutsTests {
    private let hyper = UInt32(controlKey | optionKey | cmdKey)

    private func combo(_ key: Int, _ modifiers: Int) -> KeyCombo {
        KeyCombo(keyCode: UInt32(key), modifiers: UInt32(modifiers))
    }

    // MARK: - Defaults

    @Test func `the defaults are ⌃⌥⌘ R, P, T and M`() {
        let defaults = RecorderShortcuts.defaults
        #expect(defaults[.record]?.displayString == "⌃⌥⌘R")
        #expect(defaults[.pause]?.displayString == "⌃⌥⌘P")
        #expect(defaults[.restart]?.displayString == "⌃⌥⌘T")
        #expect(defaults[.marker]?.displayString == "⌃⌥⌘M")
    }

    @Test func `no default clashes with macOS, Klik or another default`() {
        #expect(RecorderShortcuts.defaults.problems.isEmpty)
        let combos = RecorderAction.allCases.compactMap { RecorderShortcuts.defaults[$0] }
        #expect(Set(combos).count == combos.count)
    }

    @Test func `menus show the shortcut Settings shows`() {
        let record = RecorderShortcuts.defaults[.record]!
        #expect(record.menuKeyEquivalent == "r")
        #expect(record.hasControl && record.hasOption && record.hasCommand && !record.hasShift)
        #expect(combo(kVK_F5, 0).displayString == "F5")
        #expect(combo(kVK_ANSI_1, shiftKey | cmdKey).displayString == "⇧⌘1")
    }

    // MARK: - What may be used

    @Test func `a plain letter would take typing away`() {
        #expect(RecorderShortcuts.defaults.problem(with: combo(kVK_ANSI_R, 0), for: .record) == .needsModifier)
        #expect(RecorderShortcuts.defaults.problem(with: combo(kVK_ANSI_R, shiftKey), for: .record) == .needsModifier)
    }

    @Test func `a function key on its own is allowed`() {
        #expect(RecorderShortcuts.defaults.problem(with: combo(kVK_F13, 0), for: .record) == nil)
    }

    @Test func `⌘ alone is every app's menu`() {
        #expect(RecorderShortcuts.defaults.problem(with: combo(kVK_ANSI_R, cmdKey), for: .record) == .commonInApps)
        #expect(RecorderShortcuts.defaults.problem(with: combo(kVK_ANSI_R, cmdKey | shiftKey), for: .record) == .commonInApps)
    }

    @Test func `⌥ alone types a character`() {
        #expect(RecorderShortcuts.defaults.problem(with: combo(kVK_ANSI_R, optionKey), for: .record) == .typesCharacter)
    }

    @Test func `the screenshot keys belong to macOS`() {
        let problem = RecorderShortcuts.defaults.problem(with: combo(kVK_ANSI_5, shiftKey | cmdKey), for: .record)
        #expect(problem == .system("screenshots"))
        #expect(problem?.message == "macOS uses this for screenshots.")
    }

    @Test func `switching Spaces and locking the screen belong to macOS`() {
        #expect(RecorderShortcuts.defaults.problem(with: combo(kVK_LeftArrow, controlKey), for: .marker) == .system("Mission Control"))
        #expect(RecorderShortcuts.defaults.problem(with: combo(kVK_ANSI_Q, controlKey | cmdKey), for: .marker) == .system("locking the screen"))
        #expect(RecorderShortcuts.defaults.problem(with: combo(kVK_ANSI_8, controlKey | optionKey | cmdKey), for: .marker)
                == .system("inverting colours"))
    }

    @Test func `Klik's own capture keys are Klik's`() {
        let problem = RecorderShortcuts.defaults.problem(with: combo(kVK_ANSI_3, optionKey | shiftKey), for: .record)
        #expect(problem == .klik("capturing the screen"))
    }

    @Test func `two actions cannot share a key`() {
        let pauseKey = RecorderShortcuts.defaults[.pause]!
        #expect(RecorderShortcuts.defaults.problem(with: pauseKey, for: .marker) == .usedBy(.pause))
        // Its own key is not a clash with itself.
        #expect(RecorderShortcuts.defaults.problem(with: pauseKey, for: .pause) == nil)
    }

    // MARK: - Stored

    @Test func `a cleared shortcut stays cleared through a round trip`() throws {
        var shortcuts = RecorderShortcuts.defaults
        shortcuts[.marker] = nil
        shortcuts[.pause] = combo(kVK_ANSI_Y, controlKey | optionKey | cmdKey)
        let back = try JSONDecoder().decode(RecorderShortcuts.self, from: JSONEncoder().encode(shortcuts))
        #expect(back == shortcuts)
        #expect(back[.marker] == nil)
    }

    /// Settings stored by a build that knew fewer actions: the missing ones arrive bound.
    @Test func `an action missing from what was stored gets its default`() throws {
        let stored = #"{"record":{"keyCode":15,"modifiers":6400}}"#
        let shortcuts = try JSONDecoder().decode(RecorderShortcuts.self, from: Data(stored.utf8))
        #expect(shortcuts[.record] == KeyCombo(keyCode: 15, modifiers: 6400))
        #expect(shortcuts[.marker] == RecorderAction.marker.defaultShortcut)
    }

    // MARK: - What is registered when

    private let started = Date(timeIntervalSinceReferenceDate: 100)

    @Test func `idle, only Record listens`() {
        let registrar = FakeRegistrar()
        let hotkeys = RecorderHotkeys(registrar: registrar)
        hotkeys.update(shortcuts: .defaults, isEnabled: true, state: .idle)
        #expect(Set(hotkeys.registered.keys) == [.record])
        #expect(registrar.live.values.map(\.displayString) == ["⌃⌥⌘R"])
    }

    @Test func `during a take all four listen, and let go afterwards`() {
        let registrar = FakeRegistrar()
        let hotkeys = RecorderHotkeys(registrar: registrar)
        hotkeys.update(shortcuts: .defaults, isEnabled: true, state: .recording(startedAt: started))
        #expect(Set(hotkeys.registered.keys) == Set(RecorderAction.allCases))
        hotkeys.update(shortcuts: .defaults, isEnabled: true,
                       state: .paused(startedAt: started, at: started.addingTimeInterval(3)))
        #expect(registrar.live.count == 4, "pausing changes nothing that is registered")
        #expect(registrar.registrations == 4, "and registers nothing twice")
        hotkeys.update(shortcuts: .defaults, isEnabled: true, state: .finishing)
        #expect(Set(hotkeys.registered.keys) == [.record])
        #expect(registrar.live.count == 1)
    }

    @Test func `a countdown is not a take`() {
        let hotkeys = RecorderHotkeys(registrar: FakeRegistrar())
        hotkeys.update(shortcuts: .defaults, isEnabled: true, state: .countdown(remaining: 2))
        #expect(Set(hotkeys.registered.keys) == [.record])
    }

    @Test func `turned off, nothing is registered`() {
        let registrar = FakeRegistrar()
        let hotkeys = RecorderHotkeys(registrar: registrar)
        hotkeys.update(shortcuts: .defaults, isEnabled: true, state: .recording(startedAt: started))
        hotkeys.update(shortcuts: .defaults, isEnabled: false, state: .recording(startedAt: started))
        #expect(hotkeys.registered.isEmpty)
        #expect(registrar.live.isEmpty)
    }

    @Test func `a changed shortcut replaces the old one`() {
        let registrar = FakeRegistrar()
        let hotkeys = RecorderHotkeys(registrar: registrar)
        hotkeys.update(shortcuts: .defaults, isEnabled: true, state: .idle)
        var changed = RecorderShortcuts.defaults
        changed[.record] = combo(kVK_ANSI_9, controlKey | optionKey | cmdKey)
        hotkeys.update(shortcuts: changed, isEnabled: true, state: .idle)
        #expect(registrar.live.values.map(\.displayString) == ["⌃⌥⌘9"])
    }

    @Test func `a shortcut with a problem is never registered, even if it was stored`() {
        let registrar = FakeRegistrar()
        let hotkeys = RecorderHotkeys(registrar: registrar)
        var stored = RecorderShortcuts.defaults
        stored[.record] = combo(kVK_ANSI_4, shiftKey | cmdKey)
        hotkeys.update(shortcuts: stored, isEnabled: true, state: .idle)
        #expect(registrar.live.isEmpty)
    }

    @Test func `a key another app holds is reported, not retried every update`() {
        let registrar = FakeRegistrar()
        registrar.refuse = [RecorderShortcuts.defaults[.record]!]
        let hotkeys = RecorderHotkeys(registrar: registrar)
        hotkeys.update(shortcuts: .defaults, isEnabled: true, state: .idle)
        hotkeys.update(shortcuts: .defaults, isEnabled: true, state: .idle)
        #expect(hotkeys.refused.keys.contains(.record))
        #expect(registrar.attempts == 1)
    }

    @Test func `pressing a registered key performs its action`() {
        let registrar = FakeRegistrar()
        let hotkeys = RecorderHotkeys(registrar: registrar)
        var performed: [RecorderAction] = []
        hotkeys.perform = { performed.append($0) }
        hotkeys.update(shortcuts: .defaults, isEnabled: true, state: .recording(startedAt: started))
        registrar.press(RecorderHotkeys.id(for: .marker))
        registrar.press(RecorderHotkeys.id(for: .pause))
        #expect(performed == [.marker, .pause])
    }
}

/// Writes down what it is asked to register, and registers nothing.
@MainActor
final class FakeRegistrar: HotkeyRegistrar {
    var live: [UInt32: KeyCombo] = [:]
    var handlers: [UInt32: @MainActor () -> Void] = [:]
    var refuse: Set<KeyCombo> = []
    var attempts = 0
    var registrations = 0

    func register(_ combo: KeyCombo, id: UInt32, handler: @escaping @MainActor () -> Void) -> Bool {
        attempts += 1
        guard !refuse.contains(combo) else { return false }
        registrations += 1
        live[id] = combo
        handlers[id] = handler
        return true
    }

    func unregister(id: UInt32) {
        live[id] = nil
        handlers[id] = nil
    }

    func press(_ id: UInt32) { handlers[id]?() }
}
