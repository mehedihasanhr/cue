import AppKit
import SwiftUI

/// Every command in the menu bar, found by typing part of its name.
///
/// Read from the menu bar itself rather than from a list of its own, so there is nothing
/// to keep in step: a command added to any menu is here the moment it exists, with the
/// shortcut it really has and the enabled state it really has. The menus stay where
/// commands are *learnt*; this is where they are *reached* — without knowing that "Speed
/// Up Waiting…" lives under Edit, or that "Clean Up Voice" is in Audio.
@MainActor
final class CommandMenuController: NSObject, NSWindowDelegate {
    static let shared = CommandMenuController()

    private var panel: CommandMenuPanel?

    func toggle() {
        if let panel, panel.isVisible { close(); return }
        show()
    }

    private func show() {
        guard let menu = NSApp.mainMenu else { return }
        let entries = CommandCatalog.entries(in: menu)
        let panel = CommandMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setAccessibilityLabel("Command Menu")
        panel.contentView = NSHostingView(rootView: CommandMenuView(
            entries: entries,
            perform: { [weak self] entry in self?.perform(entry) },
            dismiss: { [weak self] in self?.close() }))

        // Over whatever window was in front, a little above its middle — where a search
        // field is looked for.
        let anchor = NSApp.mainWindow?.frame ?? NSApp.keyWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: anchor.midX - panel.frame.width / 2,
                                     y: anchor.minY + anchor.height * 0.62 - panel.frame.height / 2))
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// After the panel has gone, so the command acts on the window it was meant for and a
    /// sheet it opens has that window to open on.
    private func perform(_ entry: CommandEntry) {
        close()
        guard let item = entry.item, let menu = item.menu else { return }
        let index = menu.index(of: item)
        guard index >= 0 else { return }
        DispatchQueue.main.async {
            menu.update()
            guard item.isEnabled else { return }
            menu.performActionForItem(at: index)
        }
    }

    /// Clicking anywhere else closes it, as a menu would.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// A panel that can take the keyboard without ever becoming the main window — so the
/// editor behind it stays the one the commands act on.
final class CommandMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One command, as the menu bar has it.
struct CommandEntry: Identifiable {
    let id: String
    let title: String
    /// The menus it is under, outermost first: ["Edit", "Add Annotation"].
    let path: [String]
    let shortcut: String
    let isEnabled: Bool
    weak var item: NSMenuItem?
}

@MainActor
enum CommandCatalog {
    /// The menus a command menu has no business offering: the app's own menu is quitting
    /// and hiding, and Window and Help are the system's.
    private static let skipped: Set<String> = ["Window", "Help"]

    static func entries(in bar: NSMenu) -> [CommandEntry] {
        var entries: [CommandEntry] = []
        for (index, top) in bar.items.enumerated() where index > 0 && !skipped.contains(top.title) {
            guard let menu = top.submenu else { continue }
            collect(menu, path: [top.title], into: &entries)
        }
        return entries
    }

    private static func collect(_ menu: NSMenu, path: [String], into entries: inout [CommandEntry]) {
        // Brought up to date first: SwiftUI works out enabled states when a menu is about
        // to open, and this is as good as opening it.
        menu.update()
        for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.title.isEmpty {
            if let submenu = item.submenu {
                collect(submenu, path: path + [item.title], into: &entries)
                continue
            }
            entries.append(CommandEntry(id: (path + [item.title]).joined(separator: "›") + "#\(entries.count)",
                                        title: item.title,
                                        path: path,
                                        shortcut: shortcut(of: item),
                                        isEnabled: item.isEnabled,
                                        item: item))
        }
    }

    static func shortcut(of item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        let key = item.keyEquivalent
        // AppKit spells ⇧ into the key itself when it is a capital letter.
        if flags.contains(.shift) || (key.count == 1 && key != key.lowercased()) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + CommandSearch.keyName(key)
    }
}

/// How typed words find commands. Kept free of AppKit so the rule can be read on its own.
enum CommandSearch {
    /// How well `query` matches a command, or `nil` when it does not.
    ///
    /// Every word typed has to be found, each at the start of a word of the title or of
    /// one of its menus; a title that begins with what was typed ranks first, then titles
    /// that contain every word, then commands found only through their menu's name. Failing
    /// all that, the letters in order anywhere in the title ("spw" for "Speed Up
    /// Waiting…") still count, last.
    static func score(_ query: String, title: String, path: [String]) -> Int? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 0 }
        let titleText = title.lowercased()
        let titleWords = splitWords(titleText)
        let pathWords = path.flatMap { splitWords($0.lowercased()) }

        if titleText.hasPrefix(words.joined(separator: " ")) { return 400 - title.count }
        if words.allSatisfy({ word in titleWords.contains { $0.hasPrefix(word) } }) { return 300 - title.count }
        if words.allSatisfy({ word in (titleWords + pathWords).contains { $0.hasPrefix(word) } }) { return 200 - title.count }
        if isSubsequence(words.joined(), of: titleText) { return 100 - title.count }
        return nil
    }

    static func splitWords(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle[...]
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }

    static func keyName(_ key: String) -> String {
        switch key.unicodeScalars.first.map({ Int($0.value) }) {
        case 0x08, 0x7F: "⌫"
        case 0x0D: "↩"
        case 0x1B: "⎋"
        case 0x20: "Space"
        case 0x09: "⇥"
        case NSLeftArrowFunctionKey: "←"
        case NSRightArrowFunctionKey: "→"
        case NSUpArrowFunctionKey: "↑"
        case NSDownArrowFunctionKey: "↓"
        default: key.uppercased()
        }
    }
}

struct CommandMenuView: View {
    let entries: [CommandEntry]
    let perform: (CommandEntry) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searching: Bool

    private var matches: [CommandEntry] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return entries.filter(\.isEnabled)
        }
        return entries
            .compactMap { entry in
                CommandSearch.score(query, title: entry.title, path: entry.path).map { (entry, $0) }
            }
            // Enabled ones first: a command that cannot run now is still worth finding —
            // it says the command exists — but not ahead of one that can.
            .sorted { ($0.0.isEnabled ? 1 : 0, $0.1) > ($1.0.isEnabled ? 1 : 0, $1.1) }
            .map(\.0)
    }

    var body: some View {
        let found = matches
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($searching)
                    .onSubmit { run(found) }
                    .onKeyPress(.downArrow) { move(1, in: found); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: found); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .accessibilityLabel("Search commands")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()
            if found.isEmpty {
                Text("No command called “\(query)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(found.enumerated()), id: \.element.id) { index, entry in
                                row(entry, isHighlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture { if entry.isEnabled { perform(entry) } }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: highlighted) { _, index in scroller.scrollTo(index) }
                }
            }
        }
        .frame(width: 560, height: 380)
        .onAppear { searching = true }
        .onChange(of: query) { highlighted = 0 }
    }

    private func row(_ entry: CommandEntry, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                Text(entry.path.joined(separator: " › "))
                    .font(.system(size: 11))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            Spacer()
            if !entry.shortcut.isEmpty {
                Text(entry.shortcut)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .opacity(entry.isEnabled ? 1 : 0.45)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title), \(entry.path.joined(separator: ", "))\(entry.isEnabled ? "" : ", unavailable")")
    }

    private func move(_ step: Int, in found: [CommandEntry]) {
        guard !found.isEmpty else { return }
        highlighted = min(max(highlighted + step, 0), found.count - 1)
    }

    private func run(_ found: [CommandEntry]) {
        guard found.indices.contains(highlighted), found[highlighted].isEnabled else { return }
        perform(found[highlighted])
    }
}
