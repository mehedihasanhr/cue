import AppKit
import SwiftUI

/// What the open island shows: search and the capture buttons on top, then the
/// captures as cards in a horizontal row grouped by day, newest first. The row
/// scrolls by dragging (or with the trackpad).
struct IslandPanel: View {
    static let size = CGSize(width: 780, height: 272)

    let library: CaptureLibrary
    let actions: HistoryActions
    @State private var search = ""

    private var filtered: [CaptureItem] {
        guard !search.isEmpty else { return library.items }
        return library.items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
                    Text(search.isEmpty ? "No captures yet" : "No matches")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CardStrip(items: filtered, library: library, actions: actions)
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
}

// MARK: - Strip

/// Horizontal row of day groups. Dragging anywhere on it scrolls; the scroll wheel /
/// trackpad works too. Clicking a card opens the editor; hovering shows the actions.
private struct CardStrip: View {
    let items: [CaptureItem]
    let library: CaptureLibrary
    let actions: HistoryActions

    static let card = CGSize(width: 200, height: 160)
    static let spacing: CGFloat = 10
    static let groupSpacing: CGFloat = 22
    static let headerHeight: CGFloat = 24

    @State private var offset: CGFloat = 0
    @State private var dragOrigin: CGFloat?

    private struct Group: Identifiable {
        let id: Date
        let title: String
        let items: [CaptureItem]
    }

    private var groups: [Group] {
        let calendar = Calendar.current
        var result: [Group] = []
        for item in items {
            let day = calendar.startOfDay(for: item.createdAt)
            if let index = result.firstIndex(where: { $0.id == day }) {
                result[index] = Group(id: day, title: result[index].title, items: result[index].items + [item])
            } else {
                result.append(Group(id: day, title: Self.title(for: day, calendar: calendar), items: [item]))
            }
        }
        return result
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: .now)
        return day.formatted(sameYear ? .dateTime.weekday(.abbreviated).month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    private var contentWidth: CGFloat {
        let groups = groups
        let cards = CGFloat(items.count) * Self.card.width + CGFloat(max(0, items.count - groups.count)) * Self.spacing
        return cards + CGFloat(max(0, groups.count - 1)) * Self.groupSpacing
    }

    var body: some View {
        GeometryReader { proxy in
            let maxOffset = max(0, contentWidth - proxy.size.width)
            HStack(alignment: .top, spacing: Self.groupSpacing) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(height: Self.headerHeight, alignment: .leading)
                        HStack(spacing: Self.spacing) {
                            ForEach(group.items) { item in
                                Card(item: item, library: library, actions: actions)
                            }
                        }
                    }
                }
            }
            .offset(x: -min(offset, maxOffset))
            .frame(width: proxy.size.width, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if dragOrigin == nil { dragOrigin = offset }
                        offset = min(max((dragOrigin ?? 0) - value.translation.width, 0), maxOffset)
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .background(ScrollWheelObserver { delta in
                offset = min(max(offset + delta, 0), maxOffset)
            })
        }
        .frame(height: Self.headerHeight + Self.card.height)
        .clipped()
    }
}

private struct Card: View {
    let item: CaptureItem
    let library: CaptureLibrary
    let actions: HistoryActions
    @State private var hovering = false
    @State private var copied = false

    private static let radius: CGFloat = 18

    var body: some View {
        Color.clear
            .overlay {
                if let thumbnail = library.thumbnail(for: item) {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.1)
                }
            }
            .clipped()
            .overlay(alignment: .bottom) { caption }
            .overlay(alignment: .top) {
                if hovering { actionRow.transition(.opacity) }
            }
            .frame(width: CardStrip.card.width, height: CardStrip.card.height)
            .background(.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(hovering ? Color.brand : .white.opacity(0.1), lineWidth: hovering ? 2 : 1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onTapGesture { actions.edit(item) }
            .contextMenu {
                Button("Preview") { actions.preview(item) }
                Button("Edit") { actions.edit(item) }
                Button("Copy to Clipboard") { actions.copy(item) }
                Divider()
                Button("Delete", role: .destructive) { actions.delete(item) }
            }
    }

    /// Title, age and size, kept small over a short gradient: the screenshot is the
    /// content, the caption only helps telling cards apart.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title.replacingOccurrences(of: "Screenshot ", with: ""))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            HStack(alignment: .center, spacing: 6) {
                Text(item.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(item.dimensions)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(.white.opacity(0.16), in: Capsule())
                    .fixedSize()
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

    private var actionRow: some View {
        HStack(spacing: 6) {
            action("eye", help: "Preview") { actions.preview(item) }
            action("pencil", help: "Edit") { actions.edit(item) }
            action(copied ? "checkmark" : "doc.on.doc", help: "Copy to clipboard", tint: copied ? .green : .white) {
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                actions.copy(item)
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    withAnimation { copied = false }
                }
            }
            action("trash", help: "Delete", tint: .red) { actions.delete(item) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0)], startPoint: .top, endPoint: .bottom))
    }

    private func action(_ symbol: String, help: String, tint: Color = .white, perform: @escaping () -> Void) -> some View {
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
