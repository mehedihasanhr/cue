import AppKit
import SwiftUI

// MARK: - State

/// Which list is showing, what is searched for and which note is open — shared with
/// the window controller so a note can be opened from outside.
@Observable
@MainActor
final class NoteDashboardModel {
    private static let selectionKey = "notes.dashboard.selection"
    private static let sidebarKey = "notes.dashboard.sidebarCollapsed"
    private static let iconsKey = "notes.dashboard.icons"
    private static let peekWidthKey = "notes.dashboard.peekWidth"

    /// The side peek's width, dragged to by its left edge.
    var peekWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(peekWidth), forKey: Self.peekWidthKey) }
    }

    /// Icons picked for the lists, by `NoteDashboardSelection.rawValue`.
    private var icons: [String: String] {
        didSet { UserDefaults.standard.set(icons, forKey: Self.iconsKey) }
    }

    var selection: NoteDashboardSelection {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: Self.selectionKey) }
    }
    /// The sidebar folded away (⌃⌘S), for more room for the notes.
    var sidebarCollapsed: Bool {
        didSet {
            UserDefaults.standard.set(sidebarCollapsed, forKey: Self.sidebarKey)
            sidebarFloating = false
        }
    }
    /// The folded sidebar shown for a moment, floating over the page, while the
    /// pointer is at the window's left edge or on it.
    var sidebarFloating = false
    /// How wide the window's content is, kept by the dashboard as it lays out.
    var contentWidth: CGFloat = 0 {
        didSet { if !sidebarHidden { sidebarFloating = false } }
    }

    /// The sidebar folds itself away when the window cannot fit it beside the list and
    /// the open peek; `sidebarCollapsed`, the user's choice, is left alone.
    var sidebarSqueezedOut: Bool {
        guard contentWidth > 0 else { return false }
        let peek = openNoteID != nil && !noteAsPage ? NoteDashboardView.peekWidths.lowerBound : 0
        return contentWidth < NoteDashboardView.sidebarWidth + NoteDashboardView.mainMinimum + peek
    }

    var sidebarHidden: Bool { sidebarCollapsed || sidebarSqueezedOut }
    var query = ""
    /// The note in the side peek — or on its own page. A note's id is its file name,
    /// so renaming one changes this; the page says so when it saves.
    var openNoteID: String? {
        didSet { if openNoteID == nil { noteAsPage = false } }
    }
    /// The open note fills the main column instead of peeking in beside it.
    var noteAsPage = false
    /// Age groups folded away in the table; the old ones start folded.
    var collapsed: Set<NoteAge> = [.month, .older]
    /// The table is showing a line to type a new note's title in.
    var composing = false
    /// Bumped to put the caret in that line, even when it is already showing.
    var composeTick = 0
    /// Asked of the user before it happens.
    var pendingDeletion: Note?
    /// Bumped to put the caret in the search field (⌘F).
    var searchFocus = 0
    /// An image from a note, shown over the whole window.
    var viewingImage: URL?

    init() {
        let defaults = UserDefaults.standard
        selection = defaults.string(forKey: Self.selectionKey).flatMap(NoteDashboardSelection.init(rawValue:)) ?? .list(.all)
        sidebarCollapsed = defaults.bool(forKey: Self.sidebarKey)
        icons = defaults.dictionary(forKey: Self.iconsKey) as? [String: String] ?? [:]
        let stored = defaults.double(forKey: Self.peekWidthKey)
        peekWidth = stored > 0 ? min(max(CGFloat(stored), NoteDashboardView.peekWidths.lowerBound), NoteDashboardView.peekWidths.upperBound) : NoteDashboardView.peekWidth
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A list's icon: the one picked for it, else its own.
    func icon(for selection: NoteDashboardSelection) -> PageIcon {
        if let picked = icons[selection.rawValue].flatMap(PageIcon.init(rawValue:)) { return picked }
        switch selection {
        case .list(let list): return .symbol(list.symbol)
        }
    }

    /// Picks an icon for a list; nil puts its own back.
    func setIcon(_ icon: PageIcon?, for selection: NoteDashboardSelection) {
        icons[selection.rawValue] = icon?.rawValue
    }

    /// The icon over the page now showing (a search has the magnifying glass).
    var currentIcon: PageIcon {
        isSearching ? .symbol("magnifyingglass") : icon(for: selection)
    }

    /// What the main column is showing, for its title and the breadcrumb.
    var title: String {
        if isSearching { return "Search" }
        switch selection {
        case .list(let list): return list.title
        }
    }

    /// Closes the side peek; a note open as a page stays.
    func closePeek() {
        guard openNoteID != nil, !noteAsPage else { return }
        openNoteID = nil
    }

    /// ⌃⌘S and the sidebar button. With no room to dock it, the sidebar floats out
    /// (or back in) instead.
    func toggleSidebar() {
        if sidebarSqueezedOut, !sidebarCollapsed {
            sidebarFloating.toggle()
            return
        }
        withAnimation(.easeOut(duration: 0.2)) { sidebarCollapsed.toggle() }
    }

    /// Brings the sidebar to hand: docked when it can be, floating when it cannot.
    func revealSidebar() {
        if sidebarCollapsed { toggleSidebar() }
        if sidebarSqueezedOut { sidebarFloating = true }
    }

    /// ⌘N and the New button: the line to type a new note's title in. A note is its
    /// file, and a file needs a name, so a note is never made empty — it starts with
    /// the line that becomes its title.
    func composeNew() {
        noteAsPage = false
        collapsed.remove(.today)
        composing = true
        composeTick += 1
    }
}

// MARK: - Window

/// The notes dashboard: every note in a window of its own, laid out the way the task
/// dashboard is — a quiet sidebar of lists, the notes as a table grouped by when they
/// were last written, and the open note in a side peek or as a page of its own.
final class NoteDashboardWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let model = NoteDashboardModel()

    init(store: NoteStore) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let buttons = WindowButtons(close: { [weak window] in window?.performClose(nil) },
                                    minimize: { [weak window] in window?.miniaturize(nil) },
                                    zoom: { [weak window] in window?.zoom(nil) })
        let root = NoteDashboardView(store: store, buttons: buttons)
            .environment(model)
            .frame(minWidth: 860, minHeight: 540)
        let host = NSHostingController(rootView: root)
        // See SettingsWindowController: the window keeps its own size, so the hosting
        // controller never pushes one up mid-display-cycle.
        host.sizingOptions = []
        window.contentViewController = host
        window.contentMinSize = CGSize(width: 860, height: 540)
        window.title = "Cue Notes"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 1180, height: 760))
        window.center()
        window.setFrameAutosaveName("CueNoteDashboard")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Opens in front of every other app's windows and takes focus; with a note, that
    /// note is open in the side peek.
    func present(note: Note? = nil) {
        if let note {
            model.query = ""
            model.selection = .list(.all)
            model.openNoteID = note.id
        }
        let wasOpen = window?.isVisible ?? false
        showWindow(nil)
        guard let window else { return }
        NSApp.present(window)
        if !wasOpen { window.makeFirstResponder(nil) }
    }

    /// Clicked back into, the window comes up over every other app's, with Cue active.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window, !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    #if DEBUG
    /// The open note as a page or in the peek (for `cue://debug/notes`).
    func showAsPage(_ page: Bool) {
        model.noteAsPage = page
    }
    #endif
}

// MARK: - Root

struct NoteDashboardView: View {
    let store: NoteStore
    let buttons: WindowButtons
    @Environment(NoteDashboardModel.self) private var model

    static let sidebarWidth: CGFloat = 240
    static let peekWidth: CGFloat = 480
    static let peekWidths: ClosedRange<CGFloat> = 380...1100
    /// The least the list in the middle is given while the peek is open.
    static let mainMinimum: CGFloat = 340
    static let topBarHeight: CGFloat = 44
    static let windowRadius: CGFloat = 14

    /// The peek's width in a window `width` wide, never so wide that the sidebar and
    /// the list no longer fit beside it.
    private func fittedPeekWidth(in width: CGFloat) -> CGFloat {
        let room = width - (model.sidebarHidden ? 0 : Self.sidebarWidth) - Self.mainMinimum
        return min(model.peekWidth, max(room, Self.peekWidths.lowerBound))
    }

    var body: some View {
        GeometryReader { proxy in
            columns(width: proxy.size.width)
                .onAppear { model.contentWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in model.contentWidth = width }
        }
    }

    private func columns(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if !model.sidebarHidden {
                NoteDashboardSidebar(store: store, buttons: buttons)
                    .frame(width: Self.sidebarWidth)
                    .background(NotionStyle.sidebar)
                    .overlay(alignment: .trailing) { Hairline(axis: .vertical) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                NoteTopBar(store: store, buttons: buttons, note: openNote)
                Group {
                    if model.noteAsPage, let note = openNote {
                        NotePageView(store: store, note: note, style: .page)
                            .id(note.id)
                            .transition(.opacity)
                    } else {
                        NoteDashboardMain(store: store)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipped()
            if !model.noteAsPage, let note = openNote {
                NotePageView(store: store, note: note, style: .peek)
                    .id(note.id)
                    .frame(width: fittedPeekWidth(in: width))
                    .background(NotionStyle.page)
                    .overlay(alignment: .leading) {
                        NotePeekResizer(width: Binding(get: { model.peekWidth }, set: { model.peekWidth = $0 }), sidebarShown: !model.sidebarHidden)
                    }
                    .transition(.move(edge: .trailing))
            }
        }
        .foregroundStyle(NotionStyle.text)
        .background(NotionStyle.page)
        .overlay(alignment: .topLeading) {
            if model.sidebarHidden {
                NoteFloatingSidebar(store: store, buttons: buttons)
            }
        }
        .overlay {
            if let url = model.viewingImage {
                TaskImageViewer(url: url) { model.viewingImage = nil }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.viewingImage)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: openNote == nil)
        .animation(.easeOut(duration: 0.2), value: model.sidebarHidden)
        .animation(.easeOut(duration: 0.2), value: model.noteAsPage)
        .clipShape(RoundedRectangle(cornerRadius: Self.windowRadius, style: .continuous))
        .ignoresSafeArea()
        .background { shortcuts }
        .onExitCommand {
            if model.viewingImage != nil { model.viewingImage = nil } else { model.openNoteID = nil }
        }
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }), presenting: model.pendingDeletion) { note in
            Button("Delete", role: .destructive) {
                if model.openNoteID == note.id { model.openNoteID = nil }
                store.delete(note)
                model.pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
        } message: { note in
            Text("“\(note.title)” — its file goes too.")
        }
    }

    private var openNote: Note? {
        model.openNoteID.flatMap { id in store.notes.first { $0.id == id } }
    }

    /// The window's keys: ⌘N a new note, ⌘F search, ⌘⌫ delete the open note,
    /// ⌃⌘S the sidebar.
    private var shortcuts: some View {
        ZStack {
            Button("") { model.composeNew() }.keyboardShortcut("n")
            Button("") { model.searchFocus += 1 }.keyboardShortcut("f")
            Button("") { if let note = openNote { model.pendingDeletion = note } }.keyboardShortcut(.delete, modifiers: .command)
            Button("") { model.toggleSidebar() }.keyboardShortcut("s", modifiers: [.control, .command])
        }
        .hidden()
    }
}

/// The side peek's left edge: a hairline that turns blue under the pointer and drags
/// the peek wider or narrower, leaving the table at least some room.
private struct NotePeekResizer: View {
    @Binding var width: CGFloat
    var sidebarShown = true
    @State private var hovering = false
    @State private var start: CGFloat?

    var body: some View {
        ZStack {
            Hairline(axis: .vertical)
            if hovering || start != nil {
                Rectangle().fill(NotionStyle.accent.opacity(0.6)).frame(width: 2)
            }
        }
        .frame(width: 1)
        .overlay {
            Color.clear
                .frame(width: 10)
                .contentShape(Rectangle())
                .onHover { over in
                    hovering = over
                    if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let windowWidth = NSApp.keyWindow?.frame.width ?? 1200
                            let beside = (sidebarShown ? NoteDashboardView.sidebarWidth : 0) + NoteDashboardView.mainMinimum
                            let most = min(NoteDashboardView.peekWidths.upperBound, windowWidth - beside)
                            let origin = start ?? min(width, max(most, NoteDashboardView.peekWidths.lowerBound))
                            start = origin
                            width = min(max(origin - value.translation.width, NoteDashboardView.peekWidths.lowerBound), max(most, NoteDashboardView.peekWidths.lowerBound))
                        }
                        .onEnded { _ in start = nil }
                )
        }
        .help("Drag to resize")
    }
}

/// The traffic lights and the button that folds the sidebar.
private struct NoteWindowChrome: View {
    let buttons: WindowButtons
    @Environment(NoteDashboardModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            TrafficLights(onClose: buttons.close, onMinimize: buttons.minimize, onZoom: buttons.zoom)
            NotionIconButton(symbol: "sidebar.left", help: model.sidebarHidden ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)", size: 14) {
                model.toggleSidebar()
            }
            .onHover { over in
                if over, model.sidebarHidden { model.sidebarFloating = true }
            }
        }
    }
}

/// The folded sidebar, brought out over the page while the pointer wants it.
private struct NoteFloatingSidebar: View {
    let store: NoteStore
    let buttons: WindowButtons
    @Environment(NoteDashboardModel.self) private var model
    @State private var hiding: Task<Void, Never>?

    private static let edge: CGFloat = 8
    private static let linger: Duration = .milliseconds(300)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: Self.edge)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { $0 ? show() : hideSoon() }
            if model.sidebarFloating {
                NoteDashboardSidebar(store: store, buttons: buttons, floating: true)
                    .frame(width: NoteDashboardView.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(NotionStyle.card, in: shape)
                    .overlay { shape.stroke(NotionStyle.divider) }
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.12), radius: 16, x: 4, y: 6)
                    .padding(.bottom, 10)
                    .onHover { $0 ? show() : hideSoon() }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(.top, NoteDashboardView.topBarHeight)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.18), value: model.sidebarFloating)
        .onDisappear { hiding?.cancel() }
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 10, topTrailingRadius: 10, style: .continuous)
    }

    private func show() {
        hiding?.cancel()
        hiding = nil
        if !model.sidebarFloating { model.sidebarFloating = true }
    }

    private func hideSoon() {
        hiding?.cancel()
        hiding = Task {
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            model.sidebarFloating = false
        }
    }
}

// MARK: - Top bar

/// The thin bar over the content: where you are as a breadcrumb (Notes › list ›
/// note), and on a note's page when it was last written and what can be done to it.
private struct NoteTopBar: View {
    let store: NoteStore
    let buttons: WindowButtons
    let note: Note?
    @Environment(NoteDashboardModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            if model.sidebarHidden {
                NoteWindowChrome(buttons: buttons)
            }
            NotionIconButton(symbol: "chevron.left", help: model.noteAsPage ? "Back to \(model.title) (⎋)" : "Back", size: 13,
                             tint: model.noteAsPage ? NotionStyle.secondary : NotionStyle.tertiary.opacity(0.6)) { leavePage() }
                .disabled(!model.noteAsPage)
                .keyboardShortcut("[", modifiers: .command)
                .padding(.trailing, 4)
            crumb("Notes", icon: .symbol("note.text")) { leavePage() }
            separator
            crumb(model.title, icon: model.currentIcon) { leavePage() }
            if model.noteAsPage, let note {
                separator
                crumb(note.title, icon: .symbol("doc.text")) {}
            }
            Spacer(minLength: 12)
            if model.noteAsPage, let note {
                Text("Edited \(note.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 13))
                    .foregroundStyle(NotionStyle.tertiary)
                    .padding(.trailing, 6)
                NotionIconButton(symbol: "sidebar.right", help: "Open in side peek") { model.noteAsPage = false }
                NoteMoreMenu(store: store, note: note)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NoteDashboardView.topBarHeight)
    }

    private func leavePage() {
        if model.noteAsPage { model.openNoteID = nil }
    }

    private var separator: some View {
        Text("/").font(.system(size: 14)).foregroundStyle(NotionStyle.tertiary).padding(.horizontal, 2)
    }

    private func crumb(_ title: String, icon: PageIcon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                PageIconView(icon: icon, size: 13)
                Text(title).font(.system(size: 14)).lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotionHoverStyle())
    }
}

/// The … menu on a note: copy it, show the file, delete it.
struct NoteMoreMenu: View {
    let store: NoteStore
    let note: Note
    @Environment(NoteDashboardModel.self) private var model

    var body: some View {
        Menu {
            NoteRowMenu(store: store, note: note)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13))
                .foregroundStyle(NotionStyle.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

/// What can be done to a note, in the … menu and on a right-click.
struct NoteRowMenu: View {
    let store: NoteStore
    let note: Note
    @Environment(NoteDashboardModel.self) private var model

    var body: some View {
        Button("Open in Side Peek") { model.openNoteID = note.id }
        Button("Open as Page") {
            model.openNoteID = note.id
            model.noteAsPage = true
        }
        Divider()
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note.text, forType: .string)
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(for: note)])
        }
        Divider()
        Button("Delete Note", role: .destructive) { model.pendingDeletion = note }
    }
}

// MARK: - Sidebar

private struct NoteDashboardSidebar: View {
    let store: NoteStore
    let buttons: WindowButtons
    /// Brought out over the page while folded: the window's buttons stay in the top
    /// bar, so the sidebar starts at its search field.
    var floating = false
    @Environment(NoteDashboardModel.self) private var model
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if floating {
                Spacer().frame(height: 10)
            } else {
                HStack(spacing: 0) {
                    NoteWindowChrome(buttons: buttons)
                    Spacer(minLength: 0)
                    NotionIconButton(symbol: "square.and.pencil", help: "New note (⌘N)", size: 14) { model.composeNew() }
                }
                .padding(.horizontal, 8)
                .frame(height: NoteDashboardView.topBarHeight)
            }

            searchField
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(NoteDashboardList.allCases) { list in
                        NoteSidebarItem(title: list.title, icon: model.icon(for: .list(list)),
                                        count: NoteDashboardQuery.count(store.notes, list: list),
                                        selected: !model.isSearching && model.selection == .list(list)) {
                            select(.list(list))
                        }
                    }
                    folderSection
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .thinScrollers()
            .contentShape(Rectangle())
            .onTapGesture { model.closePeek() }
        }
        .onChange(of: model.searchFocus) { _, _ in
            model.revealSidebar()
            searching = true
        }
    }

    /// Where the notes are. A note is a Markdown file, and which folder it sits in is
    /// the one thing about the collection worth saying — it is what decides whether
    /// they reach iCloud Drive or an Obsidian vault.
    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NotionStyle.tertiary)
                .padding(.leading, 8)
                .padding(.top, 18)
                .padding(.bottom, 2)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([store.folderURL])
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: store.folderIsCustom ? "folder" : "internaldrive")
                        .font(.system(size: 13))
                        .frame(width: 20)
                    Text(store.folderURL.lastPathComponent)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                }
                .foregroundStyle(NotionStyle.text.opacity(0.85))
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(NotionHoverStyle())
            .help("Show the notes folder in Finder — \(store.folderURL.path)")
        }
    }

    private func select(_ selection: NoteDashboardSelection) {
        model.query = ""
        searching = false
        model.composing = false
        model.openNoteID = nil
        model.selection = selection
    }

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(NotionStyle.tertiary)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searching)
            if model.query.isEmpty {
                Text("⌘F").font(.system(size: 11)).foregroundStyle(NotionStyle.tertiary)
            } else {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(NotionStyle.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(NotionStyle.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onExitCommand { model.query = ""; searching = false }
        .help("Search every note, titles and words alike (⌘F)")
    }
}

/// A list in the sidebar: a grey glyph, its name and how many notes are in it.
private struct NoteSidebarItem: View {
    let title: String
    let icon: PageIcon
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PageIconView(icon: icon, size: 14)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? NotionStyle.text : NotionStyle.text.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(NotionStyle.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? NotionStyle.selectedRow : hovering ? NotionStyle.hover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(count > 0 ? "\(count) notes" : "")
    }
}

// MARK: - Main column

/// The database page: an icon and a big title, the view as a tab with a New button,
/// then the table.
private struct NoteDashboardMain: View {
    let store: NoteStore
    @Environment(NoteDashboardModel.self) private var model

    static let margin: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Self.margin)
                .padding(.top, 22)
            tabs
                .padding(.horizontal, Self.margin)
                .padding(.top, 18)
            if model.isSearching && shown.isEmpty {
                empty("No note matches “\(model.query)”.")
            } else if shown.isEmpty && !model.composing {
                empty(model.selection == .list(.all) ? "No notes yet. ⌘N starts one." : "Nothing in \(model.title.lowercased()).")
            } else {
                NoteTable(store: store, notes: shown, groups: groups)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.closePeek() }
    }

    private func empty(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundStyle(NotionStyle.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the page lists: every match for a search, else the chosen list.
    private var shown: [Note] {
        if model.isSearching { return store.notes.filter { NoteDashboardQuery.matches($0, query: model.query) } }
        switch model.selection {
        case .list(let list): return NoteDashboardQuery.filter(store.notes, list: list)
        }
    }

    /// The table's groups: those with notes, plus Today while a new note is being
    /// typed, so the line has somewhere to sit.
    private var groups: [NoteAge] {
        let present = NoteDashboardQuery.groups(shown)
        guard model.composing, !model.isSearching, !present.contains(.today) else { return present }
        return [.today] + present
    }

    private var header: some View {
        HStack(spacing: 8) {
            NotePageIconButton()
            Text(model.title)
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
        }
    }

    /// One view for now — notes have nothing a board would column by — kept as a tab
    /// so the page reads as the task dashboard's sibling.
    private var tabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tab(title: "Table", symbol: "tablecells")
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    newButton(labelled: true)
                    newButton(labelled: false)
                }
            }
            .padding(.bottom, 6)
            Hairline()
        }
    }

    private func newButton(labelled: Bool) -> some View {
        Button(action: model.composeNew) {
            Group {
                if labelled {
                    Text("New")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 12)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28)
                }
            }
            .foregroundStyle(.white)
            .frame(height: 28)
            .background(NotionStyle.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("New note (⌘N)")
        .fixedSize()
    }

    private func tab(title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 13))
            Text(title).font(.system(size: 14, weight: .medium))
        }
        .fixedSize()
        .foregroundStyle(NotionStyle.text)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .overlay(alignment: .bottom) {
            Rectangle().fill(NotionStyle.text).frame(height: 2).offset(y: 7)
        }
    }
}

/// The page's icon beside its title: a click opens the picker, as in Notion.
private struct NotePageIconButton: View {
    @Environment(NoteDashboardModel.self) private var model
    @State private var picking = false
    @State private var hovering = false

    var body: some View {
        let icon = model.currentIcon
        Button {
            picking = true
        } label: {
            PageIconView(icon: icon, size: 21, weight: .light)
                .frame(width: 36, height: 36)
                .background(hovering && !model.isSearching ? NotionStyle.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSearching)
        .onHover { hovering = $0 }
        .help("Change icon")
        .accessibilityLabel("Change icon")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            PageIconPicker(current: icon) { picked in
                model.setIcon(picked, for: model.selection)
                picking = false
            }
        }
        .padding(.leading, -8)
    }
}

// MARK: - Table

/// The table's columns: the name takes what is left, the rest are fixed.
private enum NoteColumns {
    static let gutter: CGFloat = 28
    static let name: CGFloat = 300
    static let words: CGFloat = 120
    static let created: CGFloat = 150
    static let updated: CGFloat = 150
    static var minimumWidth: CGFloat { gutter + name + words + created + updated + 4 }
}

/// Every note in groups by when it was last written, each a ▸ toggle with its tag and
/// count, the column headings and the rows.
private struct NoteTable: View {
    let store: NoteStore
    let notes: [Note]
    let groups: [NoteAge]
    @Environment(NoteDashboardModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { age in
                            NoteTableGroup(store: store, age: age, notes: NoteDashboardQuery.notes(notes, in: age))
                        }
                    }
                    .frame(width: max(proxy.size.width - (NoteDashboardMain.margin - NoteColumns.gutter) * 2, NoteColumns.minimumWidth), alignment: .leading)
                    .padding(.horizontal, NoteDashboardMain.margin - NoteColumns.gutter)
                    .padding(.bottom, 40)
                }
            }
            .thinScrollers()
        }
    }
}

private struct NoteTableGroup: View {
    let store: NoteStore
    let age: NoteAge
    let notes: [Note]
    @Environment(NoteDashboardModel.self) private var model

    var body: some View {
        let folded = model.collapsed.contains(age)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if folded { model.collapsed.remove(age) } else { model.collapsed.insert(age) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(NotionStyle.secondary)
                        .rotationEffect(.degrees(folded ? 0 : 90))
                    NotionTag(text: age.title, color: age.tint, dot: true)
                    Text("\(notes.count)")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(NotionStyle.tertiary)
                }
                .padding(.leading, NoteColumns.gutter - 18)
                .padding(.trailing, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.bottom, 4)
            .accessibilityLabel("\(age.title), \(notes.count) notes, \(folded ? "folded" : "unfolded")")

            if !folded {
                columnHeadings
                ForEach(notes) { note in
                    NoteTableRow(store: store, note: note, open: model.openNoteID == note.id)
                }
                // A new note is always written now, so the line belongs to Today.
                if age == .today {
                    if model.composing {
                        NewNoteLine(store: store)
                            .padding(.leading, NoteColumns.gutter)
                            .overlay(alignment: .bottom) { Hairline().padding(.leading, NoteColumns.gutter) }
                    } else {
                        Button(action: model.composeNew) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus").font(.system(size: 13))
                                Text("New note").font(.system(size: 14))
                                Spacer()
                            }
                            .foregroundStyle(NotionStyle.tertiary)
                            .padding(.horizontal, 8)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(NotionHoverStyle())
                        .padding(.leading, NoteColumns.gutter)
                    }
                }
            }
        }
    }

    private var columnHeadings: some View {
        HStack(spacing: 0) {
            heading("Note name", symbol: "textformat", width: nil)
            Hairline(axis: .vertical)
            heading("Words", symbol: "number", width: NoteColumns.words)
            Hairline(axis: .vertical)
            heading("Created", symbol: "clock", width: NoteColumns.created)
            Hairline(axis: .vertical)
            heading("Updated", symbol: "clock.arrow.circlepath", width: NoteColumns.updated)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
        .padding(.leading, NoteColumns.gutter)
    }

    private func heading(_ title: String, symbol: String, width: CGFloat?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12))
            Text(title).font(.system(size: 14))
            Spacer(minLength: 0)
        }
        .foregroundStyle(NotionStyle.secondary)
        .padding(.horizontal, 8)
        .frame(height: 34)
        .frame(minWidth: width == nil ? NoteColumns.name : nil, maxWidth: width ?? .infinity)
        .frame(width: width)
    }
}

/// One note as a table row: its title with the first line of its text behind it, how
/// many words it holds, and when it was written. A click opens it beside the table.
private struct NoteTableRow: View {
    let store: NoteStore
    let note: Note
    let open: Bool
    @Environment(NoteDashboardModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if NoteDashboardQuery.carriesFiles(note) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11))
                        .foregroundStyle(NotionStyle.tertiary)
                        .help("This note carries a picture or a file")
                }
            }
            .frame(width: NoteColumns.gutter)
            HStack(spacing: 0) {
                nameCell
                Hairline(axis: .vertical)
                cell(width: NoteColumns.words) {
                    NotionTag(text: "\(NoteDashboardQuery.words(in: note))", color: .gray)
                }
                Hairline(axis: .vertical)
                cell(width: NoteColumns.created) {
                    Text(note.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 13))
                        .foregroundStyle(NotionStyle.secondary)
                        .help(note.createdAt.formatted(date: .complete, time: .shortened))
                }
                Hairline(axis: .vertical)
                cell(width: NoteColumns.updated) {
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 13))
                        .foregroundStyle(NotionStyle.secondary)
                        .help(note.updatedAt.formatted(date: .complete, time: .shortened))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(open ? NotionStyle.openRow : hovering ? NotionStyle.hover : .clear)
            .overlay(alignment: .bottom) { Hairline() }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.openNoteID = note.id }
        .contextMenu { NoteRowMenu(store: store, note: note) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(note.title)
        .accessibilityAddTraits(open ? [.isSelected, .isButton] : .isButton)
    }

    private var nameCell: some View {
        HStack(spacing: 8) {
            Text(note.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NotionStyle.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(note.title)
            // What the note goes on to say, greyed behind the title: a note has no
            // status to show, and the first line of it is what tells two apart.
            if !note.summary.isEmpty, !hovering {
                Text(note.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(NotionStyle.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if hovering {
                Button {
                    model.openNoteID = note.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sidebar.right").font(.system(size: 10, weight: .medium))
                        Text("OPEN").font(.system(size: 11, weight: .medium)).tracking(0.4)
                    }
                    .foregroundStyle(NotionStyle.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(NotionStyle.card, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(NotionStyle.divider))
                    .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                }
                .buttonStyle(.plain)
                .help("Open in side peek")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minWidth: NoteColumns.name, maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private func cell(width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 8)
            .frame(width: width, alignment: .leading)
            .frame(minHeight: 36)
    }
}

/// A line to type a new note's title in, at the foot of Today's group. A note is a
/// file named after its title, so this is the title: ↩ writes the file and opens it
/// beside the table, ready for the rest; ⎋ puts the line away.
private struct NewNoteLine: View {
    let store: NoteStore
    @Environment(NoteDashboardModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(NotionStyle.tertiary)
            TextField("Note title", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit(commit)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .onAppear { focused = true }
        .onChange(of: model.composeTick) { _, _ in focused = true }
        .onExitCommand { dismiss() }
        .onChange(of: focused) { _, focused in
            // Clicked away from with nothing typed: the line goes rather than sitting
            // there empty.
            if !focused, text.trimmingCharacters(in: .whitespaces).isEmpty { dismiss() }
        }
    }

    private func commit() {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return dismiss() }
        text = ""
        guard let note = store.add(text: title) else { return }
        model.composing = false
        model.openNoteID = note.id
    }

    private func dismiss() {
        text = ""
        model.composing = false
    }
}
