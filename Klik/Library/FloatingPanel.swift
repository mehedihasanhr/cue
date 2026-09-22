import AppKit
import SwiftUI

/// The floating Klik panel (⌥⇧C by default): the island's content as a movable,
/// tinted Liquid Glass window at the pointer that scrolls vertically, as a grid of
/// cards or a list. It moves by the strip along its top (a drag on a card carries
/// the item out instead). Closes on ⎋, on a click outside, or when it loses key status.
final class FloatingPanelWindow: NSPanel {
    static let size = CGSize(width: 700, height: 520)
    private static let margin: CGFloat = 24
    private var monitors: [Any] = []

    /// `movableByBackground`: a drag anywhere moves the window. The library panel
    /// says no — a drag on a card carries the item out instead, and the strip along
    /// the top moves the panel.
    init(rootView: some View, size: CGSize = FloatingPanelWindow.size, movableByBackground: Bool = true) {
        let full = CGSize(width: size.width + Self.margin * 2, height: size.height + Self.margin * 2)
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
        isMovableByWindowBackground = movableByBackground
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        sharingType = .readOnly // shows in screen sharing; Klik's own shots filter it out
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow

        let host = NSHostingView(rootView: rootView
            .frame(width: size.width, height: size.height)
            .liquidGlass(cornerRadius: 24, alwaysDark: true)
            .padding(Self.margin)
            .environment(\.colorScheme, .dark)
        )
        host.frame = CGRect(origin: .zero, size: full)
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    /// Shows the panel at `position` on the pointer's screen (at the pointer: its
    /// top-left corner just under it), kept on screen.
    func show(at point: CGPoint, position: PanelPosition = .pointer) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        setFrameOrigin(position.origin(windowSize: frame.size, margin: Self.margin, pointer: point, visible: visible))
        makeKeyAndOrderFront(nil)
        installMonitors()
    }

    override func close() {
        removeMonitors()
        super.close()
        // AppKit hands key status to the next of Klik's windows that will take it —
        // the island — and the keyboard stays with Klik instead of going back to the
        // user's app. Ordering that window out and in again is the only way to drop it.
        if let key = NSApp.keyWindow as? NSPanel, key !== self, key.styleMask.contains(.nonactivatingPanel), key.isVisible {
            key.orderOut(nil)
            key.orderFrontRegardless()
        }
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

/// The panel's content: a search field, the capture tools and a grid/list switch on
/// top; every capture, clipboard entry, asset and color below, newest first by day.
/// A card copies its item on a click and drags it out — nothing more: pinning,
/// grouping, editing and deleting are the island's job.
struct FloatingPanelView: View {
    let library: CaptureLibrary
    let clipboard: ClipboardHistory
    let assets: AssetStore
    let colors: ColorStore
    // Only for the search, which looks across everything.
    let tasksStore: TaskStore
    let snippets: SnippetStore
    @Environment(NoteStore.self) private var notes
    let actions: HistoryActions
    /// Closes the panel — after a card has copied its item.
    let close: () -> Void

    @Environment(AppPreferences.self) private var preferences
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("floating.layout") private var layout: Layout = .grid
    /// Matches for the current search — computed once per keystroke.
    @State private var hits: [IslandItem] = []

    enum Layout: String { case grid, list }

    private static let cardHeight: CGFloat = 150
    /// As many equal columns as Settings › Panels says (4 by default).
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.gap, alignment: .top), count: preferences.panelColumns)
    }
    /// Between cards, across and down.
    private static let gap: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The panel moves by this strip alone: a drag on a card carries the item out.
            WindowDragStrip()
                .frame(maxWidth: .infinity)
                .frame(height: 12)
                .overlay { Capsule().fill(.white.opacity(0.25)).frame(width: 36, height: 4) }
                .padding(.top, -6)
            header
            Group {
                if searching { results } else { everything }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: search, refreshHits)
            .onChange(of: library.items.count + clipboard.items.count + assets.items.count + colors.items.count, refreshHits)
        }
        .padding(18)
        .foregroundStyle(.white)
        // The panel opens ready to type into.
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Icon("magnifyingglass", size: 14, weight: .medium)
                    .foregroundStyle(searching ? Color.brand : .white.opacity(0.6))
                TextField("Search everything", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($searchFocused) // ⎋ falls through to the panel, which closes
                if searching {
                    Text(hits.isEmpty ? "No matches" : "\(hits.count) \(hits.count == 1 ? "match" : "matches")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize()
                    Button { search = "" } label: {
                        Icon("xmark.circle.fill", size: 14).foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Clear the search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.white.opacity(searching ? 0.14 : 0.1), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(searching ? Color.brand.opacity(0.8) : .clear, lineWidth: 1.5))
            HStack(spacing: 4) {
                tool("display", help: "Capture full screen", action: actions.captureFullScreen)
                tool("viewfinder", help: "Capture area", action: actions.captureArea)
                tool("rectangle.expand.vertical", help: "Scrolling capture", action: actions.captureScrolling)
                tool("text.viewfinder", help: "Capture text", action: actions.captureText)
                tool("eyedropper", help: "Pick a color", action: actions.pickColor)
            }
            .padding(3)
            .background(.white.opacity(0.08), in: Capsule())
            HStack(spacing: 2) {
                layoutButton(.grid, symbol: "square.grid.2x2")
                layoutButton(.list, symbol: "list.bullet")
            }
            .padding(3)
            .background(.white.opacity(0.08), in: Capsule())
        }
    }

    private func tool(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        ToolButton(symbol: symbol, help: help, action: action)
    }

    private struct ToolButton: View {
        let symbol: String
        let help: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Icon(symbol, size: 14, weight: .medium)
                    .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(hovering ? 0.16 : 0), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(help)
        }
    }

    private func layoutButton(_ value: Layout, symbol: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { layout = value }
        } label: {
            Icon(symbol, size: 12, weight: .bold)
                .foregroundStyle(layout == value ? .black : .white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(layout == value ? Color.white : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(value == .grid ? "Grid — right-click for the number of columns" : "List")
        .contextMenu {
            if value == .grid {
                ForEach(Array(AppPreferences.panelColumnRange), id: \.self) { count in
                    Button {
                        preferences.panelColumns = count
                    } label: {
                        if count == preferences.panelColumns {
                            Label("\(count) columns", systemImage: "checkmark")
                        } else {
                            Text("\(count) columns")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Items

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// What the panel holds: captures, clipboard entries, assets and colors (the
    /// features that are on), newest first.
    private var items: [IslandItem] {
        let all = library.items.map(IslandItem.capture) + clipboard.items.map(IslandItem.clipboard)
            + assets.items.map(IslandItem.asset) + colors.items.map(IslandItem.color)
        return all.filter(preferences.shows).sorted { $0.date > $1.date }
    }

    private func refreshHits() {
        guard searching else { hits = []; return }
        hits = IslandSearch.hits(for: search, library: library, clipboard: clipboard, assets: assets, colors: colors, tasks: tasksStore, snippets: snippets, notes: notes)
            .filter { hit in
                switch hit {
                case .capture, .clipboard, .asset, .color, .answer: preferences.shows(hit)
                case .task, .snippet, .note: false
                }
            }
    }

    @ViewBuilder
    private var everything: some View {
        let items = items
        if items.isEmpty {
            empty("Nothing yet — capture, copy or drop something")
        } else {
            FadingScrollView {
                LazyVStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(dayGroups(items), id: \.day) { group in
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.top, 4)
                        section(group.items)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if hits.isEmpty {
            empty("Nothing matches “\(search.trimmingCharacters(in: .whitespaces))”")
        } else {
            FadingScrollView {
                section(hits).padding(.bottom, 8)
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func section(_ items: [IslandItem]) -> some View {
        if layout == .grid {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Self.gap) {
                ForEach(items) { item in card(item).frame(height: Self.cardHeight) }
            }
        } else {
            LazyVStack(spacing: 2) {
                ForEach(items) { item in row(item) }
            }
        }
    }

    private struct DayGroup {
        let day: Date
        let title: String
        var items: [IslandItem]
    }

    /// Pinned items first in their own group, then each day's.
    private func dayGroups(_ items: [IslandItem]) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        let pinned = items.filter(\.pinned)
        if !pinned.isEmpty { groups.append(DayGroup(day: .distantFuture, title: "Pinned", items: pinned)) }
        for item in items where !item.pinned {
            let day = calendar.startOfDay(for: item.date)
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

    // MARK: - Cards

    @ViewBuilder
    private func card(_ item: IslandItem) -> some View {
        switch item {
        case .capture(let capture):
            QuickCard(label: "Screenshot \(capture.dimensions), \(capture.createdAt.formatted(.relative(presentation: .named)))",
                      payload: { library.fileURL(for: capture).map { .file($0, preview: library.thumbnail(for: capture), reference: .capture(capture.id)) } },
                      copy: { actions.copy(capture) }, close: close) {
                picture(library.thumbnail(for: capture))
                    .overlay(alignment: .bottom) {
                        CardCaption(title: "", date: capture.createdAt, subtitle: capture.createdAt.formatted(date: .omitted, time: .shortened)) {
                            Badge(text: capture.dimensions)
                        }
                    }
            }
        case .clipboard(let entry):
            QuickCard(label: "\(entry.kind.rawValue.capitalized): \(entry.name ?? entry.title), \(entry.createdAt.formatted(.relative(presentation: .named)))",
                      payload: { clipboard.dragPayload(for: entry).map { var own = $0; own.reference = .clipboard(entry.id); return own } },
                      copy: {
                          // Not promoted yet: the card would jump to the top under the pointer
                          // before "Copied" could be read. It moves once the panel has closed.
                          clipboard.copy(entry, promote: false)
                          FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: entry.contentTitle, image: clipboard.thumbnail(for: entry))
                      }, close: { close(); clipboard.promote(entry) }) {
                clipboardContent(entry)
                    .overlay(alignment: .bottom) {
                        CardCaption(title: entry.name ?? "", date: entry.createdAt) {
                            if let icon = clipboard.sourceIcon(for: entry) {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16).help(entry.sourceName ?? "")
                            }
                        }
                    }
            }
        case .asset(let asset):
            QuickCard(label: "\(asset.fileName), \(asset.createdAt.formatted(.relative(presentation: .named)))",
                      payload: { .file(assets.fileURL(for: asset), preview: assets.thumbnail(for: asset), reference: .asset(asset.id)) },
                      copy: {
                          assets.copy(asset)
                          FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: asset.fileName, image: assets.thumbnail(for: asset))
                      }, close: close) {
                Group {
                    if asset.kind == .image {
                        picture(assets.thumbnail(for: asset))
                    } else {
                        VStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: assets.fileURL(for: asset).path)).resizable().frame(width: 44, height: 44)
                            Text((asset.fileName as NSString).pathExtension.uppercased())
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .overlay(alignment: .bottom) {
                    CardCaption(title: asset.fileName, date: asset.createdAt) {
                        Badge(text: asset.kind == .image ? asset.dimensions : asset.sizeText)
                    }
                }
            }
        case .color(let entry):
            let format = preferences.colorFormat
            QuickCard(label: "Color \(entry.name ?? format.string(for: entry.color))",
                      payload: { DragPayload(writer: format.string(for: entry.color) as NSString, preview: ColorCard.dragImage(for: entry.color), reference: .color(entry.id)) },
                      copy: {
                          colors.copy(entry, as: format)
                          FeedbackHUD.show("\(format.string(for: entry.color)) copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), swatch: entry.color)
                      }, close: close) {
                entry.color.swiftUIColor
                    .overlay(alignment: .topLeading) {
                        Text(format.string(for: entry.color))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(entry.color.isDark ? .white : .black)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background((entry.color.isDark ? Color.white : Color.black).opacity(0.18), in: Capsule())
                            .padding(10)
                    }
                    .overlay(alignment: .bottom) {
                        CardCaption(title: entry.name ?? "", date: entry.createdAt) { EmptyView() }
                    }
            }
        case .answer(let answer):
            AnswerCard(answer: answer, clipboard: clipboard, colors: colors)
        case .task, .snippet, .note:
            EmptyView()
        }
    }

    private func picture(_ image: NSImage?) -> some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.1)
                }
            }
            .clipped()
    }

    @ViewBuilder
    private func clipboardContent(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .text:
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
                .padding(.bottom, 20) // clear of the caption
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Icon("link", size: 14, weight: .semibold)
                    Text(URL(string: item.text)?.host ?? item.text).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                Text(item.text).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
        case .color:
            let components = item.colorComponents ?? (0.5, 0.5, 0.5)
            Color(red: components.red, green: components.green, blue: components.blue)
                .overlay(alignment: .topLeading) {
                    Text(item.text)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(10)
                }
        case .image:
            picture(clipboard.thumbnail(for: item))
                .overlay(alignment: .topTrailing) { Badge(text: item.dimensions).padding(8) }
        case .files:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Icon(item.filePaths.count > 1 ? "doc.on.doc" : "doc", size: 15, weight: .semibold)
                    Text(item.filePaths.count > 1 ? "\(item.filePaths.count) files" : "File").font(.system(size: 12, weight: .semibold))
                }
                ForEach(item.filePaths.prefix(3), id: \.self) { path in
                    Text((path as NSString).lastPathComponent).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ item: IslandItem) -> some View {
        switch item {
        case .capture(let capture):
            ListRow(image: library.thumbnail(for: capture), symbol: "photo", title: capture.title.replacingOccurrences(of: "Screenshot ", with: ""),
                    subtitle: "\(capture.dimensions) · \(capture.createdAt.formatted(.relative(presentation: .named)))",
                    payload: { library.fileURL(for: capture).map { .file($0, preview: library.thumbnail(for: capture), reference: .capture(capture.id)) } }, close: close) {
                actions.copy(capture)
            }
        case .clipboard(let entry):
            ListRow(image: clipboard.thumbnail(for: entry), swatch: entry.kind == .color ? PickedColor(hex: entry.text) : nil,
                    symbol: clipboardSymbol(entry), title: entry.title,
                    subtitle: "\(entry.sourceName ?? entry.kind.rawValue.capitalized) · \(entry.createdAt.formatted(.relative(presentation: .named)))",
                    payload: { clipboard.dragPayload(for: entry) }, close: { close(); clipboard.promote(entry) }) {
                clipboard.copy(entry, promote: false) // promoted once the panel has closed, so the row stays put
                FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
            }
        case .asset(let asset):
            ListRow(image: assets.thumbnail(for: asset), symbol: "doc", title: asset.fileName,
                    subtitle: "\(asset.kind == .image ? asset.dimensions : asset.sizeText) · \(asset.createdAt.formatted(.relative(presentation: .named)))",
                    payload: { .file(assets.fileURL(for: asset), preview: assets.thumbnail(for: asset), reference: .asset(asset.id)) }, close: close) {
                assets.copy(asset)
                FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: asset.fileName)
            }
        case .color(let entry):
            let format = preferences.colorFormat
            ListRow(swatch: entry.color, symbol: "paintpalette", title: entry.name ?? format.string(for: entry.color),
                    subtitle: "\(ColorFormat.hex.string(for: entry.color)) · \(entry.createdAt.formatted(.relative(presentation: .named)))",
                    payload: { DragPayload(writer: format.string(for: entry.color) as NSString, preview: ColorCard.dragImage(for: entry.color), reference: .color(entry.id)) }, close: close) {
                colors.copy(entry, as: format)
                FeedbackHUD.show("\(format.string(for: entry.color)) copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), swatch: entry.color)
            }
        case .answer(let answer):
            AnswerCard(answer: answer, clipboard: clipboard, colors: colors).frame(height: Self.cardHeight)
        case .task, .snippet, .note:
            EmptyView()
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

    /// A card: the item, a Copy pill while hovered, a brand outline. A click copies,
    /// the pill says Copied for a moment and the panel closes; a drag carries the
    /// item out.
    private struct QuickCard<Content: View>: View {
        let label: String
        let payload: () -> DragPayload?
        let copy: () -> Void
        let close: () -> Void
        @ViewBuilder let content: () -> Content
        @State private var hovering = false
        @State private var copied = false

        var body: some View {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(hovering ? Color.brand : .white.opacity(0.1), lineWidth: hovering ? 2 : 1))
                // Two ways in, because either layer can end up on top: AppKit for the
                // press (a drag carries the item out), SwiftUI for the click. Whichever
                // arrives first copies — `perform` only ever runs once.
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture(perform: perform)
                .onHover { hovering = $0 }
                .overlay(DragSource(payload: payload, onClick: perform, onHover: { hovering = $0 }))
                // The pill sits above the card's AppKit layer, so it takes its own
                // clicks: "Copy" while hovered, a green "Copied" once it has (a fade
                // alone when motion is reduced).
                .overlay(alignment: .topTrailing) {
                    Button(action: perform) {
                        ZStack {
                            if copied {
                                pillLabel("checkmark", "Copied")
                            } else {
                                pillLabel("doc.on.doc", "Copy")
                            }
                        }
                        .foregroundStyle(copied ? Color.white : .black)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(copied ? Color.green : .white, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .opacity(hovering || copied ? 1 : 0)
                    .allowsHitTesting(hovering || copied)
                    .animation(.easeOut(duration: 0.15), value: copied)
                    .accessibilityHidden(true)
                }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityAction { perform() }
        }

        private func pillLabel(_ symbol: String, _ title: String) -> some View {
            HStack(spacing: 5) {
                Icon(symbol, size: 11, weight: .semibold)
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .transition(IslandView.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
        }

        /// Copies once, shows it on the pill, then closes the panel.
        private func perform() {
            guard !copied else { return }
            copied = true
            copy()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { close() }
        }
    }

    /// A compact row for the list layout: thumbnail / swatch / icon, title, subtitle.
    /// A click copies (a green tick, then the panel closes), a drag carries the item out.
    private struct ListRow: View {
        var image: NSImage? = nil
        var swatch: PickedColor? = nil
        let symbol: String
        let title: String
        let subtitle: String
        let payload: () -> DragPayload?
        let close: () -> Void
        let action: () -> Void
        @State private var hovering = false
        @State private var copied = false

        var body: some View {
            HStack(spacing: 10) {
                Group {
                    if let swatch {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(swatch.swiftUIColor)
                    } else if let image {
                        Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
                    } else {
                        Icon(symbol, size: 15).foregroundStyle(.white.opacity(0.7))
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
                if copied {
                    Icon("checkmark.circle.fill", size: 13, weight: .semibold).foregroundStyle(.green).padding(.trailing, 4)
                } else if hovering {
                    Icon("doc.on.doc", size: 12, weight: .semibold).foregroundStyle(.white.opacity(0.7)).padding(.trailing, 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onTapGesture(perform: perform)
            .onHover { hovering = $0 }
            .overlay(DragSource(payload: payload, onClick: perform, onHover: { hovering = $0 }))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.15), value: copied)
        }

        /// Copies once, shows the tick, then closes the panel.
        private func perform() {
            guard !copied else { return }
            copied = true
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { close() }
        }
    }
}

/// The AppKit side of a card or row: a press that moves becomes a drag out of the
/// panel (a file URL carrying the sandbox extension other apps need, or the text);
/// a press released in place is a click. Hover is reported from here too, so the
/// view above never misses it — and is checked again whenever the card moves, since
/// cards shift under a still pointer (a new entry, a promoted one) without AppKit
/// sending the exit.
private struct DragSource: NSViewRepresentable {
    let payload: () -> DragPayload?
    let onClick: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> SourceView {
        let view = SourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: SourceView, context: Context) {
        update(view)
    }

    private func update(_ view: SourceView) {
        view.payload = payload
        view.onClick = onClick
        view.onHover = onHover
    }

    final class SourceView: NSView, NSDraggingSource {
        var payload: (() -> DragPayload?)?
        var onClick: (() -> Void)?
        var onHover: ((Bool) -> Void)?
        private var pressStart: CGPoint?
        /// A drag out of the panel began: letting go is then no longer a click.
        private var dragging = false
        private var tracking: NSTrackingArea?
        private var observer: NSObjectProtocol?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { report(hovering: true) }
        override func mouseExited(with event: NSEvent) { report(hovering: false) }

        override func mouseMoved(with event: NSEvent) {
            report(hovering: bounds.contains(convert(event.locationInWindow, from: nil)))
        }

        private var hovering = false

        private func report(hovering: Bool) {
            guard hovering != self.hovering else { return }
            self.hovering = hovering
            onHover?(hovering)
        }

        /// Cards shift under a still pointer (a new capture, a reordered entry) and
        /// AppKit sends no exit for that, leaving the card lit. So after a move, a
        /// card that no longer has the pointer over it lets go of the hover. Only
        /// ever clears: a card never claims the pointer from here, since a card's
        /// frame is briefly wrong mid-layout and every card would claim it at once.
        private func dropStaleHover() {
            guard hovering else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let window, window.isVisible, !bounds.isEmpty else { report(hovering: false); return }
                let onScreen = window.convertToScreen(convert(bounds, to: nil))
                if !onScreen.contains(NSEvent.mouseLocation) { report(hovering: false) }
            }
        }

        override func layout() {
            super.layout()
            dropStaleHover()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            // Leaving the window drops the observer with it; nothing is left behind.
            guard let window else { report(hovering: false); return }
            // A card lit when the panel lost the keyboard (a capture overlay, another
            // app) must not stay lit behind it.
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(hovering: false) }
            }
        }


        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            dropStaleHover()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            dropStaleHover()
        }

        override func mouseDown(with event: NSEvent) {
            pressStart = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = pressStart, !dragging else { return }
            let dx = event.locationInWindow.x - start.x, dy = event.locationInWindow.y - start.y
            // A press that wanders less than this is a click, not a drag: on a trackpad
            // the pointer always moves a little between pressing and letting go.
            guard hypot(dx, dy) >= 10 else { return }
            // Nothing to carry out (an entry whose contents cannot be read): the press
            // stays a press, so letting go still copies.
            guard let payload = payload?() else { return }
            dragging = true
            IslandDrag.current = payload.reference
            let item = NSDraggingItem(pasteboardWriter: payload.writer)
            let image = payload.preview
            let side: CGFloat = 140
            let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let local = convert(start, from: nil)
            item.setDraggingFrame(CGRect(x: local.x - size.width / 2, y: local.y - size.height / 2, width: size.width, height: size.height), contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            let pressed = pressStart != nil && !dragging
            pressStart = nil
            guard pressed else { return }
            onClick?()
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            NSCursor.closedHand.set()
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            NSCursor.closedHand.set()
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            NSCursor.arrow.set()
            dragging = false
            pressStart = nil
            DispatchQueue.main.async { IslandDrag.current = nil }
        }
    }
}
