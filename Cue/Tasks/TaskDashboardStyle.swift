import AppKit
import SwiftUI

// MARK: - Palette

/// The dashboard's colours, after Notion's: a flat page (white, or #191919 dark), a
/// sidebar a shade off it, warm grey ink at three strengths, and hairlines rather
/// than cards. Every colour follows the window's appearance.
enum NotionStyle {
    static let page = dynamic(light: rgb(255, 255, 255), dark: rgb(25, 25, 25))
    static let sidebar = dynamic(light: rgb(248, 248, 247), dark: rgb(32, 32, 32))
    /// Board cards and the floating bits (the OPEN button).
    static let card = dynamic(light: rgb(255, 255, 255), dark: rgb(40, 40, 40))
    static let text = dynamic(light: rgb(55, 53, 47), dark: rgb(255, 255, 255, 0.81))
    static let secondary = dynamic(light: rgb(55, 53, 47, 0.65), dark: rgb(255, 255, 255, 0.46))
    static let tertiary = dynamic(light: rgb(55, 53, 47, 0.45), dark: rgb(255, 255, 255, 0.28))
    static let divider = dynamic(light: rgb(55, 53, 47, 0.09), dark: rgb(255, 255, 255, 0.094))
    static let hover = dynamic(light: rgb(55, 53, 47, 0.04), dark: rgb(255, 255, 255, 0.04))
    static let selectedRow = dynamic(light: rgb(55, 53, 47, 0.08), dark: rgb(255, 255, 255, 0.08))
    /// A row whose task is open beside the table.
    static let openRow = dynamic(light: rgb(35, 131, 226, 0.07), dark: rgb(35, 131, 226, 0.14))
    static let field = dynamic(light: rgb(55, 53, 47, 0.06), dark: rgb(255, 255, 255, 0.055))
    static let accent = Color(red: 35 / 255, green: 131 / 255, blue: 226 / 255)

    static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
}

/// A thin line between things, the way Notion separates rows and columns.
struct Hairline: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(NotionStyle.divider)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

// MARK: - Tags

/// Notion's tag colours: a soft fill with ink of the same hue, and a stronger dot.
enum NotionColor: String, CaseIterable {
    case gray, brown, orange, yellow, green, blue, purple, pink, red

    var title: String { rawValue.capitalized }

    var background: Color {
        switch self {
        case .gray: NotionStyle.dynamic(light: NotionStyle.rgb(227, 226, 224), dark: NotionStyle.rgb(71, 71, 71))
        case .brown: NotionStyle.dynamic(light: NotionStyle.rgb(238, 224, 218), dark: NotionStyle.rgb(96, 59, 44))
        case .orange: NotionStyle.dynamic(light: NotionStyle.rgb(250, 222, 201), dark: NotionStyle.rgb(133, 76, 29))
        case .yellow: NotionStyle.dynamic(light: NotionStyle.rgb(253, 236, 200), dark: NotionStyle.rgb(137, 99, 42))
        case .green: NotionStyle.dynamic(light: NotionStyle.rgb(219, 237, 219), dark: NotionStyle.rgb(43, 89, 63))
        case .blue: NotionStyle.dynamic(light: NotionStyle.rgb(211, 229, 239), dark: NotionStyle.rgb(40, 69, 108))
        case .purple: NotionStyle.dynamic(light: NotionStyle.rgb(232, 222, 238), dark: NotionStyle.rgb(73, 47, 100))
        case .pink: NotionStyle.dynamic(light: NotionStyle.rgb(245, 224, 233), dark: NotionStyle.rgb(105, 49, 76))
        case .red: NotionStyle.dynamic(light: NotionStyle.rgb(255, 226, 221), dark: NotionStyle.rgb(110, 54, 48))
        }
    }

    var text: Color {
        let dark = NotionStyle.rgb(255, 255, 255, 0.88)
        return switch self {
        case .gray: NotionStyle.dynamic(light: NotionStyle.rgb(50, 48, 44), dark: dark)
        case .brown: NotionStyle.dynamic(light: NotionStyle.rgb(68, 42, 30), dark: dark)
        case .orange: NotionStyle.dynamic(light: NotionStyle.rgb(73, 41, 14), dark: dark)
        case .yellow: NotionStyle.dynamic(light: NotionStyle.rgb(64, 44, 27), dark: dark)
        case .green: NotionStyle.dynamic(light: NotionStyle.rgb(28, 56, 41), dark: dark)
        case .blue: NotionStyle.dynamic(light: NotionStyle.rgb(24, 51, 71), dark: dark)
        case .purple: NotionStyle.dynamic(light: NotionStyle.rgb(65, 36, 84), dark: dark)
        case .pink: NotionStyle.dynamic(light: NotionStyle.rgb(76, 35, 55), dark: dark)
        case .red: NotionStyle.dynamic(light: NotionStyle.rgb(93, 23, 21), dark: dark)
        }
    }

    var dot: Color {
        switch self {
        case .gray: Color(red: 145 / 255, green: 145 / 255, blue: 142 / 255)
        case .brown: Color(red: 159 / 255, green: 107 / 255, blue: 83 / 255)
        case .orange: Color(red: 217 / 255, green: 115 / 255, blue: 13 / 255)
        case .yellow: Color(red: 203 / 255, green: 145 / 255, blue: 47 / 255)
        case .green: Color(red: 68 / 255, green: 131 / 255, blue: 97 / 255)
        case .blue: Color(red: 51 / 255, green: 126 / 255, blue: 169 / 255)
        case .purple: Color(red: 144 / 255, green: 101 / 255, blue: 176 / 255)
        case .pink: Color(red: 193 / 255, green: 76 / 255, blue: 138 / 255)
        case .red: Color(red: 212 / 255, green: 76 / 255, blue: 71 / 255)
        }
    }
}

extension TaskStatus {
    var notionColor: NotionColor {
        switch self {
        case .pending: .gray
        case .inProcess: .blue
        case .review: .orange
        case .complete: .green
        }
    }
}

extension TaskPriority {
    var notionColor: NotionColor {
        switch self {
        case .urgent: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .green
        }
    }
}

/// A Notion tag: a status is a rounded pill with a dot, anything else a small
/// rounded rectangle.
struct NotionTag: View {
    let text: String
    let color: NotionColor
    var dot = false

    var body: some View {
        HStack(spacing: 5) {
            if dot {
                Circle().fill(color.dot).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.system(size: 13))
                .lineLimit(1)
        }
        .foregroundStyle(color.text)
        .padding(.leading, dot ? 6 : 6)
        .padding(.trailing, dot ? 8 : 6)
        .frame(height: 21)
        .background(color.background, in: RoundedRectangle(cornerRadius: dot ? 10.5 : 4, style: .continuous))
    }
}

extension NotionTag {
    static func status(_ status: TaskStatus) -> NotionTag { NotionTag(text: status.title, color: status.notionColor, dot: true) }
    static func priority(_ priority: TaskPriority) -> NotionTag { NotionTag(text: priority.title, color: priority.notionColor) }
    static func project(_ name: String) -> NotionTag { NotionTag(text: name, color: .gray) }
}

// MARK: - Small controls

/// A borderless icon button in Notion's manner: grey, a light square under the pointer.
struct NotionIconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 14
    var tint: Color = NotionStyle.secondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(hovering ? NotionStyle.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Menus

/// Pick a status; the current one is ticked off as unavailable.
struct TaskStatusItems: View {
    let store: TaskStore
    let task: TaskItem

    var body: some View {
        ForEach(TaskStatus.allCases, id: \.self) { status in
            Button { store.setStatus(status, for: task) } label: { Label(status.title, systemImage: status.symbol) }
                .disabled(status == task.status)
        }
    }
}

struct TaskPriorityItems: View {
    let store: TaskStore
    let task: TaskItem

    var body: some View {
        ForEach(TaskPriority.allCases, id: \.self) { priority in
            Button { store.setPriority(priority, for: task) } label: { Label(priority.title, systemImage: priority.symbol) }
                .disabled(priority == task.priority)
        }
    }
}

/// Every project by its full path, and No project.
struct TaskProjectItems: View {
    let store: TaskStore
    let task: TaskItem

    private func path(_ project: TaskProject) -> String {
        store.path(to: project.id).map(\.name).joined(separator: " › ")
    }

    var body: some View {
        Button("No project") { store.move(task, to: nil) }
            .disabled(task.projectID == nil)
        if !store.projects.isEmpty { Divider() }
        ForEach(store.projects.sorted { path($0).localizedStandardCompare(path($1)) == .orderedAscending }) { project in
            Button(path(project)) { store.move(task, to: project.id) }
                .disabled(task.projectID == project.id)
        }
    }
}

/// A tag that opens a menu to change it: the table's cells and the page's properties.
struct TagMenu<Items: View>: View {
    let tag: NotionTag?
    var placeholder = "Empty"
    let help: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu { items } label: {
            Group {
                if let tag {
                    tag
                } else {
                    Text(placeholder).font(.system(size: 13)).foregroundStyle(NotionStyle.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(help)
    }
}

// MARK: - Page icons

/// A page's icon at a size: the symbol in grey ink, or the emoji as it is.
struct PageIconView: View {
    let icon: PageIcon
    var size: CGFloat = 14
    var weight: Font.Weight = .regular

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(NotionStyle.secondary)
        case .emoji(let character):
            Text(character)
                .font(.system(size: size * 1.05))
        }
    }
}

/// Every SF Symbol this macOS draws and every emoji, with their names, read once in
/// the background the first time the icon picker opens.
@Observable
@MainActor
final class IconCatalog {
    static let shared = IconCatalog()

    private(set) var symbols: [String] = []
    /// Each emoji with its Unicode name in lower case, for search.
    private(set) var emoji: [(character: String, name: String)] = []
    private(set) var loaded = false
    private var loading = false

    func load() {
        guard !loaded, !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let symbols = Self.readSymbols()
            let emoji = Self.readEmoji()
            await MainActor.run {
                IconCatalog.shared.symbols = symbols
                IconCatalog.shared.emoji = emoji
                IconCatalog.shared.loaded = true
            }
        }
    }

    /// The system's own list of symbol names, in its order; localized variants
    /// (`.ar`, `.hi`, `.rtl`…) and names this macOS cannot draw are left out.
    private nonisolated static func readSymbols() -> [String] {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/symbol_order.plist")
        guard let data = try? Data(contentsOf: url),
              let names = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return PageIcon.symbols }
        let localized: Set<String> = ["ar", "he", "hi", "ja", "ko", "th", "zh", "rtl", "bn", "gu", "kn", "ml", "mr", "or", "pa", "ta", "te", "my", "km", "el", "ru", "sat", "mni", "ug", "tr"]
        let usable = names.filter { name in
            guard let last = name.split(separator: ".").last, !localized.contains(String(last)) else { return false }
            return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        }
        return usable.isEmpty ? PageIcon.symbols : usable
    }

    /// Single-character emoji (shown as emoji by default), with their names.
    private nonisolated static func readEmoji() -> [(character: String, name: String)] {
        let ranges: [ClosedRange<UInt32>] = [0x2300...0x23FF, 0x2600...0x27BF, 0x2B00...0x2BFF, 0x1F300...0x1F5FF, 0x1F600...0x1F64F,
                                             0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF]
        var result: [(character: String, name: String)] = []
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value), scalar.properties.isEmoji,
                      let name = scalar.properties.name else { continue }
                // ❤ ☀ ✏ are text by default: the variation selector draws them as emoji.
                let character = scalar.properties.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
                result.append((character, name.lowercased()))
            }
        }
        return result
    }
}

/// Notion's icon picker: a search over icons and emoji, the suggested ones first and
/// then every one, and Remove to go back to the page's own icon.
struct PageIconPicker: View {
    let current: PageIcon
    let pick: (PageIcon?) -> Void
    @State private var tab: Tab
    @State private var query = ""
    @FocusState private var searching: Bool
    private var catalog = IconCatalog.shared

    enum Tab: String, CaseIterable { case icons = "Icons", emoji = "Emoji" }

    init(current: PageIcon, pick: @escaping (PageIcon?) -> Void) {
        self.current = current
        self.pick = pick
        if case .emoji = current { _tab = State(initialValue: .emoji) } else { _tab = State(initialValue: .icons) }
    }

    private static let cell: CGFloat = 34
    private static let perRow = 9
    private let columns = Array(repeating: GridItem(.fixed(PageIconPicker.cell), spacing: 2), count: PageIconPicker.perRow)

    private var words: [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "." }).map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Kind", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Remove") { pick(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(NotionStyle.secondary)
                    .help("Use the page's own icon")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(NotionStyle.tertiary)
                TextField(tab == .icons ? "Search icons" : "Search emoji", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searching)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(NotionStyle.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(NotionStyle.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                    if tab == .icons { iconSections } else { emojiSections }
                }
            }
            .thinScrollers()
            .frame(height: 300)
        }
        .padding(12)
        .frame(width: CGFloat(Self.perRow) * Self.cell + CGFloat(Self.perRow - 1) * 2 + 24)
        .onAppear {
            catalog.load()
            searching = true
        }
        .onChange(of: tab) { _, _ in query = "" }
    }

    @ViewBuilder
    private var iconSections: some View {
        if words.isEmpty {
            section("Suggested", PageIcon.symbols.map(PageIcon.symbol))
            if catalog.loaded {
                section("All icons", catalog.symbols.map(PageIcon.symbol))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 8)
            }
        } else {
            let source = catalog.loaded ? catalog.symbols : PageIcon.symbols
            let found = source.filter { name in words.allSatisfy { name.contains($0) } }
            results(Self.ranked(found, for: words.joined(separator: ".")) { $0 }.map(PageIcon.symbol))
        }
    }

    @ViewBuilder
    private var emojiSections: some View {
        if words.isEmpty {
            section("Suggested", PageIcon.emoji.map(PageIcon.emoji))
            if catalog.loaded {
                section("All emoji", catalog.emoji.map { PageIcon.emoji($0.character) })
            }
        } else {
            let found = catalog.emoji.filter { entry in words.allSatisfy { entry.name.contains($0) } }
            results(Self.ranked(found, for: words.joined(separator: " ")) { $0.name }.map { PageIcon.emoji($0.character) })
        }
    }

    /// The closest first: the name itself, then names that start with the search, then
    /// those with a word that does, then the rest — each in the catalogue's order.
    private static func ranked<T>(_ items: [T], for query: String, name: (T) -> String) -> [T] {
        func score(_ item: T) -> Int {
            let name = name(item)
            if name == query { return 0 }
            if name.hasPrefix(query) { return 1 }
            if name.contains("." + query) || name.contains(" " + query) { return 2 }
            return 3
        }
        return items.enumerated().sorted { (score($0.element), $0.offset) < (score($1.element), $1.offset) }.map(\.element)
    }

    @ViewBuilder
    private func results(_ icons: [PageIcon]) -> some View {
        if icons.isEmpty {
            Text(catalog.loaded ? "No match for “\(query)”" : "Loading…")
                .font(.system(size: 13))
                .foregroundStyle(NotionStyle.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else {
            section(icons.count == 1 ? "1 result" : "\(icons.count) results", icons)
        }
    }

    private func section(_ title: String, _ icons: [PageIcon]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotionStyle.tertiary)
                .padding(.leading, 2)
                .padding(.top, 4)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                ForEach(Array(icons.enumerated()), id: \.offset) { _, icon in cell(icon) }
            }
        }
    }

    private func cell(_ icon: PageIcon) -> some View {
        Button {
            pick(icon)
        } label: {
            PageIconView(icon: icon, size: 18)
                .frame(width: Self.cell, height: Self.cell)
                .background(icon == current ? NotionStyle.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(NotionHoverStyle())
        .help(icon.rawValue.replacingOccurrences(of: "symbol:", with: "").replacingOccurrences(of: "emoji:", with: ""))
    }
}

/// Notion's grip: six dots in two columns (or two rows, turned for a column's handle).
struct DragDots: View {
    var horizontal = false
    var color: Color = NotionStyle.tertiary
    /// Each dot's size: 2.5 pt makes a grip 12.5 pt tall, the height of the + beside it.
    var dot: CGFloat = 2.5

    var body: some View {
        let dots = Grid(horizontalSpacing: dot, verticalSpacing: dot) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow {
                    Circle().frame(width: dot, height: dot)
                    Circle().frame(width: dot, height: dot)
                }
            }
        }
        .foregroundStyle(color)
        return Group {
            if horizontal { dots.rotationEffect(.degrees(90)) } else { dots }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Scrollers

/// A slim scroller in the page's own grey: no track, a thin rounded knob that thickens
/// a touch under the pointer — always the overlay kind, whatever System Settings asks
/// for, so a scroll area never gives up a band of its width to a chunky bar.
final class ThinScroller: NSScroller {
    private var hovering = false
    private var tracking: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 10 }

    private static let knobColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.18)
            : NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.16)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let vertical = bounds.height > bounds.width
        let thickness: CGFloat = hovering ? 6 : 4
        let inset: CGFloat = 2
        let shape = vertical
            ? NSRect(x: knob.maxX - thickness - inset, y: knob.minY + inset, width: thickness, height: max(knob.height - inset * 2, thickness))
            : NSRect(x: knob.minX + inset, y: knob.maxY - thickness - inset, width: max(knob.width - inset * 2, thickness), height: thickness)
        Self.knobColor.setFill()
        NSBezierPath(roundedRect: shape, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    /// Gives a scroll view thin scrollers in the overlay style.
    static func install(on scrollView: NSScrollView) {
        if !(scrollView.verticalScroller is ThinScroller) { scrollView.verticalScroller = ThinScroller() }
        if !(scrollView.horizontalScroller is ThinScroller) { scrollView.horizontalScroller = ThinScroller() }
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        scrollView.autohidesScrollers = true
    }
}

/// Finds the scroll view a SwiftUI `ScrollView` is drawn with — the one with this
/// view's frame — and gives it thin scrollers; again whenever macOS changes its own
/// scroller style back.
private struct ThinScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.schedule() }

    final class Probe: NSView {
        private var observing = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
            if !observing {
                observing = true
                NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            }
        }

        @objc private func styleChanged() { schedule() }

        override func layout() {
            super.layout()
            schedule()
        }

        private var scheduled = false

        /// Once per turn of the run loop at most, however many layout passes ask.
        func schedule() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.scheduled = false
                self?.install()
            }
        }

        /// The scroll view found, so a layout pass costs a few checks, not a walk of the window.
        private weak var found: NSScrollView?

        private func install() {
            if let found, found.window != nil {
                ThinScroller.install(on: found)
                return
            }
            guard let window, let content = window.contentView else { return }
            let frame = convert(bounds, to: nil)
            func search(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView {
                    let other = scroll.convert(scroll.bounds, to: nil)
                    if abs(other.minX - frame.minX) < 1.5, abs(other.minY - frame.minY) < 1.5,
                       abs(other.width - frame.width) < 1.5, abs(other.height - frame.height) < 1.5 { return scroll }
                }
                for subview in view.subviews { if let found = search(subview) { return found } }
                return nil
            }
            if let scroll = search(content) {
                found = scroll
                ThinScroller.install(on: scroll)
            }
        }
    }
}

extension View {
    /// For a `ScrollView`: thin, quiet scrollers in place of the system's.
    func thinScrollers() -> some View {
        background(ThinScrollerInstaller().allowsHitTesting(false))
    }
}
