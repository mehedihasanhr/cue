import AppKit
import Foundation
import Observation
import os

/// Owns the user's shortcut bindings: persistence, registration with the OS,
/// and status reporting for the Settings UI.
@Observable
final class ShortcutController {
    enum Status: Equatable {
        case active
        /// Registered, but macOS's own screenshot shortcut handles the keypress first.
        case reservedByMacOS
        /// Another app already owns this combination.
        case conflict
        case failed
        case unassigned
    }

    struct Entry: Equatable {
        var hotkey: Hotkey?
        var status: Status
    }

    private(set) var entries: [HotkeyID: Entry] = [:]

    /// While a recorder control has focus, global shortcuts are suspended so the
    /// keystroke being recorded doesn't trigger a capture.
    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            if isRecording { suspendAll() } else { registerAll() }
        }
    }

    private let manager = HotkeyManager()
    private let defaults = UserDefaults.standard
    private var actions: [HotkeyID: () -> Void] = [:]

    init() {
        for id in HotkeyID.configurable {
            entries[id] = Entry(hotkey: storedHotkey(for: id), status: .unassigned)
        }
    }

    // MARK: - Actions

    func setAction(for id: HotkeyID, _ action: @escaping () -> Void) {
        actions[id] = action
        register(id)
    }

    func hotkey(for id: HotkeyID) -> Hotkey? {
        entries[id]?.hotkey
    }

    /// Binds `hotkey` to `id`, unbinding it from any other action first. `nil` clears the binding.
    func set(_ hotkey: Hotkey?, for id: HotkeyID) {
        if let hotkey {
            for (otherID, entry) in entries where otherID != id && entry.hotkey == hotkey {
                entries[otherID]?.hotkey = nil
                store(nil, for: otherID)
                register(otherID)
            }
        }
        entries[id, default: Entry(hotkey: nil, status: .unassigned)].hotkey = hotkey
        store(hotkey, for: id)
        register(id)
    }

    func restoreDefaults() {
        for id in HotkeyID.configurable {
            defaults.removeObject(forKey: id.defaultsKey)
            entries[id]?.hotkey = id.defaultHotkey
            register(id)
        }
    }

    // MARK: - Temporary shortcuts

    /// Registers a shortcut that lives only as long as the returned token, e.g. ⎋ during a
    /// scrolling capture. The token unregisters on deinit.
    func registerTemporary(_ hotkey: Hotkey, id: HotkeyID, action: @escaping () -> Void) -> TemporaryShortcut {
        do {
            try manager.register(hotkey, id: id, action: action)
        } catch {
            Log.hotkey.error("Temporary shortcut \(hotkey.displayString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        return TemporaryShortcut { [manager] in manager.unregister(id) }
    }

    final class TemporaryShortcut {
        private let cleanup: () -> Void
        init(cleanup: @escaping () -> Void) { self.cleanup = cleanup }
        isolated deinit { cleanup() }
    }

    // MARK: - Registration

    private func register(_ id: HotkeyID) {
        manager.unregister(id)
        guard let hotkey = entries[id]?.hotkey else {
            entries[id]?.status = .unassigned
            return
        }
        guard let action = actions[id], !isRecording else { return }
        do {
            try manager.register(hotkey, id: id, action: action)
            entries[id]?.status = hotkey.isReservedByMacOS ? .reservedByMacOS : .active
        } catch .alreadyInUse {
            entries[id]?.status = .conflict
        } catch {
            entries[id]?.status = .failed
        }
    }

    private func registerAll() {
        for id in HotkeyID.configurable { register(id) }
    }

    private func suspendAll() {
        for id in HotkeyID.configurable { manager.unregister(id) }
    }

    // MARK: - Persistence

    /// Stored as JSON; an empty value means "deliberately unassigned", absence means "default".
    private func storedHotkey(for id: HotkeyID) -> Hotkey? {
        guard let data = defaults.data(forKey: id.defaultsKey) else { return id.defaultHotkey }
        guard !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(Hotkey.self, from: data)) ?? id.defaultHotkey
    }

    private func store(_ hotkey: Hotkey?, for id: HotkeyID) {
        if let hotkey, let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: id.defaultsKey)
        } else {
            defaults.set(Data(), forKey: id.defaultsKey)
        }
        Log.hotkey.info("Stored \(hotkey?.displayString ?? "none", privacy: .public) for \(String(describing: id), privacy: .public)")
    }
}
