import AppKit
import SwiftUI

// MARK: - Sections

/// The pages of the Settings window, in sidebar order.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, shortcuts, sharing, permissions, about
    case island, capture, editor, clipboard, snippets, colors, time

    var id: String { rawValue }

    /// The sidebar shows the app-wide pages first, then a group per feature.
    static let groups: [[SettingsSection]] = [
        [.general, .appearance, .shortcuts, .sharing, .permissions, .about],
        [.island, .capture, .editor, .clipboard, .snippets, .colors, .time],
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .shortcuts: "Shortcuts"
        case .sharing: "Sharing"
        case .permissions: "Permissions"
        case .about: "About"
        case .island: "Island"
        case .capture: "Capture"
        case .editor: "Editor"
        case .clipboard: "Clipboard"
        case .snippets: "Snippets"
        case .colors: "Colors"
        case .time: "Time"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup, sync, the menu bar icon and where captures go"
        case .appearance: "The theme, in the editor, the panels and this window"
        case .shortcuts: "The keys that reach Klik from any app"
        case .sharing: "Where Copy Share Link uploads captures"
        case .permissions: "What macOS lets Klik see and do"
        case .about: "Screenshots you can annotate, blur and share — built natively for macOS"
        case .island: "How the Dynamic Island opens, closes, looks and moves"
        case .capture: "The pointer and the sound after each capture"
        case .editor: "What every new annotation starts as"
        case .clipboard: "What Klik remembers of what you copy"
        case .snippets: "Text that expands as you type"
        case .colors: "The color picker and its formats"
        case .time: "The time on the island and prayer times"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .shortcuts: "command"
        case .sharing: "link"
        case .permissions: "lock.shield.fill"
        case .about: "info"
        case .island: "rectangle.topthird.inset.filled"
        case .capture: "camera.fill"
        case .editor: "paintbrush.pointed.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .snippets: "text.badge.checkmark"
        case .colors: "eyedropper.halffull"
        case .time: "clock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: Color(red: 0.75, green: 0.3, blue: 0.5)
        case .shortcuts: .indigo
        case .sharing: .blue
        case .permissions: .green
        case .about: .brand
        case .island: .brand
        case .capture: .orange
        case .editor: .purple
        case .clipboard: .teal
        case .snippets: .mint
        case .colors: .red
        case .time: .cyan
        }
    }

    /// What the sidebar search matches besides the title: the settings on the page.
    var keywords: [String] {
        switch self {
        case .general: ["login", "startup", "launch", "sync", "icloud", "dropbox", "folder", "menu bar", "icon", "storage", "pictures", "save"]
        case .appearance: ["theme", "dark", "light", "system", "mode", "look"]
        case .shortcuts: ["hotkey", "keyboard", "keys", "global", "bindings", "record", "screenshot", "⌘"]
        case .sharing: ["upload", "s3", "r2", "bucket", "link", "url", "cloud", "endpoint", "custom", "keychain"]
        case .permissions: ["screen recording", "accessibility", "privacy", "access", "grant", "system settings"]
        case .about: ["version", "build", "credits", "stackrover", "copyright", "website"]
        case .island: ["dynamic island", "notch", "pill", "panel", "position", "hover", "click", "delay", "open", "close", "background", "flash", "status", "animation", "tab"]
        case .snippets: ["snippet", "expand", "keyword", "trigger", "text", "type", "accessibility"]
        case .colors: ["color", "picker", "format", "hex", "rgb", "hsl", "swift", "css"]
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
/// right under a big header, with back and forward buttons over it. The whole
/// window is glass — the desktop shows faintly through — with a 24 pt corner.
struct SettingsRootView: View {
    let buttons: WindowButtons
    @Environment(SettingsNavigation.self) private var navigation
    @Environment(ShareSettings.self) private var share: ShareSettings?

    static let sidebarWidth: CGFloat = 225
    /// How far the sidebar card sits in from the window's edges.
    static let inset: CGFloat = 8
    static let windowRadius: CGFloat = 24
    static let cardRadius: CGFloat = 16

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(sections: sections, buttons: buttons)
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

    /// The pages that apply — Sharing only when share settings are wired up.
    private var sections: [[SettingsSection]] {
        SettingsSection.groups.map { group in group.filter { $0 != .sharing || share != nil } }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.section {
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .shortcuts: ShortcutSettingsView()
        case .sharing: ShareSettingsView()
        case .permissions: PermissionSettingsView()
        case .about: AboutSettingsView()
        case .island: IslandSettingsView()
        case .capture: CaptureSettingsView()
        case .editor: EditorSettingsView()
        case .clipboard: ClipboardSettingsView()
        case .snippets: SnippetSettingsView()
        case .colors: ColorSettingsView()
        case .time: TimeSettingsView()
        }
    }
}

// MARK: - Glass

/// The window's colours, measured off Raycast's settings: a near-black page, a
/// card a shade lighter with the desktop's tint, fills as fractions of white.
enum SettingsPalette {
    /// Over the glass: almost opaque, so the desktop only just shows (lands on
    /// #181919 over a typical desktop).
    static let page = Color(nsColor: dynamic(dark: NSColor(red: 0x10 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 0.94),
                                             light: NSColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255, alpha: 0.9)))
    /// Over the card's glass, which is left to show more of the desktop (about
    /// #1E2325: a shade lighter than the page, with the desktop's tint).
    static let card = Color(nsColor: dynamic(dark: NSColor(red: 0x0F / 255, green: 0x12 / 255, blue: 0x13 / 255, alpha: 0.79),
                                             light: NSColor(white: 1, alpha: 0.6)))
    static let field = Color.primary.opacity(0.11)
    static let selectedRow = Color.primary.opacity(0.12)
    static let hoveredRow = Color.primary.opacity(0.06)
    static let pill = Color.primary.opacity(0.08)
    static let edge = Color.primary.opacity(0.07)
    /// The cards on a page and the lines between their rows.
    static let cardFill = Color.primary.opacity(0.03)
    static let hairline = Color.primary.opacity(0.05)

    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}

/// The desktop behind the window, blurred — the base of every glass surface.
struct GlassMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// A rounded pane of glass: blurred desktop, a light tint, a grain of noise, and
/// an edge that catches the light at the top-left.
struct GlassCard: View {
    var radius: CGFloat

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    private var edge: LinearGradient {
        LinearGradient(colors: [Color.primary.opacity(0.11), Color.primary.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            GlassMaterial()
            SettingsPalette.card
            NoiseTexture.image
                .resizable(resizingMode: .tile)
                .opacity(0.008)
                .blendMode(.plusLighter)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(edge, lineWidth: 1))
    }
}

/// A small tile of random grey, made once; tiled over glass it reads as grain.
enum NoiseTexture {
    static let image: Image = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side)
        var state: UInt32 = 0x9E37_79B9
        for i in pixels.indices {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            pixels[i] = UInt8(truncatingIfNeeded: state)
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            return Image(systemName: "square")
        }
        return Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: side, height: side)))
    }()
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
        .help("\(help) (⌘\(key.character))")
        .accessibilityLabel(help)
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    let sections: [[SettingsSection]]
    let buttons: WindowButtons
    @Environment(SettingsNavigation.self) private var navigation
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
            // Typing narrows the list; keep the page if it is still there, else
            // jump to the first match so the search lands somewhere.
            let visible = filtered.flatMap { $0 }
            if !visible.contains(navigation.section), let first = visible.first { navigation.go(first) }
        }
        .onExitCommand { navigation.query = ""; searching = false }
        .background {
            Button("") { searching = true }.keyboardShortcut("f").hidden()
        }
        .overlay(alignment: .topLeading) {
            // The editor's lights, which sit where the card wants them (the system's are hidden).
            TrafficLights(onClose: buttons.close, onMinimize: buttons.minimize, onZoom: buttons.zoom)
                .padding(.top, 6)
                .padding(.leading, 6)
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
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.brand.opacity(searching ? 0.8 : 0), lineWidth: 1.5))
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
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Page chrome

/// The type hierarchy of a page: a group's title, a row's title, what it
/// does, and a note under a card.
enum SettingsFont {
    static let title = Font.system(size: 14)
    static let item = Font.system(size: 13)
    static let sub = Font.system(size: 11)
    static let note = Font.system(size: 9)
}

/// A settings page: groups of rows, top to bottom, starting under the history
/// pill. Every pane builds on these so the pages all look alike.
struct SettingsPane<Content: View>: View {
    let section: SettingsSection
    @ViewBuilder let content: Content

    init(_ section: SettingsSection, @ViewBuilder content: () -> Content) {
        self.section = section
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                // General introduces the window with a card (like System Settings);
                // every other page just says its name.
                if section == .general {
                    SettingsHeaderCard(section: section)
                } else {
                    Text(section.title)
                        .font(.system(size: 18, weight: .semibold))
                        .padding(.leading, 12)
                        .padding(.bottom, -8)
                        .accessibilityAddTraits(.isHeader)
                }
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 52)
            .padding(.bottom, 24)
        }
        .accessibilityLabel("\(section.title) settings")
    }
}

/// The page's tile, name and what it is for, in a card.
private struct SettingsHeaderCard: View {
    let section: SettingsSection

    var body: some View {
        VStack(spacing: 6) {
            SymbolTile(symbol: section.symbol, tint: section.tint, size: 52)
                .shadow(color: section.tint.opacity(0.3), radius: 8, y: 4)
                .padding(.bottom, 8)
            Text(section.title)
                .font(.system(size: 22, weight: .bold))
            Text(section.subtitle)
                .font(SettingsFont.item)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(SettingsPalette.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A card of rows, with a plain title above and, when needed, a note below.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(SettingsFont.title)
                    .padding(.leading, 12)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                content
            }
            // Each row ends in a hairline; the last one falls outside the card.
            .padding(.bottom, -1)
            .background(SettingsPalette.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let footer {
                Text(footer)
                    .font(SettingsFont.note)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row of a card: anything, padded, with a hairline under it.
struct SettingsCell<Content: View>: View {
    var vertical: CGFloat = 12
    @ViewBuilder let content: Content

    init(vertical: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.vertical = vertical
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, vertical)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(SettingsPalette.hairline).frame(height: 1).padding(.horizontal, 12)
        }
    }
}

/// A labelled row: the title and what it does on the left, the control on the
/// right — and a tile before the title when the row is about a thing.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color = .blue
    @ViewBuilder let control: Control

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, tint: Color = .blue, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.control = control()
    }

    var body: some View {
        SettingsCell(vertical: subtitle == nil ? 12 : 10) {
            HStack(spacing: 14) {
                if let symbol {
                    SymbolTile(symbol: symbol, tint: tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SettingsFont.item)
                    if let subtitle {
                        Text(subtitle)
                            .font(SettingsFont.sub)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                control
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension SettingsRow where Control == EmptyView {
    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, tint: Color = .blue) {
        self.init(title, subtitle: subtitle, symbol: symbol, tint: tint) { EmptyView() }
    }
}

/// A row that chooses by picture: the title on the left, a tile per option on
/// the right with its picture and name, the chosen one named on a pill. With
/// `inPopover`, the row shows only the chosen one on a button, and the tiles
/// come up in a popover.
struct SettingsPreviewPicker<Value: Hashable, Preview: View>: View {
    let title: String
    var subtitle: String?
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var columns = 3
    /// The tiles are small pictures, not panels: a fixed width each.
    var tileWidth: CGFloat = 104
    var inPopover = false
    @ViewBuilder let preview: (Value) -> Preview
    @State private var open = false

    var body: some View {
        if inPopover {
            SettingsRow(title, subtitle: subtitle) {
                Button {
                    open.toggle()
                } label: {
                    HStack(spacing: 8) {
                        preview(selection)
                            .frame(width: 30, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text(label(selection)).font(SettingsFont.sub)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 8)
                    .frame(height: 28)
                    .background(SettingsPalette.pill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SettingsPalette.edge))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(label(selection))
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    grid(onPick: { open = false })
                        .padding(12)
                }
            }
        } else {
            SettingsCell(vertical: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(SettingsFont.item)
                        if let subtitle {
                            Text(subtitle).font(SettingsFont.sub).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: 170, alignment: .leading)
                    Spacer(minLength: 0)
                    grid(onPick: {})
                }
            }
        }
    }

    private func grid(onPick: @escaping () -> Void) -> some View {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: 12), count: columns), alignment: .trailing, spacing: 12) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { selection = option }
                            onPick()
                        } label: {
                            VStack(spacing: 7) {
                                preview(option)
                                    .frame(width: tileWidth, height: tileWidth / 1.5)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                    )
                                    .padding(2)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(Color.brand, lineWidth: 1.5)
                                            .opacity(selection == option ? 1 : 0)
                                    )
                                Text(label(option))
                                    .font(.system(size: 11, weight: selection == option ? .medium : .regular))
                                    .lineLimit(1)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 2)
                                    .background(selection == option ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == option ? .isSelected : [])
                        .accessibilityLabel(label(option))
                    }
                }
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
