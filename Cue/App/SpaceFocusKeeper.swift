import AppKit

/// Gives Cue's windows the keyboard back when the user returns to their Space.
///
/// macOS remembers which app was in front on each Space and brings it back on the way
/// in — but not a menu bar app's: come back to the Space where the Tasks window was
/// being typed in, and whichever other app was there takes the front instead. So Cue
/// remembers for itself. When the user leaves a Space while a Cue window has the
/// keyboard, that window is noted; when its Space comes back, Cue comes forward and the
/// window takes the keyboard again. A Space left with another app in front is left
/// alone, as macOS would leave it.
///
/// Ordinary windows only: the floating task and note panels follow their own rule
/// (`QuickTaskPanel`), and the island never takes the keyboard to begin with.
@MainActor
final class SpaceFocusKeeper {
    /// The Cue window that last had the keyboard.
    private weak var lastKey: NSWindow?
    /// When Cue last stopped being the active app. A Space switch takes the front away
    /// a moment before it is announced, so "Cue was in front" means "until just now".
    private var resignedActiveAt: Date?
    /// The window to give the keyboard back to when its Space returns.
    private weak var pending: NSWindow?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    func start() {
        let center = NotificationCenter.default
        observe(center, NSWindow.didBecomeKeyNotification) { [weak self] note in
            guard let window = note.object as? NSWindow, !(window is NSPanel) else { return }
            self?.lastKey = window
        }
        observe(center, NSApplication.didResignActiveNotification) { [weak self] _ in
            self?.resignedActiveAt = Date()
        }
        // Brought forward some other way (clicked, a shortcut): nothing left to restore.
        observe(center, NSApplication.didBecomeActiveNotification) { [weak self] _ in
            self?.pending = nil
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            self?.spaceChanged()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handle: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            // Delivered on the main queue, so the note never leaves the main thread.
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated { handle(note) }
        }
        observers.append((center, token))
    }

    private func spaceChanged() {
        if let window = pending, window.isVisible, window.isOnActiveSpace {
            pending = nil
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Leaving the Space of the window in use: remember to come back to it.
        guard let window = lastKey, window.isVisible, !window.isOnActiveSpace else { return }
        let wasInFront = NSApp.isActive || resignedActiveAt.map { Date().timeIntervalSince($0) < 1 } == true
        if wasInFront { pending = window }
    }
}
