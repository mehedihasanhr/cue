import AppKit
import SwiftUI

// MARK: - Sections

/// The pages of the Settings window, in sidebar order.
enum StudioSettingsSection: String, CaseIterable, Identifiable {
    case general, recording, shortcuts
    case editor, captions, audio, export
    case storage, about

    var id: String { rawValue }

    /// The sidebar shows the app itself first, then what happens to a recording from
    /// the editor on, then the housekeeping.
    static let groups: [[StudioSettingsSection]] = [
        [.general, .recording, .shortcuts],
        [.editor, .captions, .audio, .export],
        [.storage, .about],
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .shortcuts: "Shortcuts"
        case .editor: "Editor"
        case .captions: "Captions"
        case .audio: "Audio"
        case .export: "Export"
        case .storage: "Storage"
        case .about: "About"
        }
    }

    /// What the sidebar search matches besides the title and keywords.
    var subtitle: String {
        switch self {
        case .general: "Where recordings go, the Dock, the menu bar and the theme"
        case .recording: "What a take records, and what is on screen while it does"
        case .shortcuts: "The recorder\u{2019}s keys from any app, and the editor\u{2019}s menu shortcuts"
        case .editor: "Saving, auto-zoom, and how a new recording looks"
        case .captions: "The language listened for, and how new captions look"
        case .audio: "Voice clean-up, click sounds and the preview"
        case .export: "What the export sheet starts with, and what happens after"
        case .storage: "Disk space, caches, and starting over"
        case .about: "The recording add-on for Klik"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .recording: "record.circle.fill"
        case .shortcuts: "command"
        case .editor: "wand.and.stars"
        case .captions: "captions.bubble.fill"
        case .audio: "waveform"
        case .export: "square.and.arrow.up.fill"
        case .storage: "internaldrive.fill"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .recording: .red
        case .shortcuts: .indigo
        case .editor: .purple
        case .captions: .orange
        case .audio: .pink
        case .export: .blue
        case .storage: .teal
        case .about: StudioPalette.brand
        }
    }

    /// What the sidebar search matches besides the title: the settings on the page.
    var keywords: [String] {
        switch self {
        case .general: ["folder", "library", "save", "location", "dock", "menu bar", "icon", "appearance", "theme", "dark", "light", "login", "launch", "startup", "open editor"]
        case .recording: ["countdown", "frame rate", "fps", "quality", "encoder", "hevc", "h.264", "codec", "pointer", "cursor", "clicks", "focus", "keyboard", "keys", "keystrokes", "accessibility", "privacy", "microphone", "mic", "system audio", "camera", "webcam", "desktop icons", "speaker notes", "restart", "confirm"]
        case .shortcuts: ["hotkey", "keyboard", "global", "record", "pause", "restart", "marker", "conflict", "editor", "menu", "key equivalent", "rebind", "undo", "play", "split", "zoom"]
        case .editor: ["autosave", "save", "look", "background", "padding", "corners", "shadow", "blur", "zoom", "auto-zoom", "scale", "pointer", "cursor", "size", "smoothing", "click", "ring", "ripple", "idle", "motion blur"]
        case .captions: ["language", "transcribe", "subtitles", "position", "typeface", "font", "animation", "highlight", "backdrop"]
        case .audio: ["voice", "clean up", "noise", "even out", "loudness", "volume", "click sound", "preview", "voiceover", "count in", "mute"]
        case .export: ["format", "mp4", "mov", "prores", "gif", "quality", "frame rate", "size", "resolution", "1080p", "4k", "codec", "sound", "loop", "folder", "reveal", "finder", "open"]
        case .storage: ["disk", "space", "free", "cache", "waveform", "thumbnail", "poster", "clear", "reset", "defaults"]
        case .about: ["version", "contract", "klik", "connection", "bridge", "build"]
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

/// Which page is showing, the pages visited before it (for the back and forward buttons)
/// and what is in the search field — shared with the window controller, so a page can be
/// asked for from outside.
@Observable
@MainActor
final class StudioSettingsNavigation {
    private static let key = "settings.section"

    private(set) var history: [StudioSettingsSection]
    private(set) var cursor = 0
    var query = ""

    init() {
        history = [StudioSettingsSection(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .general]
    }

    var section: StudioSettingsSection { history[cursor] }
    var canGoBack: Bool { cursor > 0 }
    var canGoForward: Bool { cursor < history.count - 1 }

    /// Shows `section`; going somewhere new drops the pages that were "forward".
    func go(_ section: StudioSettingsSection) {
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

/// Close, minimise and zoom, supplied by the window controller to the lights the sidebar
/// draws.
struct SettingsWindowButtons {
    var close: () -> Void
    var minimize: () -> Void
    var zoom: () -> Void
}

// MARK: - Root

/// The Settings window's content: a sidebar card on the left (search on top, an icon tile
/// per page, the traffic lights inside it), the chosen page on the right with back and
/// forward buttons over it. The whole window is glass with a 24 pt corner — Klik's
/// settings, page for page.
struct StudioSettingsRootView: View {
    let buttons: SettingsWindowButtons
    @Environment(StudioSettingsNavigation.self) private var navigation

    static let sidebarWidth: CGFloat = 225
    /// How far the sidebar card sits in from the window's edges.
    static let inset: CGFloat = 8
    static let windowRadius: CGFloat = 24
    static let cardRadius: CGFloat = 16

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(buttons: buttons)
                .frame(width: Self.sidebarWidth)
                .background { GlassCard(radius: Self.cardRadius) }
                .padding([.leading, .top, .bottom], Self.inset)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) { HistoryButtons().padding(.top, 15).padding(.leading, 10) }
        }
        .background {
            // The desktop, blurred and darkened almost to a flat colour.
            ZStack {
                GlassMaterial()
                SettingsPalette.page
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.windowRadius, style: .continuous))
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.section {
        case .general: GeneralSettingsPane()
        case .recording: RecordingSettingsPane()
        case .shortcuts: ShortcutSettingsPane()
        case .editor: EditorSettingsPane()
        case .captions: CaptionSettingsPane()
        case .audio: AudioSettingsPane()
        case .export: ExportSettingsPane()
        case .storage: StorageSettingsPane()
        case .about: AboutSettingsPane()
        }
    }
}

/// Back and forward through the pages visited, in one pill (⌘[ and ⌘]).
private struct HistoryButtons: View {
    @Environment(StudioSettingsNavigation.self) private var navigation

    var body: some View {
        HStack(spacing: 0) {
            button("chevron.left", help: "Back", enabled: navigation.canGoBack, key: "[") { navigation.back() }
            Divider().frame(height: 14)
            button("chevron.right", help: "Forward", enabled: navigation.canGoForward, key: "]") { navigation.forward() }
        }
        .frame(height: 30)
        .background(SettingsPalette.pill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SettingsPalette.edge))
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
        .help("\(help) (⌘\(String(key.character)))")
        .accessibilityLabel(help)
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    let buttons: SettingsWindowButtons
    @Environment(StudioSettingsNavigation.self) private var navigation
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.leading, 10)
                .padding(.trailing, 8)
                // Below the traffic lights, which sit inside the card.
                .padding(.top, 48)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { index, group in
                        if index > 0 { Spacer().frame(height: 14) }
                        ForEach(group) { section in
                            SidebarRow(section: section, selected: navigation.section == section) { navigation.go(section) }
                        }
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
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
            // Typing narrows the list; keep the page if it is still there, else jump to
            // the first match so the search lands somewhere.
            let visible = filtered.flatMap { $0 }
            if !visible.contains(navigation.section), let first = visible.first { navigation.go(first) }
        }
        .onExitCommand { navigation.query = ""; searching = false }
        .background {
            Button("") { searching = true }.keyboardShortcut("f").hidden()
        }
        .overlay(alignment: .topLeading) {
            // Drawn here rather than the system's, which sit where the card wants them.
            SettingsTrafficLights(buttons: buttons)
                .padding(.top, 6)
                .padding(.leading, 6)
        }
    }

    private var filtered: [[StudioSettingsSection]] {
        StudioSettingsSection.groups.map { $0.filter { $0.matches(navigation.query) } }.filter { !$0.isEmpty }
    }

    private var searchField: some View {
        @Bindable var navigation = navigation
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13, weight: .semibold))
            TextField("Search settings…", text: $navigation.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
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
        .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioPalette.brand.opacity(searching ? 0.8 : 0), lineWidth: 1.5))
        .animation(.easeOut(duration: 0.12), value: searching)
        .help("Search settings (⌘F)")
    }
}

/// One page in the sidebar: its tile and name, lit when chosen, lightly under the pointer.
private struct SidebarRow: View {
    let section: StudioSettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if section == .about {
                        AppIconTile(size: 22)
                    } else {
                        SymbolTile(symbol: section.symbol, tint: section.tint, size: 22)
                    }
                }
                // Toned down: the tiles are signposts, not the point of the page.
                .saturation(0.8)
                .brightness(-0.08)
                Text(section.title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? SettingsPalette.selectedRow : hovering ? SettingsPalette.hoveredRow : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Close, minimise and zoom, drawn inside the sidebar card with the system's colours,
/// sizes and hover glyphs — the system's own are hidden, because they are pinned to the
/// title bar's height and the card wants them lower.
private struct SettingsTrafficLights: View {
    let buttons: SettingsWindowButtons

    @Environment(\.controlActiveState) private var activeState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            light(Color(red: 1, green: 0.373, blue: 0.341), glyph: "xmark", name: "Close", action: buttons.close)
            light(Color(red: 0.996, green: 0.737, blue: 0.18), glyph: "minus", name: "Minimize", action: buttons.minimize)
            light(Color(red: 0.157, green: 0.784, blue: 0.251), glyph: "arrow.up.left.and.arrow.down.right", name: "Zoom", action: buttons.zoom)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, glyph: String, name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(activeState == .inactive && !hovering ? Color.primary.opacity(0.18) : color)
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                if hovering {
                    Image(systemName: glyph)
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.black.opacity(0.6))
                }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

// MARK: - The window

/// The Settings window, built the way Klik builds its own: an AppKit window whose title
/// bar is transparent so the sidebar runs to the top, which remembers its size and the
/// last page.
///
/// An `NSWindowController` rather than SwiftUI's `Settings` scene, because that scene
/// fixes the window's size, draws a title bar over the sidebar and cannot be made
/// resizable — the three things that make Klik's settings look the way they do. It is
/// made the first time somebody asks for it and kept, for the reason
/// `LibraryWindowController` gives.
@MainActor
final class StudioSettingsWindowController: NSWindowController {
    private let navigation = StudioSettingsNavigation()

    static let size = CGSize(width: 920, height: 640)
    static let minimumSize = CGSize(width: 820, height: 540)

    /// `recorder` is the bar's model, when there is a bar: the camera switch goes through
    /// it so the permission is asked for the way the bar asks.
    init(settings: StudioSettings, studio: StudioService, recorder: RecorderModel?) {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        let buttons = SettingsWindowButtons(close: { [weak window] in window?.performClose(nil) },
                                            minimize: { [weak window] in window?.miniaturize(nil) },
                                            zoom: { [weak window] in window?.zoom(nil) })
        let root = StudioSettingsRootView(buttons: buttons)
            .environment(navigation)
            .environment(settings)
            .environment(studio)
            .environment(recorder)
            .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)

        let hosting = NSHostingController(rootView: root)
        // The window's size is the window's business — the same reason the editor and
        // Recordings say so. Left to SwiftUI, every page would resize it to fit.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.title = "Klik Studio Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The content draws the window: glass with a 24 pt corner, and its own traffic
        // lights inside the sidebar card, so the system's are hidden.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Settings is somewhere you go; macOS must not bring it back by itself at launch.
        window.isRestorable = false
        window.contentMinSize = Self.minimumSize
        window.setContentSize(Self.size)
        window.center()
        window.setFrameAutosaveName("KlikStudioSettings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Opens in front and takes focus — or, under automation, behind everything. With a
    /// `section`, that page is shown.
    func present(_ section: StudioSettingsSection? = nil) {
        if let section { navigation.go(section) }
        StudioAutomation.present(self)
        // The search field would take focus as the first field; the page reads better
        // without a caret in it.
        window?.makeFirstResponder(nil)
    }
}
