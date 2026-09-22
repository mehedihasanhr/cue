
import UniformTypeIdentifiers
import AppKit
import SwiftUI

/// The panel's tabs, in display order.
enum IslandTab: String, CaseIterable {
    case all, assets, tasks, notes, captures, colors, snippets, clipboard

    static let storageKey = "island.tab"

    var title: String {
        switch self {
        case .all: "All"
        case .captures: "Captures"
        case .clipboard: "Clipboard"
        case .assets: "Assets"
        case .colors: "Colors"
        case .tasks: "Tasks"
        case .snippets: "Snippets"
        case .notes: "Notes"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .captures: "photo.on.rectangle"
        case .clipboard: "doc.on.clipboard"
        case .assets: "tray.full"
        case .colors: "paintpalette"
        case .tasks: "checklist"
        case .snippets: "text.badge.plus"
        case .notes: "note.text"
        }
    }
}

/// What the open island shows: search and the capture buttons on top, a row of tabs,
/// then the captures, the clipboard history or the assets as cards in a horizontal
/// row grouped by day, newest first. The row scrolls by dragging (or with the trackpad).
struct IslandPanel: View {
    /// The panel's smallest size; it widens for a tab row that needs more room.
    /// The least width and the most height: the panel grows wider for its tab row
    /// and takes only the height its content needs.
    static let size = CGSize(width: 780, height: 330)
    static let horizontalPadding: CGFloat = 20

    let library: CaptureLibrary
    let clipboard: ClipboardHistory
    let assets: AssetStore
    let colors: ColorStore
    let tasksStore: TaskStore
    let snippets: SnippetStore
    let actions: HistoryActions
    @Environment(AppPreferences.self) private var preferences
    @Environment(NoteStore.self) private var notes
    @Environment(PrayerClock.self) private var clock: PrayerClock?
    @Environment(FocusTimer.self) private var focusTimer: FocusTimer?
    @Environment(GroupStore.self) private var groups
    /// A file or image is being dragged over the island.
    var dropping = false
    /// Captures picked for one comparison sheet, in the order they were picked.
    @State private var compareSelection: [UUID] = []
    /// Asks the island for a line of text in its compact form.
    /// The current width (the island fits it to `onIdealWidth`).
    var width: CGFloat = IslandPanel.size.width
    /// The width the tab row would like, so nothing in it is ever truncated.
    var onIdealWidth: (CGFloat) -> Void = { _ in }
    /// The height the content needs, so the island is no taller.
    var onIdealHeight: (CGFloat) -> Void = { _ in }
    var onPrompt: (IslandPrompt) -> Void = { _ in }
    /// Opens a task in the compact island.
    var onShowTask: (TaskItem) -> Void = { _ in }
    /// Opens the clock in the compact island (the prayer pill).
    var onShowClock: () -> Void = {}
    /// Opens a card in the pane under the island (Settings › Island › Preview opens);
    /// the direction says which way the pane slides to it.
    var onPreviewPane: (IslandDetail, Int) -> Void = { _, _ in }
    /// Whether the pane is showing something: then the next card opens at once,
    /// sliding in. Asked when needed, so the panel does not re-render for it.
    var isPreviewOpen: () -> Bool = { false }
    /// Closes the pane: the pointer left the card it was opened from and is not on the pane.
    var onHidePreview: () -> Void = {}
    /// Whether the pointer is over the pane (or the gap above it).
    var isPointerInPreview: () -> Bool = { false }
    /// Bumped when the pointer leaves the pane (see `IslandModel.previewLeaveTick`).
    var previewLeaveTick = 0
    /// ← → that reached the window rather than a view (see `IslandWindow`).
    var arrowPress: (delta: Int, tick: Int) = (0, 0)
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    /// While searching: show hits from this tab only (nil: every tab).
    @State private var resultFilter: IslandTab?
    /// Captures / Clipboard / Colors tab: what the strip under the tabs shows —
    /// recent (neither pinned nor grouped), pinned, or one group.
    enum StripFilter: Hashable {
        case recent, pinned, group(UUID)
    }

    @State private var stripFilter: [GroupKind: StripFilter] = [:]
    /// The All tab's strip: recent, pinned, or a group of any kind.
    @State private var allFilter: StripFilter = .recent

    private func filter(_ kind: GroupKind) -> StripFilter { stripFilter[kind] ?? .recent }

    /// The All tab: recent is what is neither pinned nor grouped (snippets count
    /// as recent); pinned and each group are shown on their own. Tasks are not here.
    private var filteredEverything: [IslandItem] {
        let everything = IslandSearch.everything(library: library, clipboard: clipboard, assets: assets, colors: colors, snippets: snippets, notes: notes)
        return everything.filter { item in
            guard preferences.shows(item) else { return false }
            return switch allFilter {
            case .recent: !item.pinned && item.groupID == nil
            case .pinned: item.pinned
            case .group(let id): item.groupID == id
            }
        }
    }

    /// The strip on the All tab: Recent, Pinned, then every group with its kind's symbol.
    private var allStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                groupChip("Recent", symbol: "clock", selected: allFilter == .recent) { allFilter = .recent }
                groupChip("Pinned", symbol: allFilter == .pinned ? "pin.fill" : "pin", selected: allFilter == .pinned) { allFilter = .pinned }
                if !groups.groups.isEmpty {
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 14).padding(.horizontal, 2)
                }
                ForEach(groups.groups) { group in
                    groupChip(group.name, symbol: Self.symbol(for: group.kind), selected: allFilter == .group(group.id)) {
                        allFilter = .group(group.id)
                    }
                    .modifier(GroupDrop(kind: group.kind) { move($0, to: .group(group.id)) })
                    .contextMenu {
                        Button("Rename…") { onPrompt(IslandPrompt(kind: .group(group.kind, assign: nil, editing: group), initial: group.name)) }
                        Divider()
                        Button("Delete Group", role: .destructive) {
                            if allFilter == .group(group.id) { allFilter = .recent }
                            groups.delete(group)
                        }
                    }
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 24)
        .accessibilityLabel("Groups")
    }

    private static func symbol(for kind: GroupKind) -> String {
        switch kind {
        case .captures: "photo.on.rectangle"
        case .clipboard: "doc.on.clipboard"
        case .colors: "paintpalette"
        case .assets: "tray.full"
        }
    }
    /// The prayer pill is open, showing the day's times inline.
    @State private var prayerExpanded = false
    /// Natural widths of the two top rows; the island fits the wider one.
    @State private var headerWidth: CGFloat = 0
    @State private var tabRowWidth: CGFloat = 0
    /// A card opened in place of the row.
    @State private var detail: IslandDetail?
    /// The card ← → moved to (an `IslandItem` id), outlined in the strip.
    @State private var selectedID: String?
    /// The pointer's card and the pending open: a reference, so a hover changes
    /// nothing the body reads and the cards do not re-render for it.
    @State private var hover = HoverState()

    @MainActor
    private final class HoverState {
        /// The card the pointer is on (its `IslandItem` id).
        var hoveredID: String?
        /// The card the pane was last opened from by hovering.
        var openedID: String?
        var task: Task<Void, Never>?
        /// The pending close after the pointer left the card and the pane.
        var closeTask: Task<Void, Never>?
    }
    /// How long the pointer may be off the card and the pane (crossing the gap
    /// between them, say) before a hover-opened pane closes.
    private static let previewCloseGrace: Duration = .milliseconds(250)
    @AppStorage(IslandTab.storageKey) private var tab: IslandTab = .all

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var tabs: [IslandTab] { preferences.islandTabs }

    /// Matches across every tab for the current search — computed once per keystroke,
    /// not once per view that shows them.
    @State private var hits: [IslandItem] = []

    private func refreshHits() {
        hits = searching ? IslandSearch.hits(for: search, library: library, clipboard: clipboard, assets: assets, colors: colors, tasks: tasksStore, snippets: snippets, notes: notes).filter(preferences.shows) : []
    }

    private var filteredClipboard: [ClipboardItem] {
        clipboard.items.filter { shown(pinned: $0.pinned, groupID: $0.groupID, .clipboard) }
    }

    private var filteredCaptures: [CaptureItem] {
        library.items.filter { shown(pinned: $0.pinned, groupID: $0.groupID, .captures) }
    }

    private var filteredAssets: [AssetItem] {
        assets.items.filter { shown(pinned: $0.pinned, groupID: $0.groupID, .assets) }
    }

    private var filteredColors: [ColorEntry] {
        colors.items.filter { shown(pinned: $0.pinned, groupID: $0.groupID, .colors) }
    }

    /// Recent is what is neither pinned nor in a group; Pinned is every pin,
    /// grouped or not; a group is its items, pinned or not.
    private func shown(pinned: Bool, groupID: UUID?, _ kind: GroupKind) -> Bool {
        switch filter(kind) {
        case .recent: !pinned && groupID == nil
        case .pinned: pinned
        case .group(let id): groupID == id
        }
    }

    /// The strip under the cards: Recent, Pinned, each group, and a new one. A
    /// group's chip has Rename and Delete in its menu.
    private func groupStrip(_ kind: GroupKind) -> some View {
        let all = groups.groups(for: kind)
        let current = filter(kind)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                groupChip("Recent", symbol: "clock", selected: current == .recent) { stripFilter[kind] = .recent }
                    .modifier(GroupDrop(kind: kind) { move($0, to: .recent) })
                groupChip("Pinned", symbol: current == .pinned ? "pin.fill" : "pin", selected: current == .pinned) { stripFilter[kind] = .pinned }
                    .modifier(GroupDrop(kind: kind) { move($0, to: .pinned) })
                if !all.isEmpty {
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 14).padding(.horizontal, 2)
                }
                ForEach(all) { group in
                    groupChip(group.name, symbol: "folder", selected: current == .group(group.id)) {
                        stripFilter[kind] = .group(group.id)
                    }
                    .modifier(GroupDrop(kind: kind) { move($0, to: .group(group.id)) })
                    .contextMenu {
                        Button("Rename…") { onPrompt(IslandPrompt(kind: .group(kind, assign: nil, editing: group), initial: group.name)) }
                        Divider()
                        Button("Delete Group", role: .destructive) {
                            if current == .group(group.id) { stripFilter[kind] = .recent }
                            groups.delete(group)
                        }
                    }
                }
                groupChip(all.isEmpty ? "New group" : "", symbol: "plus", selected: false) {
                    onPrompt(IslandPrompt(kind: .group(kind, assign: nil, editing: nil)))
                }
                .help("A new group — a folder for these")
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 24)
        .accessibilityLabel("Groups")
    }

    private func groupChip(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Icon(symbol, size: 12, weight: .semibold)
                if !title.isEmpty { Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1) }
            }
            .foregroundStyle(selected ? Color.white : .white.opacity(0.75))
            .padding(.horizontal, title.isEmpty ? 7 : 9)
            .frame(height: 22)
            .background(selected ? Color.brand.opacity(0.85) : .white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A card dropped on a chip: into that group, pinned, or back to recent
    /// (ungrouped and unpinned).
    private func move(_ item: GroupAssignment, to target: StripFilter) {
        switch item {
        case .capture(let id):
            guard let capture = library.items.first(where: { $0.id == id }) else { return }
            switch target {
            case .recent:
                library.setGroup(capture, nil)
                if capture.pinned { library.togglePin(capture) }
            case .pinned:
                if !capture.pinned { library.togglePin(capture) }
            case .group(let groupID):
                library.setGroup(capture, groupID)
            }
        case .clipboard(let id):
            guard let entry = clipboard.items.first(where: { $0.id == id }) else { return }
            switch target {
            case .recent:
                clipboard.setGroup(entry, nil)
                if entry.pinned, let fresh = clipboard.items.first(where: { $0.id == id }) { clipboard.togglePin(fresh) }
            case .pinned:
                if !entry.pinned { clipboard.togglePin(entry) }
            case .group(let groupID):
                clipboard.setGroup(entry, groupID)
            }
        case .color(let id):
            guard let entry = colors.items.first(where: { $0.id == id }) else { return }
            switch target {
            case .recent:
                colors.setGroup(entry, nil)
                if entry.pinned { colors.togglePin(entry) }
            case .pinned:
                if !entry.pinned { colors.togglePin(entry) }
            case .group(let groupID):
                colors.setGroup(entry, groupID)
            }
        case .asset(let id):
            guard let asset = assets.items.first(where: { $0.id == id }) else { return }
            switch target {
            case .recent:
                assets.setGroup(asset, nil)
                if asset.pinned { assets.togglePin(asset) }
            case .pinned:
                if !asset.pinned { assets.togglePin(asset) }
            case .group(let groupID):
                assets.setGroup(asset, groupID)
            }
        }
        let name: String = switch target {
        case .recent: "Recent"
        case .pinned: "Pinned"
        case .group(let groupID): groups.group(groupID)?.name ?? "the group"
        }
        FeedbackHUD.show("Moved to \(name)", symbol: "folder.fill", duration: .seconds(1))
    }

    private func emptyText(_ kind: GroupKind, none: String) -> String {
        switch filter(kind) {
        case .recent: none
        case .pinned: "Nothing pinned"
        case .group: "Nothing in this group yet — Group › on a card's menu"
        }
    }

    private func emptySymbol(_ kind: GroupKind, _ symbol: String) -> String {
        switch filter(kind) {
        case .recent: symbol
        case .pinned: "pin"
        case .group: "folder"
        }
    }

    /// Which tab's groups the strip shows, if the tab has any.
    private var groupKind: GroupKind? {
        switch tab {
        case .captures: .captures
        case .clipboard: .clipboard
        case .colors: .colors
        case .assets: .assets
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Icon("magnifyingglass", size: 18, weight: .medium)
                        .foregroundStyle(searching ? Color.brand : .white.opacity(0.6))
                    TextField("Search everything", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .focused($searchFocused)
                        .onExitCommand { clearSearch() }
                        // With nothing typed the arrows walk the cards, not the caret.
                        .onKeyPress(.leftArrow) { search.isEmpty ? moveSelection(-1) : .ignored }
                        .onKeyPress(.rightArrow) { search.isEmpty ? moveSelection(1) : .ignored }
                        .accessibilityLabel("Search")
                        .accessibilityValue(searching ? "\(hits.count) matches" : "")
                    if searching {
                        Text(hits.isEmpty ? "No matches" : "\(hits.count) \(hits.count == 1 ? "match" : "matches")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize()
                        Button(action: clearSearch) {
                            Icon("xmark.circle.fill", size: 18).foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Clear the search")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .frame(maxWidth: searching ? .infinity : nil)
                .background(.white.opacity(searching ? 0.12 : 0.08), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(searching ? Color.brand.opacity(0.8) : .clear, lineWidth: 1.5))
                .background(KeyOnFocus(focused: searchFocused))
                if !searching {
                    Spacer(minLength: 8)
                    if let focusTimer, focusTimer.isRunning {
                        FocusPill(timer: focusTimer, onShowTask: onShowTask)
                    }
                    if let clock, clock.status != nil {
                        PrayerPill(clock: clock, expanded: $prayerExpanded, onShowClock: onShowClock)
                    }
                    captureBar
                    circle("gearshape", help: "Settings", action: actions.openSettings)
                }
            }
            .animation(.easeOut(duration: 0.18), value: searching)
            .modifier(IdealWidth { headerWidth = $0; reportWidth() })

            if searching {
                resultBar
            } else if let detail {
                IslandDetailHeader(detail: detail, library: library, assets: assets, actions: actions) {
                    withAnimation(.easeOut(duration: 0.15)) { self.detail = nil }
                }
            } else {
            HStack(spacing: 8) {
                ForEach(Array(tabs.enumerated()), id: \.element) { index, value in
                    tabPill(value, count: count(for: value), shortcut: index + 1)
                }
                Spacer(minLength: 16)
                if tab == .captures, !comparing.isEmpty {
                    smallButton("Compare \(comparing.count)", symbol: "rectangle.split.2x1",
                                help: "Lay the picked captures out in one picture and copy it", action: compareSelected)
                    smallButton("Deselect", symbol: "xmark", help: "Drop the comparison picks") { compareSelection = [] }
                }
                if tab == .captures, library.items.contains(where: { !$0.pinned }) {
                    smallButton("Clear", symbol: "trash", help: "Remove every unpinned capture") { library.unpinned.forEach(actions.delete) }
                }
                if tab == .snippets {
                    smallButton("New", symbol: "plus", help: "A new snippet") { onPrompt(IslandPrompt(kind: .snippet(nil, initialText: "", assetID: nil))) }
                }
                if tab == .notes {
                    smallButton("New", symbol: "plus", help: "A new note (⌥⇧M anywhere)") { onPrompt(IslandPrompt(kind: .note(nil))) }
                }
                if tab == .colors {
                    smallButton("Pick", symbol: "eyedropper", help: "Pick a color from the screen", action: actions.pickColor)
                    if colors.items.contains(where: { !$0.pinned }) {
                        smallButton("Clear", symbol: "trash", help: "Remove every unpinned color") { colors.clear() }
                    }
                }
                if tab == .clipboard, clipboard.items.contains(where: { !$0.pinned }) {
                    smallButton("Clear", symbol: "trash", help: "Remove every unpinned entry") { clipboard.clear() }
                }
                if tab == .assets {
                    smallButton("Paste", symbol: "doc.on.clipboard", help: "Save the image or files on the clipboard as assets") {
                        if let added = assets.addFromPasteboard() {
                            FeedbackHUD.show(added.count == 1 ? "Saved to Assets" : "\(added.count) saved to Assets", symbol: "tray.and.arrow.down.fill", duration: .seconds(1.2))
                        } else {
                            FeedbackHUD.show("No image or file on the clipboard", symbol: "tray")
                        }
                    }
                    if assets.items.contains(where: { !$0.pinned && $0.groupID == nil }) {
                        smallButton("Clear", symbol: "trash", help: "Remove every recent asset") { assets.clear() }
                    }
                }
            }
            .modifier(IdealWidth { tabRowWidth = $0; reportWidth() })
            }

            // The cards a little further from the tabs than the rows above are from each other.
            ZStack {
                if searching {
                    searchResults
                } else if let detail {
                    IslandDetailBody(detail: detail, library: library, clipboard: clipboard, assets: assets, colors: colors, actions: actions,
                                     notes: notes, tasks: tasksStore, onEdit: edit)
                        .transition(.opacity)
                } else {
                switch tab {
                case .all:
                    let everything = filteredEverything
                    if everything.isEmpty {
                        switch allFilter {
                        case .recent:
                            empty("Nothing yet — capture, copy or drop something", symbol: "square.grid.2x2",
                                  action: ("Capture area", "viewfinder", actions.captureArea))
                        case .pinned:
                            empty("Nothing pinned", symbol: "pin")
                        case .group:
                            empty("Nothing in this group yet — Group › on a card's menu", symbol: "folder")
                        }
                    } else {
                        DayStrip(items: everything, date: \.date, dragPayload: dragPayload, card: itemCard)
                            .selecting { $0.id == selectedID }
                            .onCardHover { hover($0, inside: $1) }
                    }
                case .captures:
                    if filteredCaptures.isEmpty {
                        empty(emptyText(.captures, none: "No captures yet"), symbol: emptySymbol(.captures, "camera.viewfinder"),
                              action: filter(.captures) == .recent ? ("Capture area", "viewfinder", actions.captureArea) : nil)
                    } else {
                        DayStrip(items: filteredCaptures, date: \.createdAt, pinned: \.pinned, dragPayload: { item in
                            library.fileURL(for: item).map { .file($0, preview: library.thumbnail(for: item), reference: .capture(item.id)) }
                        }, card: captureCard)
                            .selecting { IslandItem.capture($0).id == selectedID }
                            .onCardHover { hover(.capture($0), inside: $1) }
                    }
                case .clipboard:
                    if filteredClipboard.isEmpty {
                        empty(emptyText(.clipboard, none: "Nothing copied yet"), symbol: emptySymbol(.clipboard, "doc.on.clipboard"))
                    } else {
                        DayStrip(items: filteredClipboard, date: \.createdAt, pinned: \.pinned, dragPayload: { item in
                            clipboard.dragPayload(for: item).map { payload in
                                var own = payload
                                own.reference = .clipboard(item.id)
                                return own
                            }
                        }, card: clipboardCard)
                            .selecting { IslandItem.clipboard($0).id == selectedID }
                            .onCardHover { hover(.clipboard($0), inside: $1) }
                    }
                case .tasks:
                    IslandTasksView(store: tasksStore, onPrompt: onPrompt, onShowTask: onShowTask, onHover: { hover(.task($0), inside: $1) })
                case .snippets:
                    if snippets.items.isEmpty {
                        empty("Type a keyword anywhere and Klik pastes the snippet", symbol: "text.badge.plus",
                              action: ("New snippet", "plus", { onPrompt(IslandPrompt(kind: .snippet(nil, initialText: "", assetID: nil))) }))
                    } else {
                        DayStrip(items: snippets.items, date: \.createdAt, dragPayload: snippetDrag, card: snippetCard)
                            .selecting { IslandItem.snippet($0).id == selectedID }
                    }
                case .notes:
                    if notes.notes.isEmpty {
                        empty("Jot things down — ⌥⇧M opens a note anywhere", symbol: "note.text",
                              action: ("New note", "plus", { onPrompt(IslandPrompt(kind: .note(nil))) }))
                    } else {
                        DayStrip(items: notes.notes, date: \.updatedAt, dragPayload: noteDrag, card: noteCard)
                            .selecting { IslandItem.note($0).id == selectedID }
                            .onCardHover { hover(.note($0), inside: $1) }
                    }
                case .colors:
                    if filteredColors.isEmpty {
                        empty(emptyText(.colors, none: "Pick a color anywhere on screen"), symbol: emptySymbol(.colors, "eyedropper"),
                              action: filter(.colors) == .recent ? ("Pick a color", "eyedropper", actions.pickColor) : nil)
                    } else {
                        DayStrip(items: filteredColors, date: \.createdAt, pinned: \.pinned, dragPayload: { entry in
                            DragPayload(writer: preferences.colorFormat.string(for: entry.color) as NSString, preview: ColorCard.dragImage(for: entry.color), reference: .color(entry.id))
                        }, card: colorCard)
                            .selecting { IslandItem.color($0).id == selectedID }
                            .onCardHover { hover(.color($0), inside: $1) }
                    }
                case .assets:
                    if filteredAssets.isEmpty {
                        empty(emptyText(.assets, none: "Drop images or files here to keep them handy"), symbol: emptySymbol(.assets, "tray.and.arrow.down"))
                    } else {
                        DayStrip(items: filteredAssets, date: \.createdAt, pinned: \.pinned, dragPayload: { item in
                            .file(assets.fileURL(for: item), preview: assets.thumbnail(for: item), reference: .asset(item.id))
                        }, card: assetCard)
                            .selecting { IslandItem.asset($0).id == selectedID }
                            .onCardHover { hover(.asset($0), inside: $1) }
                    }
                }
                }
                if dropping {
                    dropHint
                }
            }
            .frame(height: Self.rowHeight) // the same whether a tab has cards or not
            .padding(.top, 6)
            .background { keyboardShortcuts }
            .onKeyPress(.leftArrow) { moveSelection(-1) }
            .onKeyPress(.rightArrow) { moveSelection(1) }
            .onChange(of: arrowPress.tick) { _, _ in _ = moveSelection(arrowPress.delta) }
            .onChange(of: previewLeaveTick) { _, _ in closePreviewUnlessHovered() }
            .onChange(of: tab) { _, _ in
                detail = nil
                selectedID = nil
                hover.task?.cancel()
                hover.task = nil
                hover.closeTask?.cancel()
                hover.closeTask = nil
                hover.hoveredID = nil
                hover.openedID = nil
            }
            .onChange(of: tabs, initial: true) { _, tabs in
                // The tab that was showing has been turned off: fall back to All.
                if !tabs.contains(tab) { tab = .all }
                refreshHits()
            }
            .onChange(of: searching) { _, _ in
                detail = nil
                resultFilter = nil
            }
            .onChange(of: search, refreshHits)
            .onChange(of: library.items.count + clipboard.items.count + assets.items.count + colors.items.count + tasksStore.tasks.count, refreshHits)
            // The groups under the cards, a footer to the tab: set off from the cards,
            // close to the edge.
            if let kind = groupKind {
                groupStrip(kind).padding(.top, 12)
            } else if tab == .all {
                allStrip.padding(.top, 12)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        // Straight under the menu bar (the strip above is its height), plus a hair.
        .padding(.top, 1)
        .padding(.bottom, groupKind != nil || tab == .all ? 10 : 16)
        .modifier(IdealHeight { onIdealHeight($0) })
        .frame(width: width, alignment: .top)
        .frame(maxHeight: Self.size.height, alignment: .top)
    }

    // MARK: - Cards

    private func captureCard(_ item: CaptureItem) -> some View {
        CaptureCard(item: item, library: library, actions: actions, clipboard: clipboard, colorStore: colors, onPreview: { open(.capture(item)) }, onRename: {
            onPrompt(IslandPrompt(kind: .rename(.capture(item)), initial: item.title.replacingOccurrences(of: "Screenshot ", with: ""), image: library.thumbnail(for: item)))
        }, onNewGroup: { onPrompt(IslandPrompt(kind: .group(.captures, assign: .capture(item.id), editing: nil))) },
                    compareIndex: comparing.firstIndex(of: item.id).map { $0 + 1 },
                    onToggleCompare: { toggleCompare(item) })
            .modifier(CompareDrop(owner: .capture(item.id), resolve: draggedImage, accept: { actions.compare(item, $0) }))
    }

    /// The picks that are still in the library, in the order they were picked.
    private var comparing: [UUID] {
        compareSelection.filter { id in library.items.contains { $0.id == id } }
    }

    private func toggleCompare(_ item: CaptureItem) {
        if let index = compareSelection.firstIndex(of: item.id) {
            compareSelection.remove(at: index)
        } else {
            compareSelection.append(item.id)
        }
    }

    /// The picked captures in one picture, kept and copied. The first pick is the base
    /// the others are laid beside, so the order they were picked in is the order shown.
    private func compareSelected() {
        let picks = comparing.compactMap { id in library.items.first { $0.id == id } }
        guard let base = picks.first else { return }
        guard picks.count > 1 else {
            FeedbackHUD.show("Pick another capture to compare with", symbol: "rectangle.split.2x1")
            return
        }
        let others = picks.dropFirst().compactMap { library.image(for: $0) }
        guard !others.isEmpty else {
            FeedbackHUD.show("The picked captures could not be read", symbol: "exclamationmark.triangle")
            return
        }
        actions.compare(base, others)
        compareSelection = []
    }

    /// One of Klik's own cards as an image, for a card dropped onto a capture.
    private func draggedImage(_ source: GroupAssignment) -> CapturedImage? {
        switch source {
        case .capture(let id):
            library.items.first { $0.id == id }.flatMap { library.image(for: $0) }
        case .asset(let id):
            assets.items.first { $0.id == id }.map { assets.fileURL(for: $0) }.flatMap { ImageDrop.captured(at: $0) }
        case .clipboard(let id):
            clipboard.items.first { $0.id == id }.flatMap { clipboard.imageData(for: $0) }.flatMap { ImageDrop.captured(from: $0) }
        case .color:
            nil
        }
    }

    private func clipboardCard(_ item: ClipboardItem) -> some View {
        ClipboardCard(item: item, clipboard: clipboard, onPreview: { open(.clipboard(item)) }, onRename: {
            onPrompt(IslandPrompt(kind: .rename(.clipboard(item)), initial: item.name ?? "", image: clipboard.thumbnail(for: item),
                                  swatch: item.kind == .color ? PickedColor(hex: item.text) : nil))
        }, onSnippet: { text in
            onPrompt(IslandPrompt(kind: .snippet(nil, initialText: text, assetID: nil)))
        }, onEdit: { actions.editClipboardImage(item) }, onNewGroup: { onPrompt(IslandPrompt(kind: .group(.clipboard, assign: .clipboard(item.id), editing: nil))) })
    }

    private func assetCard(_ item: AssetItem) -> some View {
        AssetCard(item: item, assets: assets, clipboard: clipboard, onPreview: { open(.asset(item)) }, onRename: {
            onPrompt(IslandPrompt(kind: .rename(.asset(item)), initial: item.title, image: assets.thumbnail(for: item)))
        }, onSnippet: {
            onPrompt(IslandPrompt(kind: .snippet(nil, initialText: "", assetID: item.id)))
        }, onNewGroup: { onPrompt(IslandPrompt(kind: .group(.assets, assign: .asset(item.id), editing: nil))) })
    }

    private func colorCard(_ entry: ColorEntry) -> some View {
        ColorCard(entry: entry, colors: colors, format: preferences.colorFormat, onPreview: { open(.color(entry)) }, onRename: {
            onPrompt(IslandPrompt(kind: .rename(.color(entry)), initial: entry.name ?? "", swatch: entry.color))
        }, onNewGroup: { onPrompt(IslandPrompt(kind: .group(.colors, assign: .color(entry.id), editing: nil))) })
    }

    // MARK: - Search

    private func clearSearch() {
        search = ""
        searchFocused = false
    }

    /// Replaces the tab row while searching: how many hits each tab has, as pills
    /// that narrow the results to that tab.
    private var resultBar: some View {
        let counts = IslandSearch.counts(hits)
        return HStack(spacing: 8) {
            resultPill(nil, title: "All", count: hits.count, symbol: "magnifyingglass")
            ForEach(counts, id: \.tab) { entry in
                resultPill(entry.tab, title: entry.tab.title, count: entry.count, symbol: entry.tab.symbol)
            }
            Spacer(minLength: 0)
            Text("⎋ to clear")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .transition(.opacity)
    }

    private func resultPill(_ value: IslandTab?, title: String, count: Int, symbol: String) -> some View {
        let selected = resultFilter == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { resultFilter = value }
        } label: {
            HStack(spacing: 6) {
                Icon(symbol, size: 14, weight: .semibold)
                Text(title).font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background((selected ? Color.black : Color.white).opacity(0.12), in: Capsule())
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(selected ? Color.brand : Color.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Every hit as a card, grouped by tab, in one strip.
    @ViewBuilder
    private var searchResults: some View {
        let shown = resultFilter.map { filter in hits.filter { $0.tab == filter || $0.tab == .all } } ?? hits
        if shown.isEmpty {
            empty("Nothing matches “\(search.trimmingCharacters(in: .whitespaces))”", symbol: "magnifyingglass")
        } else {
            DayStrip(items: shown, section: { StripSection(id: $0.tab, title: $0.tab == .all ? "Answers" : $0.tab.title) }, dragPayload: dragPayload, card: itemCard)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func itemCard(_ item: IslandItem) -> some View {
        switch item {
        case .capture(let item): captureCard(item)
        case .clipboard(let item): clipboardCard(item)
        case .asset(let item): assetCard(item)
        case .color(let entry): colorCard(entry)
        case .task(let task): TaskCard(task: task, store: tasksStore, focus: focusTimer, onOpen: { onShowTask(task) }, onDelete: { onPrompt(IslandPrompt(kind: .delete(.task(task)))) })
        case .snippet(let snippet): snippetCard(snippet)
        case .note(let note): noteCard(note)
        case .answer(let answer): AnswerCard(answer: answer, clipboard: clipboard, colors: colors)
        }
    }

    private func noteDrag(_ note: Note) -> DragPayload? {
        DragPayload(writer: note.text as NSString, preview: SnippetCard.dragImage(forText: note.title))
    }

    private func noteCard(_ note: Note) -> some View {
        NoteCard(note: note, store: notes, clipboard: clipboard, onEdit: { onPrompt(IslandPrompt(kind: .note(note))) })
    }

    private func snippetDrag(_ snippet: Snippet) -> DragPayload? {
        DragPayload(writer: SnippetTemplate.expand(snippet.text, values: [:]) as NSString, preview: SnippetCard.dragImage(for: snippet))
    }

    private func snippetCard(_ snippet: Snippet) -> some View {
        SnippetCard(snippet: snippet, store: snippets, assets: assets, clipboard: clipboard,
                    onEdit: { onPrompt(IslandPrompt(kind: .snippet(snippet, initialText: "", assetID: nil))) })
    }

    /// How many cards the tab shows under its strip filter (Recent, Pinned, a group).
    private func count(for tab: IslandTab) -> Int {
        switch tab {
        case .all: filteredEverything.count
        case .captures: filteredCaptures.count
        case .clipboard: filteredClipboard.count
        case .assets: filteredAssets.count
        case .colors: filteredColors.count
        case .tasks: tasksStore.tasks.count { $0.status != .complete }
        case .snippets: snippets.items.count
        case .notes: notes.notes.count
        }
    }

    private func dragPayload(for hit: IslandItem) -> DragPayload? {
        switch hit {
        case .capture(let item): library.fileURL(for: item).map { .file($0, preview: library.thumbnail(for: item)) }
        case .clipboard(let item): clipboard.dragPayload(for: item)
        case .asset(let item): .file(assets.fileURL(for: item), preview: assets.thumbnail(for: item))
        case .color(let entry): DragPayload(writer: preferences.colorFormat.string(for: entry.color) as NSString, preview: ColorCard.dragImage(for: entry.color))
        case .task: nil
        case .snippet(let snippet): DragPayload(writer: SnippetTemplate.expand(snippet.text, values: [:]) as NSString, preview: SnippetCard.dragImage(for: snippet))
        case .note(let note): noteDrag(note)
        case .answer(let answer): DragPayload(writer: answer.value as NSString, preview: answer.color.map(ColorCard.dragImage) ?? SnippetCard.dragImage(forText: answer.value))
        }
    }

    /// The island takes the wider of the header (the prayer pill can open wide) and
    /// the tab row, so neither is ever squeezed.
    private func reportWidth() {
        onIdealWidth(max(headerWidth, tabRowWidth) + Self.horizontalPadding * 2)
    }

    private func circle(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        HoverButton(symbol: symbol, help: help, size: 40, action: action)
    }

    /// The capture tools as one group, so they read as a toolbar rather than five
    /// loose buttons; each names itself in a tooltip.
    private var captureBar: some View {
        HStack(spacing: 0) {
            HoverButton(symbol: "display", help: "Capture full screen", size: 36, action: actions.captureFullScreen)
            HoverButton(symbol: "viewfinder", help: "Capture area", size: 36, action: actions.captureArea)
            HoverButton(symbol: "macwindow", help: "Capture window (with its shadow)", size: 36, action: actions.captureWindow)
            HoverButton(symbol: "rectangle.expand.vertical", help: "Scrolling capture", size: 36, action: actions.captureScrolling)
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 3)
            HoverButton(symbol: "text.viewfinder", help: "Capture text", size: 36, action: actions.captureText)
            HoverButton(symbol: "eyedropper", help: "Pick a color", size: 36, action: actions.pickColor)
        }
        .padding(.horizontal, 3)
        .frame(height: 40)
        .background(.white.opacity(0.08), in: Capsule(style: .continuous))
    }

    private func tabPill(_ value: IslandTab, count: Int, shortcut: Int) -> some View {
        TabPill(tab: value, count: count, selected: tab == value, shortcut: shortcut) {
            withAnimation(IslandView.openAnimation) { tab = value } // the same curve the shape follows, so the two move as one
        }
    }

    /// While the island is key (the search field has been clicked): ⌘1–⌘7 switch
    /// tabs, ⌘F goes to the search field.
    private var keyboardShortcuts: some View {
        Group {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, value in
                Button("") { withAnimation(IslandView.openAnimation) { tab = value } }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func open(_ detail: IslandDetail, direction: Int = 0) {
        if preferences.islandPreview == .pane {
            onPreviewPane(detail, direction)
        } else {
            withAnimation(.easeOut(duration: 0.15)) { self.detail = detail }
        }
    }

    /// A note or a task from an open card: its form in the compact island.
    private func edit(_ detail: IslandDetail) {
        switch detail {
        case .note(let note): onPrompt(IslandPrompt(kind: .note(note)))
        case .task(let task): onPrompt(IslandPrompt(kind: .task(project: task.projectID), editing: task))
        default: break
        }
    }

    /// The card the pane shows or ← → last moved to.
    private var currentID: String? { selectedID ?? hover.openedID }

    /// Which way `item` lies from the current card: +1 right, -1 left, 0 unknown.
    private func direction(to item: IslandItem) -> Int {
        guard let currentID, currentID != item.id else { return 0 }
        let items = navigable
        guard let from = items.firstIndex(where: { $0.id == currentID }), let to = items.firstIndex(where: { $0.id == item.id }), from != to else { return 0 }
        return to > from ? 1 : -1
    }

    /// The pointer came onto a card, or left it. With the pane and hover on, the
    /// card opens there after the delay — at once, sliding over, while the pane
    /// already shows a card. Cards report leaving and entering in either order, so
    /// a leave only counts for the card the pointer was on.
    private func hover(_ item: IslandItem, inside: Bool) {
        if !inside {
            guard hover.hoveredID == item.id else { return }
            hover.hoveredID = nil
            hover.task?.cancel()
            hover.task = nil
            closePreviewUnlessHovered()
            return
        }
        guard hover.hoveredID != item.id else { return }
        hover.hoveredID = item.id
        hover.task?.cancel()
        hover.task = nil
        hover.closeTask?.cancel()
        hover.closeTask = nil
        // A link's page is fetched now, so its preview is whole when the pane opens.
        if case .clipboard(let entry) = item, entry.kind == .link, let url = URL(string: entry.text) { LinkMetadata.prefetch(url) }
        guard let detail = item.detail, preferences.islandPreview == .pane, preferences.islandPreviewOnHover else { return }
        let delay = isPreviewOpen() ? 0 : preferences.islandPreviewHoverDelay
        if delay <= 0 {
            openFromHover(item, detail)
        } else {
            hover.task = Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, hover.hoveredID == item.id else { return }
                openFromHover(item, detail)
            }
        }
    }

    /// The pointer left a card or the pane: a pane opened by hovering closes after
    /// the grace unless the pointer is back on a card or over the pane by then. A
    /// pane opened with ← → stays until ⎋ or the next card.
    private func closePreviewUnlessHovered() {
        hover.closeTask?.cancel()
        hover.closeTask = nil
        guard hover.openedID != nil, selectedID == nil, isPreviewOpen() else { return }
        hover.closeTask = Task { @MainActor in
            try? await Task.sleep(for: Self.previewCloseGrace)
            guard !Task.isCancelled, hover.hoveredID == nil, selectedID == nil, !isPointerInPreview() else { return }
            hover.openedID = nil
            onHidePreview()
        }
    }

    private func openFromHover(_ item: IslandItem, _ detail: IslandDetail) {
        let direction = direction(to: item)
        hover.openedID = item.id
        if selectedID != nil { selectedID = nil } // the hovered card's own outline marks it
        onPreviewPane(detail, direction)
    }

    /// The cards of the tab, in the order the strip shows them (pinned first).
    private var navigable: [IslandItem] {
        if searching { return hits.filter { if case .answer = $0 { false } else { true } } }
        switch tab {
        case .all: return filteredEverything
        case .captures: return (filteredCaptures.filter(\.pinned) + filteredCaptures.filter { !$0.pinned }).map(IslandItem.capture)
        case .clipboard: return (filteredClipboard.filter(\.pinned) + filteredClipboard.filter { !$0.pinned }).map(IslandItem.clipboard)
        case .assets: return (filteredAssets.filter(\.pinned) + filteredAssets.filter { !$0.pinned }).map(IslandItem.asset)
        case .colors: return (filteredColors.filter(\.pinned) + filteredColors.filter { !$0.pinned }).map(IslandItem.color)
        case .snippets: return snippets.items.map(IslandItem.snippet)
        case .notes: return notes.notes.map(IslandItem.note)
        case .tasks: return []
        }
    }

    /// ← → walk the cards; a card that can be previewed opens as it is reached.
    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        let items = navigable
        guard !items.isEmpty else { return .ignored }
        let current = items.firstIndex { $0.id == currentID }
        let next = current.map { min(max($0 + delta, 0), items.count - 1) } ?? (delta > 0 ? 0 : items.count - 1)
        let item = items[next]
        let direction = direction(to: item)
        selectedID = item.id
        hover.task?.cancel()
        hover.task = nil
        if let detail = item.detail { open(detail, direction: direction) }
        return .handled
    }

    /// A `smallButton` that stays lit while on.
    private func smallToggle(_ title: String, symbol: String, help: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Label { Text(title) } icon: { Icon(symbol, weight: .medium) }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? .yellow : .white.opacity(0.7))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(isOn.wrappedValue ? .yellow.opacity(0.18) : .white.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func smallButton(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { Icon(symbol, weight: .medium) }
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
                    Icon("tray.and.arrow.down.fill", size: 35).foregroundStyle(.white)
                    Text("Drop to save as an asset").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// Height of the card row: header plus cards.
    static var rowHeight: CGFloat { DayStrip<CaptureItem, EmptyView>.headerHeight + DayStrip<CaptureItem, EmptyView>.cardSize.height }

    /// An empty tab says what goes here and, when there is one, offers the next step.
    private func empty(_ message: String, symbol: String, action: (title: String, symbol: String, perform: () -> Void)? = nil) -> some View {
        VStack(spacing: 8) {
            Icon(symbol, size: 32).foregroundStyle(.white.opacity(0.6))
            Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            if let action {
                Button(action: action.perform) {
                    Label { Text(action.title) } icon: { Icon(action.symbol, weight: .medium) }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Color.white, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.rowHeight)
    }
}

// MARK: - Day strip

/// A header in a `DayStrip`.
struct StripSection {
    let id: AnyHashable
    let title: String
}

/// Horizontal row of day groups ("Today", "Yesterday", "Wed, Jul 22"). Dragging
/// anywhere on it scrolls; the scroll wheel / trackpad works too. Every card has the
/// same width, so positions are arithmetic and only the cards in view are built —
/// a history of thousands costs the same as one of ten.
struct DayStrip<Item: Identifiable, Card: View>: View {
    let items: [Item]
    /// What a card puts on the drag pasteboard, if it can be dragged out. A vertical
    /// drag on a card then drags it into other apps; a horizontal drag scrolls the row.
    var dragPayload: ((Item) -> DragPayload?)? = nil
    @ViewBuilder let card: (Item) -> Card
    /// The card outlined as the one chosen (← → move it), scrolled into view.
    var isSelected: (Item) -> Bool = { _ in false }
    /// The pointer came onto a card (true) or left it (false). Leaving one card
    /// and entering the next arrive in either order.
    var onHover: (Item, Bool) -> Void = { _, _ in }

    func selecting(_ isSelected: @escaping (Item) -> Bool) -> DayStrip {
        var copy = self
        copy.isSelected = isSelected
        return copy
    }

    func onCardHover(_ onHover: @escaping (Item, Bool) -> Void) -> DayStrip {
        var copy = self
        copy.onHover = onHover
        return copy
    }

    /// Grouped by day ("Today", "Yesterday", "Wed, Jul 22"); items flagged `pinned`
    /// go first in a "Pinned" group.
    init(items: [Item], date: KeyPath<Item, Date>, pinned: KeyPath<Item, Bool>? = nil,
         dragPayload: ((Item) -> DragPayload?)? = nil, @ViewBuilder card: @escaping (Item) -> Card) {
        let calendar = Calendar.current
        self.items = pinned.map { key in items.filter { $0[keyPath: key] } + items.filter { !$0[keyPath: key] } } ?? items
        // A day's title is formatted once, not once per card.
        var titles: [Date: String] = [:]
        let sections = self.items.map { item -> StripSection in
            if let pinned, item[keyPath: pinned] { return StripSection(id: "pinned", title: "Pinned") }
            let day = calendar.startOfDay(for: item[keyPath: date])
            if let title = titles[day] { return StripSection(id: day, title: title) }
            let title = Self.title(for: day, calendar: calendar)
            titles[day] = title
            return StripSection(id: day, title: title)
        }
        self.dragPayload = dragPayload
        self.card = card
        self.layout = Self.layout(for: self.items, sections: sections)
    }

    /// Grouped however `section` says (search results by tab, say); consecutive
    /// items with the same section share a header.
    init(items: [Item], section: @escaping (Item) -> StripSection,
         dragPayload: ((Item) -> DragPayload?)? = nil, @ViewBuilder card: @escaping (Item) -> Card) {
        self.items = items
        self.dragPayload = dragPayload
        self.card = card
        self.layout = Self.layout(for: items, sections: items.map(section))
    }

    static var cardSize: CGSize { CGSize(width: 156, height: 124) }
    static var spacing: CGFloat { 10 }
    static var groupSpacing: CGFloat { 22 }
    static var headerHeight: CGFloat { 24 }

    @State private var offset: CGFloat = 0
    @State private var dragOrigin: CGFloat?
    @State private var dragMode: DragMode?

    private enum DragMode { case scroll, dragOut }

    private struct PlacedGroup: Identifiable {
        let id: AnyHashable
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

    /// Worked out once when the strip is made — not again for every scroll or hover.
    private let layout: Layout

    private static func layout(for items: [Item], sections: [StripSection]) -> Layout {
        var layout = Layout()
        var x: CGFloat = 0
        var current: AnyHashable?
        for (item, section) in zip(items, sections) {
            if section.id != current {
                if current != nil { x += Self.groupSpacing - Self.spacing }
                layout.groups.append(PlacedGroup(id: section.id, title: section.title, x: x, width: 0))
                current = section.id
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
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(layout.cards.filter { visible.contains($0.x) }) { placed in
                    card(placed.item)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.brand, lineWidth: 2)
                                .opacity(isSelected(placed.item) ? 1 : 0)
                                .allowsHitTesting(false)
                        )
                        .onHover { inside in onHover(placed.item, inside) }
                        .offset(x: placed.x - offset, y: Self.headerHeight)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            // The chosen card is brought into view (← → walk past the edges).
            .onChange(of: layout.cards.first { isSelected($0.item) }?.x) { _, x in
                guard let x else { return }
                if x < offset { self.offset = max(0, x) }
                else if x + Self.cardSize.width > offset + proxy.size.width { self.offset = min(maxOffset, x + Self.cardSize.width - proxy.size.width) }
            }
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
            // Fades at the edges say there is more to scroll to.
            .overlay(alignment: .leading) {
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 28)
                    .opacity(offset > 0 ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 28)
                    .opacity(offset < maxOffset - 1 ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.15), value: offset > 0)
            .animation(.easeOut(duration: 0.15), value: offset < maxOffset - 1)
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
struct CardChrome<Content: View, Actions: View, Menu: View>: View {
    @Binding var hovering: Bool
    /// What VoiceOver reads for the card (its content is decorative for it).
    var label: String = ""
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actionRow: () -> Actions
    @ViewBuilder let menu: () -> Menu

    private static var radius: CGFloat { 18 }

    var body: some View {
        content()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .overlay(alignment: .top) {
                // Always in the tree (faded out, not hit-testable) so a drag started
                // from the row survives the pointer leaving the card.
                HStack(spacing: 6) { actionRow() }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0)], startPoint: .top, endPoint: .bottom))
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
struct CardAction: View {
    let symbol: String
    let help: String
    var tint: Color = .white
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Icon(symbol, size: 14, weight: .bold)
                .frame(width: 27, height: 27)
                .background(.black.opacity(0.8), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35)))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Copy button that turns into a green tick for a moment.
struct CopyAction: View {
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
struct CardCaption<Leading: View>: View {
    let title: String
    let date: Date
    /// Shown instead of the relative date ("5:20 PM" for a screenshot, say).
    var subtitle: String? = nil
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
                Text(subtitle ?? date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.8))
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

struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.white.opacity(0.16), in: Capsule())
            .fixedSize()
    }
}

/// A round icon button that lights up under the pointer; the name is its tooltip.
struct HoverButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 36
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Icon(symbol, size: size >= 40 ? 19 : 18, weight: .medium)
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .frame(width: size, height: size)
                .background(.white.opacity(hovering ? 0.16 : (size >= 40 ? 0.1 : 0)), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One tab, its name alone: a brand capsule when selected, an outlined one
/// otherwise (a little fill under the pointer), its count as quiet digits.
struct TabPill: View {
    let tab: IslandTab
    let count: Int
    let selected: Bool
    var shortcut: Int? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(tab.title).font(.system(size: 13))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11).monospacedDigit())
                        .opacity(selected ? 0.55 : 0.5)
                }
            }
            .foregroundStyle(.white.opacity(selected || hovering ? 1 : 0.75))
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(selected ? Color.brand : Color.white.opacity(hovering ? 0.06 : 0), in: Capsule())
            // The others are outlines.
            .overlay(Capsule().strokeBorder(Color.white.opacity(selected ? 0 : 0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(shortcut.map { "\(tab.title)  ⌘\($0)" } ?? tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityValue(count > 0 ? "\(count) items" : "empty")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// "Paste as…" / "Copy as…" for a text entry: plain, trimmed, another case,
/// pretty JSON, URL-encoded… only the transforms that would change it.
struct TransformMenus: View {
    let text: String
    let clipboard: ClipboardHistory
    /// Where the paste should go back to (a panel that took activation).
    var frontField: FrontField? = nil

    var body: some View {
        let transforms = TextTransform.applicable(to: text)
        if !transforms.isEmpty {
            if clipboard.canPaste {
                Menu("Paste as") {
                    ForEach(transforms) { transform in
                        Button(transform.title) { paste(transform) }
                    }
                }
            }
            Menu("Copy as") {
                ForEach(transforms) { transform in
                    Button(transform.title) { copy(transform) }
                }
            }
        }
        let extracts = TextExtract.Kind.allCases.map { ($0, TextExtract.extract($0, from: text)) }.filter { !$0.1.isEmpty }
        if !extracts.isEmpty {
            Menu("Extract") {
                ForEach(extracts, id: \.0) { kind, found in
                    Button("\(kind.title) (\(found.count))") {
                        clipboard.copy(text: found.joined(separator: "\n"))
                        FeedbackHUD.show("\(found.count) \(kind.title.lowercased()) copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: found.first)
                    }
                }
            }
        }
    }

    private func copy(_ transform: TextTransform) {
        guard let result = transform.apply(to: text) else { return }
        clipboard.copy(text: result)
        FeedbackHUD.show("Copied as \(transform.title)", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
    }

    private func paste(_ transform: TextTransform) {
        guard let result = transform.apply(to: text) else { return }
        clipboard.copy(text: result)
        if !clipboard.pressPaste(returningTo: frontField) {
            FeedbackHUD.show("Copied — press ⌘V to paste", symbol: "doc.on.clipboard", duration: .seconds(1.6))
        }
    }
}

/// The running focus session in the island's header: a ring filling as it goes,
/// the time left, the task; a click opens the task, the ■ stops it.
struct FocusPill: View {
    let timer: FocusTimer
    var onShowTask: (TaskItem) -> Void = { _ in }
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 2.5)
                Circle().trim(from: 0, to: timer.progress).stroke(Color.brand, style: SwiftUI.StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                Icon("timer", size: 10, weight: .bold).foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 18, height: 18)
            .animation(.linear(duration: 1), value: timer.progress)
            Text(timer.clock).font(.system(size: 12, weight: .semibold).monospacedDigit())
            if let task = timer.task {
                Text(task.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).frame(maxWidth: 140)
            }
            Button { timer.stop() } label: {
                Icon("stop.fill", size: 11, weight: .bold)
                    .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.5))
                    .frame(width: 20, height: 20)
                    .background(.white.opacity(hovering ? 0.14 : 0), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stop the focus session")
            .accessibilityLabel("Stop focus")
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 40)
        .fixedSize()
        .background(.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(hovering ? Color.white.opacity(0.18) : .clear))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture { if let task = timer.task { onShowTask(task) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus, \(timer.clock) left on \(timer.task?.title ?? "a task")")
    }
}

/// Pin / unpin, lit yellow while pinned.
private struct PinAction: View {
    let pinned: Bool
    let perform: () -> Void

    var body: some View {
        CardAction(symbol: pinned ? "pin.slash.fill" : "pin", help: pinned ? "Unpin" : "Pin", tint: pinned ? .yellow : .white, perform: perform)
    }
}

struct CaptureCard: View {
    let item: CaptureItem
    let library: CaptureLibrary
    let actions: HistoryActions
    /// For pasting straight into the front app / an open Klik editor.
    var clipboard: ClipboardHistory? = nil
    /// Where "Keep Colors" puts the capture's palette.
    var colorStore: ColorStore? = nil
    var onPreview: () -> Void = {}
    var onRename: () -> Void = {}
    /// A new group with this capture in it.
    var onNewGroup: () -> Void = {}
    /// Its place (from 1) in the comparison being built, if it is in one.
    var compareIndex: Int? = nil
    /// Put it in the comparison, or take it out; nil where comparing is not offered.
    var onToggleCompare: (() -> Void)? = nil
    @Environment(GroupStore.self) private var groups: GroupStore?
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, label: accessibilityLabel, onTap: tap) {
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
                    // The day is in the strip's header, so a default-named capture needs
                    // only its time; a renamed one keeps its name.
                    CardCaption(title: item.hasDefaultName ? "" : item.title, date: item.createdAt,
                                subtitle: item.createdAt.formatted(date: .omitted, time: .shortened)) {
                        if item.pinned {
                            Icon("pin.fill", size: 11).foregroundStyle(.yellow)
                        }
                        Badge(text: item.dimensions)
                    }
                }
        } actionRow: {
            CopyAction { actions.copy(item) }
            CardAction(symbol: "pencil", help: "Edit") { actions.edit(item) }
            PinAction(pinned: item.pinned) { library.togglePin(item) }
            CardAction(symbol: "trash", help: "Remove", tint: .red) { actions.delete(item) }
        } menu: {
            if let clipboard, clipboard.canPaste { Button("Paste", action: paste) }
            Button("Preview", action: onPreview)
            Button("Open in Viewer") { actions.preview(item) }
            Button("Edit") { actions.edit(item) }
            Button("Copy to Clipboard") { actions.copy(item) }
            Button("Pin to Screen") { actions.pinToScreen(item) }
            Button("Copy Share Link") { actions.shareLink(item) }
            Button("Make Task…") { actions.makeTask(item) }
            Menu("Palette") {
                Button("Keep Colors in the Colors Tab") { keepPalette() }
                Divider()
                ForEach(PaletteExtractor.Export.allCases, id: \.self) { export in
                    Button("Copy as \(export.title)") { copyPalette(as: export) }
                }
            }
            Button(item.pinned ? "Unpin" : "Pin") { library.togglePin(item) }
            if let groups {
                GroupMenu(groups: groups, kind: .captures, current: item.groupID, assign: { library.setGroup(item, $0) }, newGroup: onNewGroup)
            }
            if let onToggleCompare {
                Button(compareIndex == nil ? "Add to Comparison" : "Remove from Comparison", action: onToggleCompare)
            }
            Button("Rename…", action: onRename)
            Divider()
            Button("Delete", role: .destructive) { actions.delete(item) }
        }
        .overlay(alignment: .topTrailing) { compareToggle }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.brand, lineWidth: 2)
                .opacity(compareIndex == nil ? 0 : 1)
                .allowsHitTesting(false)
        }
    }

    /// ⌘-click adds the card to the comparison instead of copying it, which is how
    /// several captures are picked without leaving the row.
    private func tap() {
        if let onToggleCompare, NSEvent.modifierFlags.contains(.command) {
            onToggleCompare()
            return
        }
        actions.copy(item)
    }

    /// The tick in the corner: the card's number while it is in a comparison, an empty
    /// ring while the pointer is on the card.
    @ViewBuilder private var compareToggle: some View {
        if let onToggleCompare, compareIndex != nil || hovering {
            Button(action: onToggleCompare) {
                Group {
                    if let compareIndex {
                        Text("\(compareIndex)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Icon("plus", size: 12, weight: .bold).foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: 24, height: 24)
                .background(compareIndex == nil ? AnyShapeStyle(.black.opacity(0.8)) : AnyShapeStyle(Color.brand), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35)))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .padding(8)
            .help(compareIndex == nil ? "Add to the comparison (⌘-click)" : "Remove from the comparison")
        }
    }

    /// The capture's colors, worked out when first asked for.
    private func palette() -> [PickedColor] { actions.palette(item) }

    private func keepPalette() {
        let colors = palette()
        guard !colors.isEmpty else { FeedbackHUD.show("No colors found", symbol: "paintpalette"); return }
        for color in colors { _ = colorStore?.add(color) }
        FeedbackHUD.show("\(colors.count) colors kept", symbol: "paintpalette.fill", duration: .seconds(1.4), swatch: colors.first)
    }

    private func copyPalette(as export: PaletteExtractor.Export) {
        let colors = palette()
        guard !colors.isEmpty else { FeedbackHUD.show("No colors found", symbol: "paintpalette"); return }
        clipboard?.copy(text: PaletteExtractor.text(for: colors, as: export))
        FeedbackHUD.show("Palette copied as \(export.title)", symbol: "checkmark.circle.fill", duration: .seconds(1.4), swatch: colors.first)
    }

    private var accessibilityLabel: String {
        let name = item.hasDefaultName ? "Screenshot" : item.title
        let when = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(name), \(when), \(item.pixelWidth) by \(item.pixelHeight) pixels\(item.pinned ? ", pinned" : "")"
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
    /// A snippet from this entry's text.
    var onSnippet: (String) -> Void = { _ in }
    /// An image entry in the editor — annotate, blur, crop — like a capture.
    var onEdit: () -> Void = {}
    /// A new group with this entry in it.
    var onNewGroup: () -> Void = {}
    @Environment(GroupStore.self) private var groups: GroupStore?
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, label: "\(item.kind.rawValue.capitalized): \(item.name ?? item.title), \(item.createdAt.formatted(.relative(presentation: .named)))\(item.pinned ? ", pinned" : "")", onTap: copy) {
            content
                .overlay(alignment: .bottom) {
                    CardCaption(title: item.name ?? "", date: item.createdAt) {
                        if item.pinned {
                            Icon("pin.fill", size: 11).foregroundStyle(.yellow)
                        }
                        if let icon = clipboard.sourceIcon(for: item) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                                .help(item.sourceName ?? "")
                        }
                    }
                }
        } actionRow: {
            CopyAction(perform: copy)
            PinAction(pinned: item.pinned) { clipboard.togglePin(item) }
            if item.kind == .image {
                CardAction(symbol: "pencil", help: "Edit", perform: onEdit)
            }
            CardAction(symbol: "trash", help: "Remove", tint: .red) { clipboard.delete(item) }
        } menu: {
            Button("Copy") { copy() }
            if clipboard.canPaste { Button("Paste") { paste() } }
            Button("Preview", action: onPreview)
            if item.kind == .image {
                Button("Edit…", action: onEdit)
            }
            if item.kind == .color, let color = PickedColor(hex: item.text) {
                Menu("Copy as") {
                    ForEach(ColorFormat.allCases, id: \.self) { format in
                        Button(format.string(for: color)) {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(format.string(for: color), forType: .string)
                            FeedbackHUD.show("\(format.string(for: color)) copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), swatch: color)
                        }
                    }
                }
            }
            if item.kind == .text || item.kind == .link {
                TransformMenus(text: item.text, clipboard: clipboard)
            }
            if item.kind == .text {
                let fenced = CodeSnippet.fenced(item.text, as: code)
                Button("Copy as Code Block") {
                    clipboard.copy(text: fenced)
                    FeedbackHUD.show("Copied as ```\(code?.fence ?? "") block", symbol: "chevron.left.forwardslash.chevron.right", duration: .seconds(1.2))
                }
                if clipboard.canPaste {
                    Button("Paste as Code Block") {
                        clipboard.copy(text: fenced)
                        clipboard.pressPaste()
                    }
                }
            }
            Button(item.pinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
            if let groups {
                GroupMenu(groups: groups, kind: .clipboard, current: item.groupID, assign: { clipboard.setGroup(item, $0) }, newGroup: onNewGroup)
            }
            Button(item.name == nil ? "Name…" : "Rename…", action: onRename)
            if item.kind == .text || item.kind == .link || item.kind == .color {
                Button("Make Snippet…") { onSnippet(item.text) }
            }
            Divider()
            Button("Delete", role: .destructive) { clipboard.delete(item) }
        }
    }

    private func copy() {
        clipboard.copy(item)
        FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: item.contentTitle,
                         image: item.kind == .image ? clipboard.thumbnail(for: item) : nil, swatch: item.kind == .color ? PickedColor(hex: item.text) : nil)
    }

    /// Pastes straight into the front app when Accessibility allows it, otherwise
    /// copies and says so.
    private func paste() {
        if clipboard.paste(item) {
            FeedbackHUD.show("Pasted", symbol: "checkmark.circle.fill", duration: .seconds(1.0))
        } else {
            FeedbackHUD.show("Copied — press ⌘V to paste", symbol: "doc.on.clipboard", duration: .seconds(1.6))
        }
    }

    @ViewBuilder
    /// Code is recognised once per card, not on every redraw.
    @State private var language: CodeSnippet.Language??

    private var code: CodeSnippet.Language? {
        if let language { return language }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Group {
                if let code {
                    Text(CodeSnippet.highlighted(item.text.trimmingCharacters(in: .whitespacesAndNewlines), as: code))
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(7)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                        .overlay(alignment: .topTrailing) {
                            if !hovering {
                                Badge(text: "\(code.title) · \(item.text.split(whereSeparator: \.isNewline).count) lines")
                                    .padding(8)
                            }
                        }
                } else {
                    Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(7)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            }
            .onAppear { if language == nil { language = .some(CodeSnippet.detect(item.text)) } }
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Icon("link", size: 14, weight: .semibold)
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
                    Icon(item.filePaths.count > 1 ? "doc.on.doc" : "doc", size: 15, weight: .semibold)
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
    /// A snippet that pastes this file.
    var onSnippet: () -> Void = {}
    /// A new group with this asset in it.
    var onNewGroup: () -> Void = {}
    @Environment(GroupStore.self) private var groups: GroupStore?
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, label: "\(item.fileName), \(item.createdAt.formatted(.relative(presentation: .named)))\(item.pinned ? ", pinned" : "")", onTap: { assets.open(item) }) {
            content
                .overlay(alignment: .bottom) {
                    CardCaption(title: item.fileName, date: item.createdAt) {
                        if item.pinned {
                            Icon("pin.fill", size: 11).foregroundStyle(.yellow)
                        }
                        Badge(text: item.kind == .image && item.pixelWidth > 0 ? item.dimensions : item.sizeText)
                    }
                }
        } actionRow: {
            CopyAction {
                assets.copy(item)
                FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: item.fileName, image: assets.thumbnail(for: item))
            }
            CardAction(symbol: "arrow.up.forward.app", help: "Open") { assets.open(item) }
            PinAction(pinned: item.pinned) { assets.togglePin(item) }
            CardAction(symbol: "trash", help: "Remove", tint: .red) { assets.delete(item) }
        } menu: {
            if let clipboard, clipboard.canPaste { Button("Paste", action: paste) }
            Button("Preview", action: onPreview)
            Button("Open") { assets.open(item) }
            Button("Copy") { assets.copy(item) }
            Button("Reveal in Finder") { assets.reveal(item) }
            Button(item.pinned ? "Unpin" : "Pin") { assets.togglePin(item) }
            if let groups {
                GroupMenu(groups: groups, kind: .assets, current: item.groupID, assign: { assets.setGroup(item, $0) }, newGroup: onNewGroup)
            }
            Button("Rename…", action: onRename)
            Button("Make Snippet…", action: onSnippet)
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

/// A picked color: the swatch fills the card, the preferred format is the caption.
struct ColorCard: View {
    let entry: ColorEntry
    let colors: ColorStore
    let format: ColorFormat
    var onPreview: () -> Void = {}
    var onRename: () -> Void = {}
    /// A new group with this color in it.
    var onNewGroup: () -> Void = {}
    @Environment(AppPreferences.self) private var preferences
    @Environment(GroupStore.self) private var groups: GroupStore?
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, label: "Color \(entry.name ?? preferences.colorFormat.string(for: entry.color))\(entry.pinned ? ", pinned" : "")", onTap: { copy(as: format) }) {
            entry.color.swiftUIColor
                .overlay(alignment: .topLeading) {
                    if !entry.color.isInSRGBGamut {
                        Text("P3")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(entry.color.isDark ? .white : .black)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background((entry.color.isDark ? Color.white : Color.black).opacity(0.2), in: Capsule())
                            .padding(8)
                            .help("Outside the sRGB gamut — a Display P3 color")
                    }
                }
                .overlay(alignment: .bottom) {
                    CardCaption(title: entry.name ?? format.string(for: entry.color), date: entry.createdAt) {
                        if entry.pinned {
                            Icon("pin.fill", size: 11).foregroundStyle(.yellow)
                        }
                        if entry.name != nil || format != .hex { Badge(text: ColorFormat.hex.string(for: entry.color)) }
                    }
                }
        } actionRow: {
            CopyAction { copy(as: format) }
            PinAction(pinned: entry.pinned) { colors.togglePin(entry) }
            CardAction(symbol: "trash", help: "Remove", tint: .red) { colors.delete(entry) }
        } menu: {
            Button("Preview", action: onPreview)
            Button("Copy \(format.title)") { copy(as: format) }
            Menu("Copy as") {
                ForEach(ColorFormat.allCases, id: \.self) { other in
                    Button(other.string(for: entry.color)) { copy(as: other) }
                }
            }
            Button(entry.pinned ? "Unpin" : "Pin") { colors.togglePin(entry) }
            if let groups {
                GroupMenu(groups: groups, kind: .colors, current: entry.groupID, assign: { colors.setGroup(entry, $0) }, newGroup: onNewGroup)
            }
            Button(entry.name == nil ? "Name…" : "Rename…", action: onRename)
            Divider()
            Button("Delete", role: .destructive) { colors.delete(entry) }
        }
    }

    private func copy(as format: ColorFormat) {
        colors.copy(entry, as: format)
        preferences.colorFormat = format // the next copy uses the format used last
        FeedbackHUD.show("\(format.string(for: entry.color)) copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: entry.name, swatch: entry.color)
    }

    /// A swatch for dragging the color's text.
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
/// A task as a card, for search results: status, title, notes, project.
private struct TaskCard: View {
    let task: TaskItem
    let store: TaskStore
    var focus: FocusTimer? = nil
    var onOpen: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, label: "Task: \(task.title), \(task.status.title), \(task.priority.title) priority", onTap: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Icon(task.status.symbol, size: 16, weight: .medium)
                        .foregroundStyle(task.status.color)
                    Text(task.title)
                        .font(.system(size: 12, weight: .semibold))
                        .strikethrough(task.status == .complete, color: .white.opacity(0.5))
                        .foregroundStyle(task.status == .complete ? .white.opacity(0.5) : .white)
                        .lineLimit(2)
                }
                if task.hasMore {
                    Text(task.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .overlay(alignment: .bottom) {
                CardCaption(title: store.project(task.projectID)?.name ?? "", date: task.createdAt) {
                    if task.priority != .medium {
                        Icon(task.priority.symbol, size: 11, weight: .bold).foregroundStyle(task.priority.color)
                            .help(task.priority.title)
                    }
                    Badge(text: task.status.title)
                }
            }
        } actionRow: {
            CardAction(symbol: task.status.next.symbol, help: "Mark \(task.status.next.title.lowercased())", tint: task.status.next == .pending ? .white : task.status.next.color) {
                store.setStatus(task.status.next, for: task)
            }
            CardAction(symbol: "arrow.up.forward", help: "Open", perform: onOpen)
        } menu: {
            Button("Open", action: onOpen)
            Menu("Status") {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Button { store.setStatus(status, for: task) } label: { Label { Text(status.title) } icon: { Icon(status.symbol, weight: .medium) } }
                }
            }
            Menu("Priority") {
                ForEach(TaskPriority.allCases, id: \.self) { value in
                    Button { store.setPriority(value, for: task) } label: { Label { Text(value.title) } icon: { Icon(value.symbol, weight: .medium) } }
                }
            }
            if let focus {
                if focus.task?.id == task.id {
                    Button("Stop Focus (\(focus.clock) left)") { focus.stop() }
                } else {
                    Menu("Focus") {
                        ForEach(FocusTimer.lengths, id: \.self) { minutes in
                            Button("\(minutes) minutes") { focus.start(task, minutes: minutes) }
                        }
                    }
                }
            }
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }
}

/// The island is a non-activating panel that opens on hover, so it is not the key
/// window when the search field is clicked; typing needs it to be.
private struct KeyOnFocus: NSViewRepresentable {
    let focused: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard focused, let window = view.window, !window.isKeyWindow else { return }
        DispatchQueue.main.async { window.makeKey() }
    }
}

struct DragPayload {
    let writer: any NSPasteboardWriting
    let preview: NSImage
    /// Which of Klik's own items this is, for drops inside the island (onto a group).
    var reference: GroupAssignment?

    /// A file: other apps get a file URL carrying the sandbox extension they need to
    /// read a file in Klik's container.
    static func file(_ url: URL, preview: NSImage?, reference: GroupAssignment? = nil) -> DragPayload {
        DragPayload(writer: url as NSURL, preview: preview ?? NSWorkspace.shared.icon(forFile: url.path), reference: reference)
    }
}

/// The item being dragged out of a strip right now, so the island's own drop
/// targets (the group chips) know what it is, and the island does not take its
/// own card for a file arriving from outside.
enum IslandDrag {
    nonisolated(unsafe) static var current: GroupAssignment?
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
            IslandDrag.current = payload.reference
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
            // The drop handler runs first; clear a beat later so it can still read it.
            DispatchQueue.main.async { IslandDrag.current = nil }
            onDragEnded?()
        }
    }
}


/// "Group ▸" on a card's menu: none, each group of the kind (the current one
/// ticked), and a new one.
struct GroupMenu: View {
    let groups: GroupStore
    let kind: GroupKind
    let current: UUID?
    let assign: (UUID?) -> Void
    let newGroup: () -> Void

    var body: some View {
        Menu("Group") {
            Button {
                assign(nil)
            } label: {
                if current == nil { Label { Text("None") } icon: { Icon("checkmark", weight: .medium) } } else { Text("None") }
            }
            let all = groups.groups(for: kind)
            if !all.isEmpty { Divider() }
            ForEach(all) { group in
                Button {
                    assign(group.id)
                } label: {
                    if group.id == current { Label { Text(group.name) } icon: { Icon("checkmark", weight: .medium) } } else { Text(group.name) }
                }
            }
            Divider()
            Button("New Group…", action: newGroup)
        }
    }
}


/// A capture card takes images dropped onto it — another of Klik's cards, or a file
/// from anywhere — and hands them over to be laid out beside the capture. Dropping a
/// design on a screenshot is the quickest way to a before-and-after for a chat or an
/// agent: the comparison lands on the clipboard.
private struct CompareDrop: ViewModifier {
    /// The card underneath, so dropping a card on itself does nothing.
    let owner: GroupAssignment
    /// One of Klik's own items as an image, when the drag started inside the island.
    let resolve: (GroupAssignment) -> CapturedImage?
    let accept: ([CapturedImage]) -> Void
    @State private var targeted = false

    /// A drag from inside the island is taken unless it is this very card; anything
    /// from outside is read for images when it lands.
    private var accepting: Bool {
        guard let source = IslandDrag.current else { return true }
        return source != owner
    }

    func body(content: Content) -> some View {
        let lit = targeted && accepting
        content
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.brand, lineWidth: 2)
                    .opacity(lit ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if lit {
                    Label("Compare", systemImage: "rectangle.split.2x1")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.brand, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: lit)
            .onDrop(of: ImageDrop.contentTypes, isTargeted: $targeted) { providers in
                if let source = IslandDrag.current {
                    guard source != owner, let image = resolve(source) else { return false }
                    accept([image])
                    return true
                }
                Task { @MainActor in
                    let images = await ImageDrop.captures(from: providers)
                    guard !images.isEmpty else {
                        FeedbackHUD.show("No image in what was dropped", symbol: "photo")
                        return
                    }
                    accept(images)
                }
                return true
            }
    }
}

/// A chip that takes one of the island's own cards: it lights while a card of the
/// right kind hovers, and hands the card over on the drop.
private struct GroupDrop: ViewModifier {
    let kind: GroupKind
    let drop: (GroupAssignment) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(Capsule().strokeBorder(Color.brand, lineWidth: 1.5).opacity(targeted && IslandDrag.current?.kind == kind ? 1 : 0))
            .scaleEffect(targeted && IslandDrag.current?.kind == kind ? 1.06 : 1)
            .animation(.easeOut(duration: 0.12), value: targeted)
            .onDrop(of: [.item], isTargeted: $targeted) { _ in
                guard let item = IslandDrag.current, item.kind == kind else { return false }
                drop(item)
                return true
            }
    }
}


extension IslandItem {
    /// Pinned, for what can be (tasks and snippets cannot).
    var pinned: Bool {
        switch self {
        case .capture(let item): item.pinned
        case .clipboard(let item): item.pinned
        case .asset(let item): item.pinned
        case .color(let entry): entry.pinned
        case .task, .snippet, .note, .answer: false
        }
    }

    /// The group it is in, for what can be grouped.
    var groupID: UUID? {
        switch self {
        case .capture(let item): item.groupID
        case .clipboard(let item): item.groupID
        case .asset(let item): item.groupID
        case .color(let entry): entry.groupID
        case .task, .snippet, .note, .answer: nil
        }
    }
}
