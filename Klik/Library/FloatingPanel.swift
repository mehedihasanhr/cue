import AppKit
import SwiftUI

/// The floating Klik panel (⌥⇧C by default): the island's content as a movable,
/// tinted Liquid Glass window at the pointer that scrolls vertically, as a grid of
/// cards or a list. Closes on ⎋, on a click outside, or when it loses key status.
final class FloatingPanelWindow: NSPanel {
    static let size = CGSize(width: 700, height: 520)
    private static let margin: CGFloat = 24
    private var monitors: [Any] = []

    init(rootView: some View) {
        let full = CGSize(width: Self.size.width + Self.margin * 2, height: Self.size.height + Self.margin * 2)
        super.init(
            contentRect: CGRect(origin: .zero, size: full),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // `.floating`: above ordinary windows, below the Dynamic Island so its cards can
        // be dragged in here even when the two overlap.
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the glass draws its own
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow

        let host = NSHostingView(rootView: rootView
            .frame(width: Self.size.width, height: Self.size.height)
            .liquidGlass(cornerRadius: 24, alwaysDark: true)
            .padding(Self.margin)
            .environment(\.colorScheme, .dark)
        )
        host.frame = CGRect(origin: .zero, size: full)
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    /// Shows the panel with its top-left corner just under the pointer, kept on screen.
    func show(at point: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = frame.size
        var origin = CGPoint(x: point.x - Self.margin - 24, y: point.y - size.height + Self.margin + 12)
        origin.x = min(max(origin.x, visible.minX + 8 - Self.margin), visible.maxX - size.width - 8 + Self.margin)
        origin.y = min(max(origin.y, visible.minY + 8 - Self.margin), visible.maxY - size.height - 8 + Self.margin)
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
        installMonitors()
    }

    override func close() {
        removeMonitors()
        super.close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func resignKey() {
        super.resignKey()
        // Menus and the island's compact box take key status briefly; only a real switch closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, isVisible, !isKeyWindow, NSApp.keyWindow == nil || NSApp.keyWindow?.isKind(of: NSPanel.self) == false else { return }
            close()
        }
    }

    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}

/// The panel's content: search, capture buttons, a grid/list switch, the tabs, and
/// the current tab's items scrolling vertically by day.
struct FloatingPanelView: View {
    let library: CaptureLibrary
    let clipboard: ClipboardHistory
    let assets: AssetStore
    let colors: ColorStore
    let tasksStore: TaskStore
    let actions: HistoryActions
    var onPrompt: (IslandPrompt) -> Void = { _ in }
    var onShowTask: (TaskItem) -> Void = { _ in }

    @Environment(AppPreferences.self) private var preferences
    @State private var search = ""
    /// While searching: show hits from this tab only (nil: every tab).
    @State private var resultFilter: IslandTab?
    @AppStorage(IslandTab.storageKey) private var tab: IslandTab = .all
    @AppStorage("floating.layout") private var layout: Layout = .grid

    enum Layout: String { case grid, list }

    private static let cardSize = CGSize(width: 200, height: 160)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(searching ? Color.brand : .white.opacity(0.6))
                    TextField("Search everything", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .onExitCommand { search = "" }
                    if searching {
                        Text(hits.isEmpty ? "No matches" : "\(hits.count) \(hits.count == 1 ? "match" : "matches")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize()
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Clear the search")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(.white.opacity(searching ? 0.14 : 0.1), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(searching ? Color.brand.opacity(0.8) : .clear, lineWidth: 1.5))
                if !searching {
                    Spacer(minLength: 4)
                    circle("display", help: "Capture full screen", action: actions.captureFullScreen)
                    circle("viewfinder", help: "Capture area", action: actions.captureArea)
                    circle("rectangle.expand.vertical", help: "Scrolling capture", action: actions.captureScrolling)
                    circle("text.viewfinder", help: "Capture text", action: actions.captureText)
                    circle("eyedropper", help: "Pick a color", action: actions.pickColor)
                }
            }
            .animation(.easeOut(duration: 0.18), value: searching)
            HStack(spacing: 8) {
                if searching {
                    resultPill(nil, title: "All", count: hits.count, symbol: "magnifyingglass")
                    ForEach(IslandSearch.counts(hits), id: \.tab) { entry in
                        resultPill(entry.tab, title: entry.tab.title, count: entry.count, symbol: entry.tab.symbol)
                    }
                } else {
                    ForEach(IslandTab.allCases, id: \.self) { value in
                        tabPill(value)
                    }
                }
                Spacer(minLength: 0)
                if searching || tab != .tasks {
                    HStack(spacing: 2) {
                        layoutButton(.grid, symbol: "square.grid.2x2")
                        layoutButton(.list, symbol: "list.bullet")
                    }
                    .padding(2)
                    .background(.white.opacity(0.1), in: Capsule())
                }
            }
            Group {
                if searching { searchResults } else { content }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: searching) { _, _ in resultFilter = nil }
            .onChange(of: search, refreshHits)
            .onChange(of: library.items.count + clipboard.items.count + assets.items.count + colors.items.count + tasksStore.tasks.count, refreshHits)
        }
        .padding(18)
        .foregroundStyle(.white)
    }

    // MARK: - Search

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Matches across every tab for the current search — computed once per keystroke,
    /// not once per view that shows them.
    @State private var hits: [IslandItem] = []

    private func refreshHits() {
        hits = searching ? IslandSearch.hits(for: search, library: library, clipboard: clipboard, assets: assets, colors: colors, tasks: tasksStore) : []
    }

    private func resultPill(_ value: IslandTab?, title: String, count: Int, symbol: String) -> some View {
        let selected = resultFilter == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { resultFilter = value }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background((selected ? Color.black : Color.white).opacity(0.12), in: Capsule())
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(selected ? Color.brand : Color.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Hits grouped by tab, as cards or rows like the tabs themselves.
    @ViewBuilder
    private var searchResults: some View {
        let shown = resultFilter.map { filter in hits.filter { $0.tab == filter } } ?? hits
        if shown.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
                Text("Nothing matches “\(search.trimmingCharacters(in: .whitespaces))”").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(IslandTab.allCases, id: \.self) { tab in
                        let group = shown.filter { $0.tab == tab }
                        if !group.isEmpty {
                            Text(tab.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.top, 4)
                            if layout == .grid, tab != .tasks {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cardSize.width, maximum: Self.cardSize.width), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                                    ForEach(group) { hit in hitCard(hit) }
                                }
                            } else {
                                LazyVStack(spacing: 2) {
                                    ForEach(group) { hit in hitRow(hit) }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func hitCard(_ hit: IslandItem) -> some View {
        switch hit {
        case .capture(let item): captureCard(item)
        case .clipboard(let item): clipboardCard(item)
        case .asset(let item): assetCard(item)
        case .color(let entry): colorCard(entry)
        case .task(let task): taskRow(task)
        }
    }

    @ViewBuilder
    private func hitRow(_ hit: IslandItem) -> some View {
        switch hit {
        case .capture(let item): captureRow(item)
        case .clipboard(let item): clipboardRow(item)
        case .asset(let item): assetRow(item)
        case .color(let entry): colorRow(entry)
        case .task(let task): taskRow(task)
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        let project = tasksStore.project(task.projectID)
        return ListRow(symbol: task.status.symbol, title: task.title,
                       subtitle: "\(task.status.title)\(project.map { " · \($0.name)" } ?? "") · \(task.createdAt.formatted(.relative(presentation: .named)))") { onShowTask(task) }
            .contextMenu {
                Button("Open") { onShowTask(task) }
                Menu("Status") {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Button { tasksStore.setStatus(status, for: task) } label: { Label(status.title, systemImage: status.symbol) }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { tasksStore.delete(task) }
            }
    }

    // MARK: - Header pieces

    private func circle(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func tabPill(_ value: IslandTab) -> some View {
        let selected = tab == value
        let count: Int = switch value {
        case .all: library.items.count + clipboard.items.count + assets.items.count + colors.items.count + tasksStore.tasks.count
        case .captures: library.items.count
        case .clipboard: clipboard.items.count
        case .assets: assets.items.count
        case .colors: colors.items.count
        case .tasks: tasksStore.tasks.filter { $0.status != .complete }.count
        }
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { tab = value }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: value.symbol).font(.system(size: 10, weight: .semibold))
                Text(value.title).font(.system(size: 11.5, weight: .semibold))
                if count > 0 {
                    Text("\(count)").font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background((selected ? Color.black : Color.white).opacity(0.12), in: Capsule())
                }
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(selected ? Color.white : Color.white.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func layoutButton(_ value: Layout, symbol: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { layout = value }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(layout == value ? .black : .white.opacity(0.7))
                .frame(width: 24, height: 22)
                .background(layout == value ? Color.white : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(value == .grid ? "Grid" : "List")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .all:
            list(IslandSearch.everything(library: library, clipboard: clipboard, assets: assets, colors: colors, tasks: tasksStore),
                 date: \.date, empty: "Nothing yet — capture, copy or drop something", card: hitCard, row: hitRow)
        case .tasks:
            IslandTasksView(store: tasksStore, onPrompt: onPrompt, onShowTask: onShowTask)
        case .captures:
            list(library.items, date: \.createdAt, empty: "No captures yet", card: captureCard, row: captureRow)
        case .clipboard:
            list(clipboard.items, date: \.createdAt, pinned: \.pinned, empty: "Nothing copied yet", card: clipboardCard, row: clipboardRow)
        case .assets:
            list(assets.items, date: \.createdAt, empty: "No assets yet — drop files on the island", card: assetCard, row: assetRow)
        case .colors:
            list(colors.items, date: \.createdAt, empty: "No colors yet — use the eyedropper", card: colorCard, row: colorRow)
        }
    }

    // MARK: - Cards and rows

    private func captureCard(_ item: CaptureItem) -> some View {
        CaptureCard(item: item, library: library, actions: actions, clipboard: clipboard, onPreview: { actions.preview(item) }, onRename: {
            onPrompt(IslandPrompt(kind: .rename(.capture(item)), initial: item.title.replacingOccurrences(of: "Screenshot ", with: ""), image: library.thumbnail(for: item)))
        })
    }

    private func captureRow(_ item: CaptureItem) -> some View {
        ListRow(image: library.thumbnail(for: item), symbol: "photo", title: item.title.replacingOccurrences(of: "Screenshot ", with: ""),
                subtitle: "\(item.dimensions) · \(item.createdAt.formatted(.relative(presentation: .named)))") { actions.edit(item) }
            .contextMenu {
                Button("Preview") { actions.preview(item) }
                Button("Edit") { actions.edit(item) }
                Button("Copy to Clipboard") { actions.copy(item) }
                Divider()
                Button("Delete", role: .destructive) { actions.delete(item) }
            }
    }

    private func clipboardCard(_ item: ClipboardItem) -> some View {
        ClipboardCard(item: item, clipboard: clipboard, onRename: {
            onPrompt(IslandPrompt(kind: .rename(.clipboard(item)), initial: item.name ?? "", image: clipboard.thumbnail(for: item), swatch: item.kind == .color ? PickedColor(hex: item.text) : nil))
        })
    }

    private func clipboardRow(_ item: ClipboardItem) -> some View {
        ListRow(image: clipboard.thumbnail(for: item), swatch: item.kind == .color ? PickedColor(hex: item.text) : nil,
                symbol: clipboardSymbol(item), title: item.title,
                subtitle: "\(item.sourceName ?? item.kind.rawValue.capitalized) · \(item.createdAt.formatted(.relative(presentation: .named)))") {
            clipboard.copy(item)
            FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
        }
        .contextMenu {
            Button("Copy") { clipboard.copy(item) }
            Button(item.pinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
            Divider()
            Button("Delete", role: .destructive) { clipboard.delete(item) }
        }
    }

    private func assetCard(_ item: AssetItem) -> some View {
        AssetCard(item: item, assets: assets, clipboard: clipboard, onRename: {
            onPrompt(IslandPrompt(kind: .rename(.asset(item)), initial: item.title, image: assets.thumbnail(for: item)))
        })
    }

    private func assetRow(_ item: AssetItem) -> some View {
        ListRow(image: assets.thumbnail(for: item), symbol: "doc", title: item.fileName,
                subtitle: "\(item.kind == .image ? item.dimensions : item.sizeText) · \(item.createdAt.formatted(.relative(presentation: .named)))") { assets.open(item) }
            .contextMenu {
                Button("Open") { assets.open(item) }
                Button("Copy") { assets.copy(item) }
                Button("Reveal in Finder") { assets.reveal(item) }
                Divider()
                Button("Delete", role: .destructive) { assets.delete(item) }
            }
    }

    private func colorCard(_ entry: ColorEntry) -> some View {
        ColorCard(entry: entry, colors: colors, format: preferences.colorFormat, onRename: {
            onPrompt(IslandPrompt(kind: .rename(.color(entry)), initial: entry.name ?? "", swatch: entry.color))
        })
    }

    private func colorRow(_ entry: ColorEntry) -> some View {
        ListRow(swatch: entry.color, symbol: "paintpalette", title: entry.name ?? preferences.colorFormat.string(for: entry.color),
                subtitle: "\(ColorFormat.hex.string(for: entry.color)) · \(entry.createdAt.formatted(.relative(presentation: .named)))") {
            colors.copy(entry, as: preferences.colorFormat)
            FeedbackHUD.show("\(preferences.colorFormat.string(for: entry.color)) copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
        }
        .contextMenu {
            Menu("Copy as") {
                ForEach(ColorFormat.allCases, id: \.self) { format in
                    Button(format.string(for: entry.color)) { colors.copy(entry, as: format) }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { colors.delete(entry) }
        }
    }

    private func clipboardSymbol(_ item: ClipboardItem) -> String {
        switch item.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .color: "paintpalette"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }

    /// Items by day: cards in a grid, or compact rows.
    private func list<Item: Identifiable, Card: View, Row: View>(
        _ items: [Item], date: KeyPath<Item, Date>, pinned: KeyPath<Item, Bool>? = nil, empty: String,
        @ViewBuilder card: @escaping (Item) -> Card, @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 6) {
                    Text(empty).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                        ForEach(dayGroups(items, date: date, pinned: pinned), id: \.day) { group in
                            Text(group.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.top, 4)
                            if layout == .grid {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cardSize.width, maximum: Self.cardSize.width), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                                    ForEach(group.items) { item in card(item) }
                                }
                            } else {
                                LazyVStack(spacing: 2) {
                                    ForEach(group.items) { item in row(item) }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private struct DayGroup<Item> {
        let day: Date
        let title: String
        var items: [Item]
    }

    /// Pinned items (if `pinned` is given) come first in their own group.
    private func dayGroups<Item>(_ items: [Item], date: KeyPath<Item, Date>, pinned: KeyPath<Item, Bool>? = nil) -> [DayGroup<Item>] {
        let calendar = Calendar.current
        var groups: [DayGroup<Item>] = []
        if let pinned {
            let pinnedItems = items.filter { $0[keyPath: pinned] }
            if !pinnedItems.isEmpty { groups.append(DayGroup(day: .distantFuture, title: "Pinned", items: pinnedItems)) }
        }
        for item in items where !(pinned.map { item[keyPath: $0] } ?? false) {
            let day = calendar.startOfDay(for: item[keyPath: date])
            if let index = groups.firstIndex(where: { $0.day == day }) {
                groups[index].items.append(item)
            } else {
                let title = calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday"
                    : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                groups.append(DayGroup(day: day, title: title, items: [item]))
            }
        }
        return groups
    }

    /// A compact row for the list layout: thumbnail / swatch / icon, title, subtitle.
    private struct ListRow: View {
        var image: NSImage? = nil
        var swatch: PickedColor? = nil
        let symbol: String
        let title: String
        let subtitle: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                Group {
                    if let swatch {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(swatch.swiftUIColor)
                    } else if let image {
                        Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
                    } else {
                        Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 56, height: 36)
                .background(.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
        }
    }
}
