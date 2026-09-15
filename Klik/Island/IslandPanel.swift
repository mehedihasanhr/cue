import AppKit
import SwiftUI

enum IslandTab: String, CaseIterable {
    case captures, clipboard

    var title: String {
        switch self {
        case .captures: "Captures"
        case .clipboard: "Clipboard"
        }
    }

    var symbol: String {
        switch self {
        case .captures: "photo.on.rectangle"
        case .clipboard: "doc.on.clipboard"
        }
    }
}

/// What the open island shows: search and the capture buttons on top, a row of tabs,
/// then the captures or the clipboard history as cards in a horizontal row grouped
/// by day, newest first. The row scrolls by dragging (or with the trackpad).
struct IslandPanel: View {
    static let size = CGSize(width: 780, height: 316)

    let library: CaptureLibrary
    let clipboard: ClipboardHistory
    let actions: HistoryActions
    @State private var search = ""
    @AppStorage("island.tab") private var tab: IslandTab = .captures

    private var filteredCaptures: [CaptureItem] {
        guard !search.isEmpty else { return library.items }
        return library.items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private var filteredClipboard: [ClipboardItem] {
        guard !search.isEmpty else { return clipboard.items }
        return clipboard.items.filter { $0.text.localizedCaseInsensitiveContains(search) || ($0.sourceName?.localizedCaseInsensitiveContains(search) ?? false) }
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
            }

            HStack(spacing: 8) {
                tabPill(.captures, count: library.items.count)
                tabPill(.clipboard, count: clipboard.items.count)
                Spacer(minLength: 0)
                if tab == .clipboard, clipboard.items.contains(where: { !$0.pinned }) {
                    Button {
                        clipboard.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Remove every unpinned item")
                }
            }

            switch tab {
            case .captures:
                if filteredCaptures.isEmpty {
                    empty(search.isEmpty ? "No captures yet" : "No matches", symbol: "camera.viewfinder")
                } else {
                    DayStrip(items: filteredCaptures, date: \.createdAt) { item in
                        CaptureCard(item: item, library: library, actions: actions)
                    }
                }
            case .clipboard:
                if filteredClipboard.isEmpty {
                    empty(search.isEmpty ? "Nothing copied yet" : "No matches", symbol: "doc.on.clipboard")
                } else {
                    DayStrip(items: filteredClipboard, date: \.createdAt) { item in
                        ClipboardCard(item: item, clipboard: clipboard)
                    }
                }
            }
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
    }

    private func empty(_ message: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
            Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @ViewBuilder let card: (Item) -> Card

    static var cardSize: CGSize { CGSize(width: 200, height: 160) }
    static var spacing: CGFloat { 10 }
    static var groupSpacing: CGFloat { 22 }
    static var headerHeight: CGFloat { 24 }

    @State private var offset: CGFloat = 0
    @State private var dragOrigin: CGFloat?

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
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if dragOrigin == nil { dragOrigin = offset }
                        self.offset = min(max((dragOrigin ?? 0) - value.translation.width, 0), maxOffset)
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .background(ScrollWheelObserver { delta in
                self.offset = min(max(offset + delta, 0), maxOffset)
            })
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
                if hovering {
                    HStack(spacing: 6) { actionRow() }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .transition(.opacity)
                }
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

private struct CaptureCard: View {
    let item: CaptureItem
    let library: CaptureLibrary
    let actions: HistoryActions
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
            CardAction(symbol: "eye", help: "Preview") { actions.preview(item) }
            CardAction(symbol: "pencil", help: "Edit") { actions.edit(item) }
            CopyAction { actions.copy(item) }
            CardAction(symbol: "trash", help: "Delete", tint: .red) { actions.delete(item) }
        } menu: {
            Button("Preview") { actions.preview(item) }
            Button("Edit") { actions.edit(item) }
            Button("Copy to Clipboard") { actions.copy(item) }
            Divider()
            Button("Delete", role: .destructive) { actions.delete(item) }
        }
    }
}

private struct ClipboardCard: View {
    let item: ClipboardItem
    let clipboard: ClipboardHistory
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, onTap: paste) {
            content
                .overlay(alignment: .bottom) {
                    CardCaption(title: "", date: item.createdAt) {
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
            CardAction(symbol: item.pinned ? "star.fill" : "star", help: item.pinned ? "Unpin" : "Pin", tint: item.pinned ? .yellow : .white) {
                clipboard.togglePin(item)
            }
            CardAction(symbol: "trash", help: "Delete", tint: .red) { clipboard.delete(item) }
        } menu: {
            if clipboard.canPaste { Button("Paste") { paste() } }
            Button("Copy") { copy() }
            Button(item.pinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
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

// MARK: - Scroll wheel

/// Reports horizontal scroll-wheel / trackpad deltas over its own bounds. SwiftUI
/// offers no scroll-wheel hook for a hand-rolled strip, so this watches the app's
/// scroll events while it is on screen and keeps the ones that land on it.
private struct ScrollWheelObserver: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onScroll = onScroll
    }

    final class ObserverView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        /// Installed while on screen; `viewDidMoveToWindow` with a nil window (the
        /// island collapsing) removes it, so nothing is left behind.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return event }
                let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
                self.onScroll?(event.hasPreciseScrollingDeltas ? -delta : -delta * 8)
                return nil
            }
        }
    }
}
