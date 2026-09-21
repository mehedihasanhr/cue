import AppKit
import SwiftUI

// MARK: - Sections

/// The pages of the Settings window, in sidebar order.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, shortcuts, sharing, permissions, about
    case island, capture, editor, clipboard, time

    var id: String { rawValue }

    /// The sidebar shows the app-wide pages first, then a group per feature.
    static let groups: [[SettingsSection]] = [
        [.general, .shortcuts, .sharing, .permissions, .about],
        [.island, .capture, .editor, .clipboard, .time],
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .sharing: "Sharing"
        case .permissions: "Permissions"
        case .about: "About"
        case .island: "Island"
        case .capture: "Capture"
        case .editor: "Editor"
        case .clipboard: "Clipboard"
        case .time: "Time"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Appearance, startup, sync, the menu bar icon and where captures go"
        case .shortcuts: "The keys that reach Klik from any app"
        case .sharing: "Where Copy Share Link uploads captures"
        case .permissions: "What macOS lets Klik see and do"
        case .about: "Screenshots you can annotate, blur and share — built natively for macOS"
        case .island: "The Dynamic Island, panels, snippets and the color picker"
        case .capture: "The pointer and the sound after each capture"
        case .editor: "What every new annotation starts as"
        case .clipboard: "What Klik remembers of what you copy"
        case .time: "The time on the island and prayer times"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "command"
        case .sharing: "link"
        case .permissions: "lock.shield.fill"
        case .about: "info"
        case .island: "rectangle.topthird.inset.filled"
        case .capture: "camera.fill"
        case .editor: "paintbrush.pointed.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .time: "clock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .shortcuts: .indigo
        case .sharing: .blue
        case .permissions: .green
        case .about: .brand
        case .island: .brand
        case .capture: .orange
        case .editor: .purple
        case .clipboard: .teal
        case .time: .cyan
        }
    }

    /// What the sidebar search matches besides the title: the settings on the page.
    var keywords: [String] {
        switch self {
        case .general: ["appearance", "dark", "light", "theme", "login", "startup", "launch", "sync", "icloud", "dropbox", "folder", "menu bar", "icon", "storage", "pictures", "save"]
        case .shortcuts: ["hotkey", "keyboard", "keys", "global", "bindings", "record", "screenshot", "⌘"]
        case .sharing: ["upload", "s3", "r2", "bucket", "link", "url", "cloud", "endpoint", "custom", "keychain"]
        case .permissions: ["screen recording", "accessibility", "privacy", "access", "grant", "system settings"]
        case .about: ["version", "build", "credits", "stackrover", "copyright", "website"]
        case .island: ["dynamic island", "notch", "pill", "panel", "position", "snippets", "expand", "keyword", "trigger", "color", "picker", "format", "hex"]
        case .capture: ["cursor", "pointer", "mouse", "sound", "shutter", "audio", "full screen"]
        case .editor: ["annotation", "color", "stroke", "width", "shape", "arrow", "fill", "text", "font", "marker", "highlighter", "blur", "pixelate", "counter", "defaults"]
        case .clipboard: ["history", "copy", "paste", "limit", "items", "clear", "pinned"]
        case .time: ["clock", "hour", "prayer", "salah", "fajr", "dhuhr", "asr", "maghrib", "isha", "location", "latitude", "longitude", "method", "madhab", "announce"]
        }
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return title.lowercased().contains(needle)
            || subtitle.lowercased().contains(needle)
            || keywords.contains { $0.contains(needle) }
    }
}

// MARK: - Navigation

/// Which page is showing, the pages visited before it (for the back and forward
/// buttons) and what is in the search field — shared with the window controller
/// so a page can be asked for from outside (`present(.permissions)`).
@Observable
@MainActor
final class SettingsNavigation {
    private static let key = "settings.section"

    private(set) var history: [SettingsSection]
    private(set) var cursor = 0
    var query = ""

    init() {
        history = [SettingsSection(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .general]
    }

    var section: SettingsSection { history[cursor] }
    var canGoBack: Bool { cursor > 0 }
    var canGoForward: Bool { cursor < history.count - 1 }

    /// Shows `section`; going somewhere new drops the pages that were "forward".
    func go(_ section: SettingsSection) {
        guard section != self.section else { return }
        history = Array(history.prefix(cursor + 1)) + [section]
        cursor = history.count - 1
        remember()
    }

    func back() {
        guard canGoBack else { return }
        cursor -= 1
        remember()
    }

    func forward() {
        guard canGoForward else { return }
        cursor += 1
        remember()
    }

    private func remember() {
        UserDefaults.standard.set(section.rawValue, forKey: Self.key)
    }
}

// MARK: - Root

/// The Settings window's content: a sidebar card on the left (search on top, an
/// icon tile per page; the traffic lights sit inside it), the chosen page on the
/// right under a big header, with back and forward buttons over it.
struct SettingsRootView: View {
    @Environment(SettingsNavigation.self) private var navigation
    @Environment(ShareSettings.self) private var share: ShareSettings?

    static let sidebarWidth: CGFloat = 230
    /// How far the sidebar card sits in from the window's edges.
    static let inset: CGFloat = 10
    static let cardRadius: CGFloat = 16

    /// The card's fill: a shade lighter than the window in the dark, white-ish in the light.
    static let cardFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 1, alpha: 0.72)
    })

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(sections: sections)
                .frame(width: Self.sidebarWidth)
                .background(Self.cardFill, in: RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous).strokeBorder(.primary.opacity(0.08)))
                .padding([.leading, .top, .bottom], Self.inset)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) { HistoryButtons().padding(.top, Self.inset).padding(.leading, 12) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    /// The pages that apply — Sharing only when share settings are wired up.
    private var sections: [[SettingsSection]] {
        SettingsSection.groups.map { group in group.filter { $0 != .sharing || share != nil } }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.section {
        case .general: GeneralSettingsView()
        case .shortcuts: ShortcutSettingsView()
        case .sharing: ShareSettingsView()
        case .permissions: PermissionSettingsView()
        case .about: AboutSettingsView()
        case .island: IslandSettingsView()
        case .capture: CaptureSettingsView()
        case .editor: EditorSettingsView()
        case .clipboard: ClipboardSettingsView()
        case .time: TimeSettingsView()
        }
    }
}

/// Back and forward through the pages visited, in one pill (⌘[ and ⌘]).
private struct HistoryButtons: View {
    @Environment(SettingsNavigation.self) private var navigation

    var body: some View {
        HStack(spacing: 0) {
            button("chevron.left", help: "Back", enabled: navigation.canGoBack, key: "[") { navigation.back() }
            Divider().frame(height: 14)
            button("chevron.right", help: "Forward", enabled: navigation.canGoForward, key: "]") { navigation.forward() }
        }
        .frame(height: 30)
        .background(SettingsRootView.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }

    private func button(_ symbol: String, help: String, enabled: Bool, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? .primary : .quaternary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(key, modifiers: .command)
        .help("\(help) (⌘\(key.character))")
        .accessibilityLabel(help)
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    let sections: [[SettingsSection]]
    @Environment(SettingsNavigation.self) private var navigation
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                // Below the window's traffic lights, which sit inside the card.
                .padding(.top, 46)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { index, group in
                        if index > 0 { Spacer().frame(height: 16) }
                        ForEach(group) { section in
                            SidebarRow(section: section, selected: navigation.section == section) { navigation.go(section) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: navigation.query)
                        .scaleEffect(0.8)
                }
            }
        }
        .onChange(of: navigation.query) { _, _ in
            // Typing narrows the list; keep the page if it is still there, else
            // jump to the first match so the search lands somewhere.
            let visible = filtered.flatMap { $0 }
            if !visible.contains(navigation.section), let first = visible.first { navigation.go(first) }
        }
        .onExitCommand { navigation.query = ""; searching = false }
        .background {
            Button("") { searching = true }.keyboardShortcut("f").hidden()
        }
    }

    private var filtered: [[SettingsSection]] {
        sections.map { $0.filter { $0.matches(navigation.query) } }.filter { !$0.isEmpty }
    }

    private var searchField: some View {
        @Bindable var navigation = navigation
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13, weight: .semibold))
            TextField("Search settings…", text: $navigation.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searching)
            if !navigation.query.isEmpty {
                Button {
                    navigation.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.brand.opacity(searching ? 0.8 : 0), lineWidth: 1.5))
        .animation(.easeOut(duration: 0.12), value: searching)
        .help("Search settings (⌘F)")
    }
}

/// One page in the sidebar: its tile and name, lit when chosen, lightly under the pointer.
private struct SidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if section == .about {
                    AppIconTile(size: 22)
                } else {
                    SymbolTile(symbol: section.symbol, tint: section.tint, size: 22)
                }
                Text(section.title)
                    .font(.system(size: 14))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.primary.opacity(selected ? 0.1 : hovering ? 0.05 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Page chrome

/// A settings page: a grouped form under the page's icon, title and subtitle.
/// Every pane wraps its sections in one so they all look alike.
struct SettingsPane<Content: View>: View {
    let section: SettingsSection
    @ViewBuilder let content: Content

    init(_ section: SettingsSection, @ViewBuilder content: () -> Content) {
        self.section = section
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(section: section)
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }
}

private struct SettingsHeader: View {
    let section: SettingsSection

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if section == .about {
                    AppIconTile(size: 58)
                } else {
                    SymbolTile(symbol: section.symbol, tint: section.tint, size: 52)
                }
            }
            .shadow(color: section.tint.opacity(0.3), radius: 10, y: 5)
            .padding(.bottom, 10)
            Text(section.title)
                .font(.system(size: 26, weight: .bold))
            Text(section.subtitle)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        // Under the back/forward pill, then a little room before the form's inset.
        .padding(.top, 60)
        .padding(.bottom, 24)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The app icon in a tile, the size of a `SymbolTile`.
struct AppIconTile: View {
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            // The icon has its own rounded shape; a little larger so it lines up
            // with the symbol tiles' edges.
            .scaleEffect(1.12)
    }
}
