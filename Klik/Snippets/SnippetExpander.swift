import AppKit
import Carbon.HIToolbox
import os

/// Watches what is typed in any app (with Accessibility access) and, when the last
/// keystrokes spell a snippet's keyword, deletes the keyword and pastes the snippet
/// in its place — asking for the `{{blanks}}` first when the template has any.
@MainActor
final class SnippetExpander {
    private let store: SnippetStore
    private let assets: AssetStore
    private let preferences: AppPreferences
    /// Asks the user to fill a snippet's blanks (where the cursor was is passed along
    /// so the paste can go back there); the answer comes back through `paste`.
    var askToFill: (Snippet, FrontField) -> Void = { _, _ in }

    private var monitors: [Any] = []
    /// The last few characters typed, at most the longest keyword.
    private var typed = ""
    /// Set while a keyword is being replaced, so the paste's own keystrokes are ignored.
    private var expanding = false

    init(store: SnippetStore, assets: AssetStore, preferences: AppPreferences) {
        self.store = store
        self.assets = assets
        self.preferences = preferences
        apply()
    }

    /// Starts or stops watching as the setting changes.
    func apply() {
        let enabled = withObservationTracking {
            preferences.snippetsEnabled
        } onChange: { [weak self] in
            Task { @MainActor in self?.apply() }
        }
        if enabled { start() } else { stop() }
    }

    var isWatching: Bool { !monitors.isEmpty }

    private func start() {
        guard monitors.isEmpty else { return }
        guard PermissionManager.hasAccessibilityAccess else {
            Log.app.info("Snippets: no Accessibility access, not watching")
            return
        }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.keyDown(event) }
        }
        // A click moves the caret: whatever was typed before is no longer "before".
        let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.typed = "" }
        }
        monitors = [keys, clicks].compactMap { $0 }
        Log.app.info("Snippets: watching")
    }

    private func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        typed = ""
    }

    private var loggedFirstKey = false

    private func keyDown(_ event: NSEvent) {
        if !loggedFirstKey {
            loggedFirstKey = true
            Log.app.info("Snippets: first keystroke seen")
        }
        // Cheapest checks first: this runs for every keystroke on the Mac.
        guard !expanding, store.longestKeyword > 0, NSApp.keyWindow == nil else { return } // not while typing into Klik itself
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { typed = ""; return }
        switch Int(event.keyCode) {
        case kVK_Delete:
            if !typed.isEmpty { typed.removeLast() }
            return
        case kVK_Return, kVK_Tab, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End:
            typed = ""
            return
        default:
            break
        }
        guard let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
        typed += characters
        let keep = store.longestKeyword
        if typed.count > keep { typed = String(typed.suffix(keep)) }
        guard let snippet = store.match(endOf: typed) else { return }
        typed = ""
        Log.app.info("Snippets: expanding \(snippet.keyword, privacy: .public)")
        expand(snippet)
    }

    /// Replaces the keyword just typed: fills the blanks first when there are any.
    private func expand(_ snippet: Snippet) {
        expanding = true
        // The keyword is erased one backspace at a time, spaced out: posted in one
        // burst from inside the key monitor they arrive before the app has taken the
        // keystroke that completed the keyword, and some go missing.
        Self.erase(characters: snippet.keyword.count) { [weak self] in
            guard let self else { return }
            if snippet.placeholders.isEmpty {
                paste(snippet, values: [:])
            } else {
                expanding = false
                askToFill(snippet, FrontField.capture())
            }
        }
    }

    /// Backspaces `count` times, a few milliseconds apart, then calls `done`.
    private static func erase(characters count: Int, then done: @escaping @MainActor () -> Void) {
        guard count > 0 else { done(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            press(kVK_Delete, times: 1)
            erase(characters: count - 1, then: done)
        }
    }

    /// Pastes the snippet where the caret is: the pasteboard takes the expansion, ⌘V
    /// goes to the front app, and what was on the pasteboard before comes back.
    func paste(_ snippet: Snippet, values: [String: String], returningTo field: FrontField? = nil) {
        expanding = true
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        let clipboardText = pasteboard.string(forType: .string)

        if let assetID = snippet.assetID, let asset = assets.items.first(where: { $0.id == assetID }) {
            assets.copy(asset)
        } else {
            let expanded = SnippetTemplate.expand(snippet.text, values: values, clipboard: clipboardText)
            pasteboard.clearContents()
            pasteboard.setString(expanded, forType: .string)
        }
        pasteboard.setData(Data(), forType: Clipboard.ownMarker) // the history need not record the expansion
        store.recordUse(snippet)

        ClipboardHistory.pressCommandV(returningTo: field)
        DispatchQueue.main.asyncAfter(deadline: .now() + (field == nil ? 0.4 : 1.6)) { [weak self] in
            if !previous.isEmpty {
                pasteboard.clearContents()
                pasteboard.writeObjects(previous)
            }
            self?.expanding = false
        }
    }

    private static func press(_ key: Int, times: Int, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<times {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
