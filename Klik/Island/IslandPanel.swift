import AppKit
import SwiftUI

enum IslandTab: String, CaseIterable {
    case captures, clipboard, assets, colors, tasks

    static let storageKey = "island.tab"

    var title: String {
        switch self {
        case .captures: "Captures"
        case .clipboard: "Clipboard"
        case .assets: "Assets"
        case .colors: "Colours"
        case .tasks: "Tasks"
        }
    }

    var symbol: String {
        switch self {
        case .captures: "photo.on.rectangle"
        case .clipboard: "doc.on.clipboard"
        case .assets: "tray.full"
        case .colors: "paintpalette"
        case .tasks: "checklist"
        }
    }
}

/// What the open island shows: search and the capture buttons on top, a row of tabs,
/// then the captures, the clipboard history or the assets as cards in a horizontal
/// row grouped by day, newest first. The row scrolls by dragging (or with the trackpad).
struct IslandPanel: View {
    static let size = CGSize(width: 780, height: 316)

    let library: CaptureLibrary
    let clipboard: ClipboardHistory
    let assets: AssetStore
    let colors: ColorStore
    let tasksStore: TaskStore
    let actions: HistoryActions
    @Environment(AppPreferences.self) private var preferences
    /// A file or image is being dragged over the island.
    var dropping = false
    /// Asks the island for a line of text in its compact form.
    var onPrompt: (IslandPrompt) -> Void = { _ in }
    /// Opens a task in the compact island.
    var onShowTask: (TaskItem) -> Void = { _ in }
    @State private var search = ""
    /// A card opened in place of the row.
    @State private var detail: IslandDetail?
    /// Pending hover switch of the tabs (cancelled if the pointer moves on).
    @State private var hoverSwitch: Task<Void, Never>?
    @AppStorage(IslandTab.storageKey) private var tab: IslandTab = .captures

    private var filteredCaptures: [CaptureItem] {
        guard !search.isEmpty else { return library.items }
        return library.items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private var filteredClipboard: [ClipboardItem] {
        guard !search.isEmpty else { return clipboard.items }
        return clipboard.items.filter { $0.text.localizedCaseInsensitiveContains(search) || ($0.sourceName?.localizedCaseInsensitiveContains(search) ?? false) }
    }

    private var filteredAssets: [AssetItem] {
        guard !search.isEmpty else { return assets.items }
        return assets.items.filter { $0.fileName.localizedCaseInsensitiveContains(search) }
    }

    private var filteredColors: [ColorEntry] {
        guard !search.isEmpty else { return colors.items }
        return colors.items.filter { ColorFormat.hex.string(for: $0.color).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                circle("gearshape", help: "Settings", action: actions.openSettings)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    TextField("Search", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.white.opacity(0.08), in: Capsule(style: .continuous))
                Spacer(minLength: 8)
                circle("display", help: "Capture full screen", action: actions.captureFullScreen)
                circle("viewfinder", help: "Capture area", action: actions.captureArea)
                circle("rectangle.expand.vertical", help: "Scrolling capture", action: actions.captureScrolling)
                circle("text.viewfinder", help: "Capture text", action: actions.captureText)
                circle("eyedropper", help: "Pick a colour", action: actions.pickColor)
            }

            if let detail {
                IslandDetailHeader(detail: detail, library: library, assets: assets, actions: actions) {
                    withAnimation(.easeOut(duration: 0.15)) { self.detail = nil }
                }
            } else {
            HStack(spacing: 8) {
                tabPill(.captures, count: library.items.count)
                tabPill(.clipboard, count: clipboard.items.count)
                tabPill(.assets, count: assets.items.count)
                tabPill(.colors, count: colors.items.count)
                tabPill(.tasks, count: tasksStore.tasks.filter { $0.status != .complete }.count)
                Spacer(minLength: 0)
                if tab == .colors {
                    smallButton("Pick", symbol: "eyedropper", help: "Pick a colour from the screen", action: actions.pickColor)
                }
                if tab == .clipboard, clipboard.items.contains(where: { !$0.pinned }) {
                    smallButton("Clear", symbol: "trash", help: "Remove every unpinned item") { clipboard.clear() }
                }
                if tab == .assets {
                    smallButton("Paste", symbol: "doc.on.clipboard", help: "Save the image or files on the clipboard as assets") {
                        if let added = assets.addFromPasteboard() {
                            FeedbackHUD.show(added.count == 1 ? "Saved to Assets" : "\(added.count) saved to Assets", symbol: "tray.and.arrow.down.fill", duration: .seconds(1.2))
                        } else {
                            FeedbackHUD.show("No image or file on the clipboard", symbol: "tray")
                        }
                    }
                }
            }
            }

            ZStack {
                if let detail {
                    IslandDetailBody(detail: detail, library: library, clipboard: clipboard, assets: assets, colors: colors, actions: actions)
                        .transition(.opacity)
                } else {
                switch tab {
                case .captures:
                    if filteredCaptures.isEmpty {
                        empty(search.isEmpty ? "No captures yet" : "No matches", symbol: "camera.viewfinder")
                    } else {
                        DayStrip(items: filteredCaptures, date: \.createdAt, dragPayload: { item in
                            library.fileURL(for: item).map { .file($0, preview: library.thumbnail(for: item)) }
                        }) { item in
                            CaptureCard(item: item, library: library, actions: actions, clipboard: clipboard, onPreview: { open(.capture(item)) }, onRename: {
                                onPrompt(IslandPrompt(kind: .rename(.capture(item)), initial: item.title.replacingOccurrences(of: "Screenshot ", with: ""), image: library.thumbnail(for: item)))
                            })
                        }
                    }
                case .clipboard:
                    if filteredClipboard.isEmpty {
                        empty(search.isEmpty ? "Nothing copied yet" : "No matches", symbol: "doc.on.clipboard")
                    } else {
                        DayStrip(items: filteredClipboard, date: \.createdAt, dragPayload: { item in
                            clipboard.dragPayload(for: item)
                        }) { item in
                            ClipboardCard(item: item, clipboard: clipboard, onPreview: { open(.clipboard(item)) }, onRename: {
                                onPrompt(IslandPrompt(kind: .rename(.clipboard(item)), initial: item.name ?? "", image: clipboard.thumbnail(for: item),
                                                      swatch: item.kind == .color ? PickedColor(hex: item.text) : nil))
                            })
                        }
                    }
                case .tasks:
                    IslandTasksView(store: tasksStore, onPrompt: onPrompt, onShowTask: onShowTask)
                case .colors:
                    if filteredColors.isEmpty {
                        empty(search.isEmpty ? "Pick a colour anywhere on screen with the eyedropper" : "No matches", symbol: "eyedropper")
                    } else {
                        DayStrip(items: filteredColors, date: \.createdAt, dragPayload: { entry in
                            DragPayload(writer: preferences.colorFormat.string(for: entry.color) as NSString, preview: ColorCard.dragImage(for: entry.color))
                        }) { entry in
                            ColorCard(entry: entry, colors: colors, format: preferences.colorFormat, onPreview: { open(.color(entry)) }, onRename: {
                                onPrompt(IslandPrompt(kind: .rename(.color(entry)), initial: entry.name ?? "", swatch: entry.color))
                            })
                        }
                    }
                case .assets:
                    if filteredAssets.isEmpty {
                        empty(search.isEmpty ? "Drop images or files here to keep them handy" : "No matches", symbol: "tray.and.arrow.down")
                    } else {
                        DayStrip(items: filteredAssets, date: \.createdAt, dragPayload: { item in
                            .file(assets.fileURL(for: item), preview: assets.thumbnail(for: item))
                        }) { item in
                            AssetCard(item: item, assets: assets, clipboard: clipboard, onPreview: { open(.asset(item)) }, onRename: {
                                onPrompt(IslandPrompt(kind: .rename(.asset(item)), initial: item.title, image: assets.thumbnail(for: item)))
                            })
                        }
                    }
                }
                }
                if dropping {
                    dropHint
                }
            }
            .frame(height: Self.rowHeight) // the same whether a tab has cards or not
            .onChange(of: tab) { _, _ in detail = nil }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func circle(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Tabs switch after the pointer rests on them for 250 ms (a click is immediate).
    private func tabPill(_ value: IslandTab, count: Int) -> some View {
        let selected = tab == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { tab = value }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: value.symbol).font(.system(size: 11, weight: .semibold))
                Text(value.title).font(.system(size: 12, weight: .semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((selected ? Color.black : Color.white).opacity(0.12), in: Capsule())
                }
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(selected ? Color.white : Color.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoverSwitch?.cancel()
            guard inside, tab != value else { return }
            hoverSwitch = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.15)) { tab = value }
            }
        }
    }

    private func open(_ detail: IslandDetail) {
        withAnimation(.easeOut(duration: 0.15)) { self.detail = detail }
    }

    private func smallButton(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.white.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Shown over the row while a drag hovers the island.
    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.black.opacity(0.75))
            .background(Color.brand.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.brand, style: SwiftUI.StrokeStyle(lineWidth: 2, dash: [8, 6])))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 28)).foregroundStyle(.white)
                    Text("Drop to save as an asset").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// Height of the card row: header plus cards.
    static var rowHeight: CGFloat { DayStrip<CaptureItem, EmptyView>.headerHeight + DayStrip<CaptureItem, EmptyView>.cardSize.height }

    private func empty(_ message: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
            Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.rowHeight)
    }
}

// MARK: - Day strip

/// Horizontal row of day groups ("Today", "Yesterday", "Wed, Jul 22"). Dragging
/// anywhere on it scrolls; the scroll wheel / trackpad works too. Every card has the
/// same width, so positions are arithmetic and only the cards in view are built —
/// a history of thousands costs the same as one of ten.
struct DayStrip<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let date: KeyPath<Item, Date>
    /// What a card puts on the drag pasteboard, if it can be dragged out. A vertical
    /// drag on a card then drags it into other apps; a horizontal drag scrolls the row.
    var dragPayload: ((Item) -> DragPayload?)? = nil
    @ViewBuilder let card: (Item) -> Card

    static var cardSize: CGSize { CGSize(width: 200, height: 160) }
    static var spacing: CGFloat { 10 }
    static var groupSpacing: CGFloat { 22 }
    static var headerHeight: CGFloat { 24 }

    @State private var offset: CGFloat = 0
    @State private var dragOrigin: CGFloat?
    @State private var dragMode: DragMode?

    private enum DragMode { case scroll, dragOut }

    private struct PlacedGroup: Identifiable {
        let id: Date
        let title: String
        let x: CGFloat
        var width: CGFloat
    }

    private struct PlacedCard: Identifiable {
        let item: Item
        let x: CGFloat
        var id: Item.ID { item.id }
    }

    private struct Layout {
        var groups: [PlacedGroup] = []
        var cards: [PlacedCard] = []
        var width: CGFloat = 0
    }

    private var layout: Layout {
        let calendar = Calendar.current
        var layout = Layout()
        var x: CGFloat = 0
        var currentDay: Date?
        for item in items {
            let day = calendar.startOfDay(for: item[keyPath: date])
            if day != currentDay {
                if currentDay != nil { x += Self.groupSpacing - Self.spacing }
                layout.groups.append(PlacedGroup(id: day, title: Self.title(for: day, calendar: calendar), x: x, width: 0))
                currentDay = day
            }
            layout.cards.append(PlacedCard(item: item, x: x))
            x += Self.cardSize.width + Self.spacing
            layout.groups[layout.groups.count - 1].width = x - Self.spacing - layout.groups[layout.groups.count - 1].x
        }
        layout.width = max(0, x - Self.spacing)
        return layout
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: .now)
        return day.formatted(sameYear ? .dateTime.weekday(.abbreviated).month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = layout
            let maxOffset = max(0, layout.width - proxy.size.width)
            let offset = min(offset, maxOffset)
            let visible = (offset - Self.cardSize.width)...(offset + proxy.size.width + Self.cardSize.width)
            ZStack(alignment: .topLeading) {
                ForEach(layout.groups.filter { visible.overlaps($0.x...($0.x + $0.width)) }) { group in
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(height: Self.headerHeight, alignment: .leading)
                        .offset(x: group.x - offset)
                }
                ForEach(layout.cards.filter { visible.contains($0.x) }) { placed in
                    card(placed.item)
                        .offset(x: placed.x - offset, y: Self.headerHeight)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            // Horizontal drags scroll the row. Vertical ones are taken by the AppKit
            // layer underneath before SwiftUI's gesture settles (see StripEventView).
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if dragMode == nil {
                            let dx = value.translation.width, dy = value.translation.height
                            guard hypot(dx, dy) >= StripEventView.decisionDistance else { return }
                            guard !StripEventView.isDragOut(dx: dx, dy: dy) else { dragMode = .dragOut; return }
                            dragMode = .scroll
                            dragOrigin = offset
                            NSCursor.closedHand.set()
                        }
                        guard dragMode == .scroll else { return }
                        self.offset = min(max((dragOrigin ?? 0) - value.translation.width, 0), maxOffset)
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        dragMode = nil
                        NSCursor.arrow.set()
                    }
            )
            .background(StripEventView(payloadAt: { point in
                guard point.y >= Self.headerHeight, let dragPayload,
                      let placed = layout.cards.first(where: { ($0.x - offset...$0.x - offset + Self.cardSize.width).contains(point.x) })
                else { return nil }
                return dragPayload(placed.item)
            }, onScroll: { delta in
                self.offset = min(max(offset + delta, 0), maxOffset)
            }, onDragBegan: { dragMode = .dragOut }, onDragEnded: { dragMode = nil }))
        }
        .frame(height: Self.headerHeight + Self.cardSize.height)
        .clipped()
    }
}

// MARK: - Cards

/// Rounded card chrome shared by captures and clipboard items: blue border on hover,
/// circular action buttons at the top, click and context menu.
private struct CardChrome<Content: View, Actions: View, Menu: View>: View {
    @Binding var hovering: Bool
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actionRow: () -> Actions
    @ViewBuilder let menu: () -> Menu

    private static var radius: CGFloat { 18 }

    var body: some View {
        content()
            .overlay(alignment: .top) {
                // Always in the tree (faded out, not hit-testable) so a drag started
                // from the row survives the pointer leaving the card.
                HStack(spacing: 6) { actionRow() }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            .frame(width: DayStrip<CaptureItem, EmptyView>.cardSize.width, height: DayStrip<CaptureItem, EmptyView>.cardSize.height)
            .background(.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(hovering ? Color.brand : .white.opacity(0.1), lineWidth: hovering ? 2 : 1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onTapGesture(perform: onTap)
            .contextMenu { menu() }
    }
}

/// A circular button for the card's hover row.
private struct CardAction: View {
    let symbol: String
    let help: String
    var tint: Color = .white
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(help)
    }
}

/// Copy button that turns into a green tick for a moment.
private struct CopyAction: View {
    let perform: () -> Void
    @State private var copied = false

    var body: some View {
        CardAction(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy to clipboard", tint: copied ? .green : .white) {
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            perform()
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation { copied = false }
            }
        }
    }
}

/// Small caption over a short gradient at the foot of a card: the content is the
/// point, the caption only helps telling cards apart.
private struct CardCaption<Leading: View>: View {
    let title: String
    let date: Date
    @ViewBuilder let trailing: () -> Leading

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
            HStack(alignment: .center, spacing: 6) {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
                trailing()
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.45), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .padding(.top, -16)
        )
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.white.opacity(0.16), in: Capsule())
            .fixedSize()
    }
}

struct CaptureCard: View {
    let item: CaptureItem
    let library: CaptureLibrary
    let actions: HistoryActions
    /// For pasting straight into the front app / an open Klik editor.
    var clipboard: ClipboardHistory? = nil
    var onPreview: () -> Void = {}
    var onRename: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, onTap: { actions.edit(item) }) {
            Color.clear
                .overlay {
                    if let thumbnail = library.thumbnail(for: item) {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
                .clipped()
                .overlay(alignment: .bottom) {
                    CardCaption(title: item.title.replacingOccurrences(of: "Screenshot ", with: ""), date: item.createdAt) {
                        Badge(text: item.dimensions)
                    }
                }
        } actionRow: {
            if let clipboard, clipboard.canPaste {
                CardAction(symbol: "arrow.down.doc", help: "Paste", perform: paste)
            }
            CardAction(symbol: "eye", help: "Preview", perform: onPreview)
            CardAction(symbol: "pencil", help: "Edit") { actions.edit(item) }
            CopyAction { actions.copy(item) }
            CardAction(symbol: "trash", help: "Delete", tint: .red) { actions.delete(item) }
        } menu: {
            if let clipboard, clipboard.canPaste { Button("Paste", action: paste) }
            Button("Preview") { actions.preview(item) }
            Button("Edit") { actions.edit(item) }
            Button("Copy to Clipboard") { actions.copy(item) }
            Button("Rename…", action: onRename)
            Divider()
            Button("Delete", role: .destructive) { actions.delete(item) }
        }
    }

    private func paste() {
        actions.copy(item)
        if clipboard?.pressPaste() == true {
            FeedbackHUD.show("Pasted", symbol: "checkmark.circle.fill", duration: .seconds(1.0))
        }
    }
}

struct ClipboardCard: View {
    let item: ClipboardItem
    let clipboard: ClipboardHistory
    var onPreview: () -> Void = {}
    var onRename: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, onTap: paste) {
            content
                .overlay(alignment: .bottom) {
                    CardCaption(title: item.name ?? "", date: item.createdAt) {
                        if item.pinned {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                        }
                        if let icon = clipboard.sourceIcon(for: item) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                                .help(item.sourceName ?? "")
                        }
                    }
                }
        } actionRow: {
            if clipboard.canPaste {
                CardAction(symbol: "arrow.down.doc", help: "Paste into the front app", perform: paste)
            }
            CopyAction(perform: copy)
            CardAction(symbol: "eye", help: "Preview", perform: onPreview)
            CardAction(symbol: item.pinned ? "star.fill" : "star", help: item.pinned ? "Unpin" : "Pin", tint: item.pinned ? .yellow : .white) {
                clipboard.togglePin(item)
            }
            CardAction(symbol: "trash", help: "Delete", tint: .red) { clipboard.delete(item) }
        } menu: {
            if clipboard.canPaste { Button("Paste") { paste() } }
            Button("Copy") { copy() }
            if item.kind == .color, let color = PickedColor(hex: item.text) {
                Menu("Copy as") {
                    ForEach(ColorFormat.allCases, id: \.self) { format in
                        Button(format.string(for: color)) {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(format.string(for: color), forType: .string)
                            FeedbackHUD.show("\(format.string(for: color)) copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
                        }
                    }
                }
            }
            Button(item.pinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
            Button(item.name == nil ? "Name…" : "Rename…", action: onRename)
            Divider()
            Button("Delete", role: .destructive) { clipboard.delete(item) }
        }
    }

    private func copy() {
        clipboard.copy(item)
        FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
    }

    /// Click: paste straight into the front app when Accessibility allows it,
    /// otherwise copy and say so.
    private func paste() {
        if clipboard.paste(item) {
            FeedbackHUD.show("Pasted", symbol: "checkmark.circle.fill", duration: .seconds(1.0))
        } else {
            FeedbackHUD.show("Copied — press ⌘V to paste", symbol: "doc.on.clipboard", duration: .seconds(1.6))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(7)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 11, weight: .semibold))
                    Text(URL(string: item.text)?.host ?? item.text).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(.white)
                Text(item.text)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
        case .color:
            let components = item.colorComponents ?? (0.5, 0.5, 0.5)
            Color(red: components.red, green: components.green, blue: components.blue)
                .overlay(alignment: .topLeading) {
                    Text(item.text)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(12)
                }
        case .image:
            Color.clear
                .overlay {
                    if let thumbnail = clipboard.thumbnail(for: item) {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if !hovering { Badge(text: item.dimensions).padding(8) }
                }
        case .files:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: item.filePaths.count > 1 ? "doc.on.doc" : "doc").font(.system(size: 12, weight: .semibold))
                    Text(item.filePaths.count > 1 ? "\(item.filePaths.count) files" : "File").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                ForEach(item.filePaths.prefix(4), id: \.self) { path in
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
        }
    }
}

struct AssetCard: View {
    let item: AssetItem
    let assets: AssetStore
    var clipboard: ClipboardHistory? = nil
    var onPreview: () -> Void = {}
    var onRename: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, onTap: { assets.open(item) }) {
            content
                .overlay(alignment: .bottom) {
                    CardCaption(title: item.fileName, date: item.createdAt) {
                        Badge(text: item.kind == .image && item.pixelWidth > 0 ? item.dimensions : item.sizeText)
                    }
                }
        } actionRow: {
            if let clipboard, clipboard.canPaste {
                CardAction(symbol: "arrow.down.doc", help: "Paste", perform: paste)
            }
            CardAction(symbol: "eye", help: "Preview", perform: onPreview)
            CardAction(symbol: "arrow.up.forward.app", help: "Open") { assets.open(item) }
            CopyAction { assets.copy(item) }
            CardAction(symbol: "trash", help: "Delete", tint: .red) { assets.delete(item) }
        } menu: {
            if let clipboard, clipboard.canPaste { Button("Paste", action: paste) }
            Button("Open") { assets.open(item) }
            Button("Copy") { assets.copy(item) }
            Button("Reveal in Finder") { assets.reveal(item) }
            Button("Rename…", action: onRename)
            Divider()
            Button("Delete", role: .destructive) { assets.delete(item) }
        }
    }

    private func paste() {
        assets.copy(item)
        if clipboard?.pressPaste() == true {
            FeedbackHUD.show("Pasted", symbol: "checkmark.circle.fill", duration: .seconds(1.0))
        }
    }

    @ViewBuilder
    private var content: some View {
        if item.kind == .image {
            Color.clear
                .overlay {
                    if let thumbnail = assets.thumbnail(for: item) {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
                .clipped()
        } else {
            VStack(spacing: 8) {
                if let icon = assets.thumbnail(for: item) {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                }
                Text((item.fileName as NSString).pathExtension.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 24)
        }
    }
}

/// A picked colour: the swatch fills the card, the preferred format is the caption.
struct ColorCard: View {
    let entry: ColorEntry
    let colors: ColorStore
    let format: ColorFormat
    var onPreview: () -> Void = {}
    var onRename: () -> Void = {}
    @Environment(AppPreferences.self) private var preferences
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, onTap: onPreview) {
            entry.color.swiftUIColor
                .overlay(alignment: .topLeading) {
                    if !entry.color.isInSRGBGamut {
                        Text("P3")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(entry.color.isDark ? .white : .black)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background((entry.color.isDark ? Color.white : Color.black).opacity(0.2), in: Capsule())
                            .padding(8)
                            .help("Outside the sRGB gamut — a Display P3 colour")
                    }
                }
                .overlay(alignment: .bottom) {
                    CardCaption(title: entry.name ?? format.string(for: entry.color), date: entry.createdAt) {
                        if entry.name != nil || format != .hex { Badge(text: ColorFormat.hex.string(for: entry.color)) }
                    }
                }
        } actionRow: {
            CopyAction { copy(as: format) }
            CardAction(symbol: "eye", help: "Preview", perform: onPreview)
            CardAction(symbol: "trash", help: "Delete", tint: .red) { colors.delete(entry) }
        } menu: {
            Button("Copy \(format.title)") { copy(as: format) }
            Menu("Copy as") {
                ForEach(ColorFormat.allCases, id: \.self) { other in
                    Button(other.string(for: entry.color)) { copy(as: other) }
                }
            }
            Button(entry.name == nil ? "Name…" : "Rename…", action: onRename)
            Divider()
            Button("Delete", role: .destructive) { colors.delete(entry) }
        }
    }

    private func copy(as format: ColorFormat) {
        colors.copy(entry, as: format)
        preferences.colorFormat = format // the next copy uses the format used last
        FeedbackHUD.show("\(format.string(for: entry.color)) copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
    }

    /// A swatch for dragging the colour's text.
    static func dragImage(for color: PickedColor) -> NSImage {
        let (r, g, b) = color.clamped
        return NSImage(size: NSSize(width: 60, height: 60), flipped: false) { rect in
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            return true
        }
    }
}

// MARK: - Row events

/// What a dragged card writes to the drag pasteboard, and the image under the pointer.
struct DragPayload {
    let writer: any NSPasteboardWriting
    let preview: NSImage

    /// A file: other apps get a file URL carrying the sandbox extension they need to
    /// read a file in Klik's container.
    static func file(_ url: URL, preview: NSImage?) -> DragPayload {
        DragPayload(writer: url as NSURL, preview: preview ?? NSWorkspace.shared.icon(forFile: url.path))
    }
}

/// The AppKit side of the row: starts drags out of the island and reports
/// scroll-wheel / trackpad deltas over its bounds (SwiftUI offers no scroll-wheel
/// hook for a hand-rolled strip).
///
/// Drags start here, from a local event monitor, rather than from a SwiftUI gesture:
/// the monitor sees the mouse-down and the first drag events before the window
/// dispatches them, so a card leaves the island on the first vertical movement —
/// whether or not the island is the key window, mid-animation, and without waiting
/// for SwiftUI to settle its gesture. The AppKit session writes a file URL, which
/// carries the sandbox extension other apps need to read a file in Klik's container.
private struct StripEventView: NSViewRepresentable {
    /// How far the pointer moves before a press becomes a drag-out or a scroll.
    static let decisionDistance: CGFloat = 5
    /// Anything steeper than ~30° from horizontal drags the card out; flatter scrolls.
    static func isDragOut(dx: CGFloat, dy: CGFloat) -> Bool { abs(dy) > abs(dx) * 0.6 }

    /// The payload for the card under a point (top-left origin, strip coordinates).
    var payloadAt: (CGPoint) -> DragPayload?
    var onScroll: (CGFloat) -> Void
    var onDragBegan: () -> Void
    var onDragEnded: () -> Void

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        update(view)
        return view
    }

    func updateNSView(_ view: EventView, context: Context) {
        update(view)
    }

    private func update(_ view: EventView) {
        view.payloadAt = payloadAt
        view.onScroll = onScroll
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
    }

    final class EventView: NSView, NSDraggingSource {
        var payloadAt: ((CGPoint) -> DragPayload?)?
        var onScroll: ((CGFloat) -> Void)?
        var onDragBegan: (() -> Void)?
        var onDragEnded: (() -> Void)?
        private var monitor: Any?
        /// Where the current press started (window coordinates), until it is
        /// classified as a drag-out or handed to SwiftUI as a scroll.
        private var pressStart: CGPoint?

        /// Installed while on screen; `viewDidMoveToWindow` with a nil window (the
        /// island collapsing) removes it, so nothing is left behind.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                // Local monitors run on the main thread; the event stays there too.
                nonisolated(unsafe) var result: NSEvent? = event
                MainActor.assumeIsolated { result = self.handle(event) }
                return result
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .scrollWheel:
                guard event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
                let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
                onScroll?(event.hasPreciseScrollingDeltas ? -delta : -delta * 8)
                return nil
            case .leftMouseDown:
                pressStart = event.window === window && bounds.contains(convert(event.locationInWindow, from: nil)) ? event.locationInWindow : nil
                return event
            case .leftMouseDragged:
                guard let start = pressStart, event.window === window else { return event }
                let dx = event.locationInWindow.x - start.x, dy = event.locationInWindow.y - start.y
                guard hypot(dx, dy) >= StripEventView.decisionDistance else { return event }
                pressStart = nil
                guard StripEventView.isDragOut(dx: dx, dy: dy) else { return event } // SwiftUI scrolls
                let local = convert(start, from: nil)
                guard let payload = payloadAt?(CGPoint(x: local.x, y: bounds.height - local.y)) else { return event }
                onDragBegan?()
                beginDrag(payload, at: local, event: event)
                return nil
            case .leftMouseUp:
                pressStart = nil
                return event
            default:
                return event
            }
        }

        private func beginDrag(_ payload: DragPayload, at location: CGPoint, event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: payload.writer)
            let image = payload.preview
            let side: CGFloat = 140
            let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            item.setDraggingFrame(CGRect(x: location.x - size.width / 2, y: location.y - size.height / 2, width: size.width, height: size.height), contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        // The grabbing hand for the whole drag; the drag manager keeps resetting the
        // cursor, so it is set again on every move.
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            NSCursor.closedHand.set()
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            NSCursor.closedHand.set()
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            NSCursor.arrow.set()
            onDragEnded?()
        }
    }
}
