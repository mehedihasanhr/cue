import AppKit
import SwiftUI

// MARK: - State

/// Which note is open, what is searched for, and which folders are unfolded.
@Observable
@MainActor
final class NoteDashboardModel {
    private static let openKey = "notes.dashboard.open"
    private static let sidebarKey = "notes.dashboard.sidebarCollapsed"
    private static let widthKey = "notes.dashboard.listWidth"
    private static let expandedKey = "notes.dashboard.expanded"

    /// The list's width, dragged to by its right edge.
    var listWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(listWidth), forKey: Self.widthKey) }
    }
    /// The list folded away (⌃⌘S), for the note alone.
    var sidebarCollapsed: Bool {
        didSet {
            UserDefaults.standard.set(sidebarCollapsed, forKey: Self.sidebarKey)
            sidebarFloating = false
        }
    }
    /// The folded list brought out over the note while the pointer wants it.
    var sidebarFloating = false
    /// How wide the window's content is, kept by the dashboard as it lays out.
    var contentWidth: CGFloat = 0 {
        didSet { if !sidebarHidden { sidebarFloating = false } }
    }

    /// The list folds itself away when the window cannot fit it beside the note.
    var sidebarSqueezedOut: Bool {
        guard contentWidth > 0 else { return false }
        return contentWidth < NoteDashboardView.listWidths.lowerBound + NoteDashboardView.noteMinimum
    }

    var sidebarHidden: Bool { sidebarCollapsed || sidebarSqueezedOut }
    var query = ""

    /// The note being read, by its path. A note's id is its file, so renaming one
    /// changes this; the note view says so when it saves.
    var openNoteID: String? {
        didSet { UserDefaults.standard.set(openNoteID, forKey: Self.openKey) }
    }
    /// The folders unfolded in the list, by path.
    var expanded: Set<String> {
        didSet { UserDefaults.standard.set(Array(expanded), forKey: Self.expandedKey) }
    }
    /// The folder a new note or folder is being named in, and which of the two.
    var composing: Composing?
    /// Bumped to put the caret in that line, even when it is already showing.
    var composeTick = 0
    /// A folder being renamed in place.
    var renaming: String?
    /// Asked of the user before it happens.
    var pendingNoteDeletion: Note?
    var pendingFolderDeletion: String?
    /// Bumped to put the caret in the search field (⌘F).
    var searchFocus = 0
    /// An image from a note, shown over the whole window.
    var viewingImage: URL?

    /// A line being typed in the list: a note's title, or a folder's name.
    struct Composing: Equatable {
        enum Kind { case note, folder }
        var kind: Kind
        /// The folder it goes in ("" is the top).
        var parent: String
    }

    init() {
        let defaults = UserDefaults.standard
        sidebarCollapsed = defaults.bool(forKey: Self.sidebarKey)
        openNoteID = defaults.string(forKey: Self.openKey)
        expanded = Set(defaults.stringArray(forKey: Self.expandedKey) ?? [])
        let stored = defaults.double(forKey: Self.widthKey)
        listWidth = stored > 0 ? min(max(CGFloat(stored), NoteDashboardView.listWidths.lowerBound), NoteDashboardView.listWidths.upperBound) : NoteDashboardView.listWidth
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func isExpanded(_ folder: String) -> Bool { expanded.contains(folder) }

    func toggle(_ folder: String) {
        if expanded.contains(folder) { expanded.remove(folder) } else { expanded.insert(folder) }
    }

    /// Unfolds a folder and everything above it, so a note inside can be seen.
    func reveal(_ folder: String) {
        var path = folder
        while !path.isEmpty {
            expanded.insert(path)
            path = (path as NSString).deletingLastPathComponent
        }
    }

    /// ⌃⌘S and the list button.
    func toggleSidebar() {
        if sidebarSqueezedOut, !sidebarCollapsed {
            sidebarFloating.toggle()
            return
        }
        withAnimation(.easeOut(duration: 0.2)) { sidebarCollapsed.toggle() }
    }

    func revealSidebar() {
        if sidebarCollapsed { toggleSidebar() }
        if sidebarSqueezedOut { sidebarFloating = true }
    }

    /// ⌘N and the New button: the line to type a new note's title in. A note is a
    /// file, and a file needs a name, so a note is never made empty.
    func composeNote(in parent: String = "") {
        reveal(parent)
        if !parent.isEmpty { expanded.insert(parent) }
        composing = Composing(kind: .note, parent: parent)
        composeTick += 1
    }

    func composeFolder(in parent: String = "") {
        reveal(parent)
        if !parent.isEmpty { expanded.insert(parent) }
        composing = Composing(kind: .folder, parent: parent)
        composeTick += 1
    }
}

// MARK: - Window

/// The notes window: the notes themselves down the left, in their folders, and the
/// one being read on the right. Two panes, no database — a note is a file in a
/// folder, and that is what the window shows.
final class NoteDashboardWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let model = NoteDashboardModel()
    private let store: NoteStore

    init(store: NoteStore) {
        self.store = store
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1060, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let buttons = WindowButtons(close: { [weak window] in window?.performClose(nil) },
                                    minimize: { [weak window] in window?.miniaturize(nil) },
                                    zoom: { [weak window] in window?.zoom(nil) })
        let root = NoteDashboardView(store: store, buttons: buttons)
            .environment(model)
            .frame(minWidth: 720, minHeight: 480)
        let host = NSHostingController(rootView: root)
        // See SettingsWindowController: the window keeps its own size, so the hosting
        // controller never pushes one up mid-display-cycle.
        host.sizingOptions = []
        window.contentViewController = host
        window.contentMinSize = CGSize(width: 720, height: 480)
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
        window.setContentSize(CGSize(width: 1060, height: 720))
        window.center()
        window.setFrameAutosaveName("CueNoteDashboard")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Opens in front of every other app's windows and takes focus; with a note,
    /// that note is the one being read.
    func present(note: Note? = nil) {
        if let note {
            model.query = ""
            model.reveal(note.folder)
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
        // The watcher only hears about the top folder, so a note written in a
        // sub-folder elsewhere (Obsidian, iCloud) is picked up on coming back.
        store.reload()
        guard let window, !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    #if DEBUG
    /// For `cue://debug/note`: which note is being read.
    func show(note: Note) {
        model.reveal(note.folder)
        model.openNoteID = note.id
    }
    #endif
}

// MARK: - Root

struct NoteDashboardView: View {
    let store: NoteStore
    let buttons: WindowButtons
    @Environment(NoteDashboardModel.self) private var model

    static let listWidth: CGFloat = 280
    static let listWidths: ClosedRange<CGFloat> = 220...460
    /// The least the note itself is given.
    static let noteMinimum: CGFloat = 420
    static let topBarHeight: CGFloat = 44
    static let windowRadius: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            columns
                .onAppear { model.contentWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in model.contentWidth = width }
        }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            if !model.sidebarHidden {
                NoteList(store: store, buttons: buttons)
                    .frame(width: min(model.listWidth, max(model.contentWidth - Self.noteMinimum, Self.listWidths.lowerBound)))
                    .background(NotionStyle.sidebar)
                    .overlay(alignment: .trailing) {
                        NoteListResizer(width: Binding(get: { model.listWidth }, set: { model.listWidth = $0 }))
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            NoteDetail(store: store, buttons: buttons, note: openNote)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .background(NotionStyle.page)
                .clipped()
        }
        .foregroundStyle(NotionStyle.text)
        .background(NotionStyle.page)
        .overlay(alignment: .topLeading) {
            if model.sidebarHidden {
                NoteFloatingList(store: store, buttons: buttons)
            }
        }
        .overlay {
            if let url = model.viewingImage {
                TaskImageViewer(url: url) { model.viewingImage = nil }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.viewingImage)
        .animation(.easeOut(duration: 0.2), value: model.sidebarHidden)
        .clipShape(RoundedRectangle(cornerRadius: Self.windowRadius, style: .continuous))
        .ignoresSafeArea()
        .background { shortcuts }
        .onExitCommand {
            if model.viewingImage != nil { model.viewingImage = nil } else if model.isSearching { model.query = "" }
        }
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { model.pendingNoteDeletion != nil }, set: { if !$0 { model.pendingNoteDeletion = nil } }), presenting: model.pendingNoteDeletion) { note in
            Button("Delete", role: .destructive) {
                if model.openNoteID == note.id { model.openNoteID = nil }
                store.delete(note)
                model.pendingNoteDeletion = nil
            }
            Button("Cancel", role: .cancel) { model.pendingNoteDeletion = nil }
        } message: { note in
            Text("“\(note.title)” — its file goes too.")
        }
        .confirmationDialog("Delete this folder?", isPresented: Binding(get: { model.pendingFolderDeletion != nil }, set: { if !$0 { model.pendingFolderDeletion = nil } }), presenting: model.pendingFolderDeletion) { folder in
            Button("Delete", role: .destructive) {
                if let open = openNote, open.folder == folder || open.folder.hasPrefix(folder + "/") { model.openNoteID = nil }
                store.deleteFolder(folder)
                model.pendingFolderDeletion = nil
            }
            Button("Cancel", role: .cancel) { model.pendingFolderDeletion = nil }
        } message: { folder in
            let count = store.noteCount(in: folder)
            Text(count == 0 ? "“\((folder as NSString).lastPathComponent)” is empty."
                            : "“\((folder as NSString).lastPathComponent)” and the \(count) note\(count == 1 ? "" : "s") in it.")
        }
    }

    private var openNote: Note? {
        model.openNoteID.flatMap { id in store.notes.first { $0.id == id } }
    }

    /// The window's keys: ⌘N a new note, ⇧⌘N a new folder, ⌘F search,
    /// ⌘⌫ delete the note being read, ⌃⌘S the list.
    private var shortcuts: some View {
        ZStack {
            Button("") { model.composeNote(in: openNote?.folder ?? "") }.keyboardShortcut("n")
            Button("") { model.composeFolder(in: openNote?.folder ?? "") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("") { model.searchFocus += 1 }.keyboardShortcut("f")
            Button("") { if let note = openNote { model.pendingNoteDeletion = note } }.keyboardShortcut(.delete, modifiers: .command)
            Button("") { model.toggleSidebar() }.keyboardShortcut("s", modifiers: [.control, .command])
        }
        .hidden()
    }
}

/// The list's right edge: a hairline that turns blue under the pointer and drags the
/// list wider or narrower, leaving the note at least some room.
private struct NoteListResizer: View {
    @Binding var width: CGFloat
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
                            let windowWidth = NSApp.keyWindow?.frame.width ?? 1060
                            let most = min(NoteDashboardView.listWidths.upperBound, windowWidth - NoteDashboardView.noteMinimum)
                            let origin = start ?? min(width, max(most, NoteDashboardView.listWidths.lowerBound))
                            start = origin
                            width = min(max(origin + value.translation.width, NoteDashboardView.listWidths.lowerBound), max(most, NoteDashboardView.listWidths.lowerBound))
                        }
                        .onEnded { _ in start = nil }
                )
        }
        .help("Drag to resize")
    }
}

/// The traffic lights and the button that folds the list away. Shown at the top of
/// the list, or of the note when the list is away (`NoteDetail`).
struct NoteWindowChrome: View {
    let buttons: WindowButtons
    @Environment(NoteDashboardModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            TrafficLights(onClose: buttons.close, onMinimize: buttons.minimize, onZoom: buttons.zoom)
            NotionIconButton(symbol: "sidebar.left", help: model.sidebarHidden ? "Show the notes (⌃⌘S)" : "Hide the notes (⌃⌘S)", size: 14) {
                model.toggleSidebar()
            }
            .onHover { over in
                if over, model.sidebarHidden { model.sidebarFloating = true }
            }
        }
    }
}

/// The folded list, brought out over the note while the pointer wants it.
private struct NoteFloatingList: View {
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
                NoteList(store: store, buttons: buttons, floating: true)
                    .frame(width: NoteDashboardView.listWidth)
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
            guard !Task.isCancelled, model.composing == nil, model.renaming == nil else { return }
            model.sidebarFloating = false
        }
    }
}

// MARK: - The list

/// Every note down the left, inside its folders: a folder is a twisty with its
/// sub-folders and notes under it, and clicking a note opens it on the right.
/// Searching flattens the lot to what matches.
private struct NoteList: View {
    let store: NoteStore
    let buttons: WindowButtons
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
                    NotionIconButton(symbol: "folder.badge.plus", help: "New folder (⇧⌘N)", size: 14) { model.composeFolder() }
                    NotionIconButton(symbol: "square.and.pencil", help: "New note (⌘N)", size: 14) { model.composeNote() }
                }
                .padding(.horizontal, 8)
                .frame(height: NoteDashboardView.topBarHeight)
            }

            searchField
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if model.isSearching {
                        results
                    } else {
                        ForEach(rows) { row in
                            switch row.kind {
                            case .folder(let folder):
                                NoteFolderRow(store: store, folder: folder, depth: row.depth)
                            case .note(let note):
                                NoteRow(store: store, note: note, depth: row.depth, selected: model.openNoteID == note.id)
                            case .composing(let composing):
                                NewThingLine(store: store, composing: composing, depth: row.depth)
                            }
                        }
                        if store.notes.isEmpty && store.folders.isEmpty && model.composing == nil {
                            hint("No notes yet. ⌘N starts one.")
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .thinScrollers()
            // A drop on the empty space below moves a note to the top folder.
            .dropDestination(for: String.self) { ids, _ in moveNotes(ids, to: "") }
        }
        .onChange(of: model.searchFocus) { _, _ in
            model.revealSidebar()
            searching = true
        }
    }

    /// The list, flattened: every unfolded folder and the notes under it, in order,
    /// each with how deep it sits. Worked out here rather than by a view calling
    /// itself — a SwiftUI view cannot be recursive without losing its type.
    private var rows: [NoteListRow] {
        var rows: [NoteListRow] = []
        func walk(_ folder: String, depth: Int) {
            for child in store.subfolders(of: folder) {
                rows.append(NoteListRow(id: "folder:" + child, depth: depth, kind: .folder(child)))
                if model.isExpanded(child) { walk(child, depth: depth + 1) }
            }
            for note in store.notes(in: folder) {
                rows.append(NoteListRow(id: "note:" + note.id, depth: depth, kind: .note(note)))
            }
            if let composing = model.composing, composing.parent == folder {
                rows.append(NoteListRow(id: "new", depth: depth, kind: .composing(composing)))
            }
        }
        walk("", depth: 0)
        return rows
    }

    /// What a search finds, flat: a note's folder is said beside it instead.
    @ViewBuilder
    private var results: some View {
        let found = store.notes.filter { NoteDashboardQuery.matches($0, query: model.query) }
        if found.isEmpty {
            hint("No note matches “\(model.query)”.")
        } else {
            ForEach(found) { note in
                NoteRow(store: store, note: note, depth: 0, selected: model.openNoteID == note.id, showsFolder: true)
            }
        }
    }

    private func hint(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(NotionStyle.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
    }

    private func moveNotes(_ ids: [String], to folder: String) -> Bool {
        let moved = ids.compactMap { id in store.notes.first { $0.id == id } }.filter { $0.folder != folder }
        for note in moved {
            let after = store.move(note, to: folder)
            if model.openNoteID == note.id { model.openNoteID = after?.id }
        }
        return !moved.isEmpty
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

/// One line of the list: a folder, a note, or the line being typed.
private struct NoteListRow: Identifiable {
    enum Kind {
        case folder(String)
        case note(Note)
        case composing(NoteDashboardModel.Composing)
    }

    let id: String
    let depth: Int
    let kind: Kind
}

/// A folder in the list: a twisty, its name, and how many notes are under it. Notes
/// dragged onto it move into it; the … menu adds, renames and removes.
private struct NoteFolderRow: View {
    let store: NoteStore
    let folder: String
    let depth: Int
    @Environment(NoteDashboardModel.self) private var model
    @State private var hovering = false
    @State private var targeted = false
    @FocusState private var renaming: Bool
    @State private var draft = ""

    var body: some View {
        let open = model.isExpanded(folder)
        let name = (folder as NSString).lastPathComponent
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.toggle(folder) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NotionStyle.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(store.isEmpty(folder) ? 0.25 : 1)
            Image(systemName: open ? "folder.fill" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(NotionStyle.secondary)
                .frame(width: 16)
            if model.renaming == folder {
                TextField("Folder name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($renaming)
                    .onSubmit(commitRename)
                    .onExitCommand { model.renaming = nil }
                    .onAppear { draft = name; renaming = true }
                    .onChange(of: renaming) { _, focused in if !focused { commitRename() } }
            } else {
                Text(name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if hovering {
                    Menu {
                        folderMenu
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(NotionStyle.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 18)
                } else {
                    let count = store.noteCount(in: folder)
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(NotionStyle.tertiary)
                    }
                }
            }
        }
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 30)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(targeted ? NotionStyle.accent.opacity(0.14) : hovering ? NotionStyle.hover : Color.clear)
        )
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(NotionStyle.accent.opacity(0.6))
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.toggle(folder) } }
        .dropDestination(for: String.self) { ids, _ in
            let moved = ids.compactMap { id in store.notes.first { $0.id == id } }.filter { $0.folder != folder }
            model.expanded.insert(folder)
            for note in moved {
                let after = store.move(note, to: folder)
                if model.openNoteID == note.id { model.openNoteID = after?.id }
            }
            return !moved.isEmpty
        } isTargeted: { targeted = $0 }
        .contextMenu { folderMenu }
        .accessibilityLabel("\(name) folder, \(store.noteCount(in: folder)) notes")
    }

    @ViewBuilder
    private var folderMenu: some View {
        Button("New Note Here") { model.composeNote(in: folder) }
        Button("New Sub-folder") { model.composeFolder(in: folder) }
        Divider()
        Button("Rename") {
            draft = (folder as NSString).lastPathComponent
            model.renaming = folder
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([store.folderURL.appendingPathComponent(folder, isDirectory: true)])
        }
        Divider()
        Button("Delete Folder", role: .destructive) { model.pendingFolderDeletion = folder }
    }

    private func commitRename() {
        guard model.renaming == folder else { return }
        let wanted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.renaming = nil
        guard !wanted.isEmpty, wanted != (folder as NSString).lastPathComponent else { return }
        let open = model.openNoteID
        guard let path = store.renameFolder(folder, to: wanted) else { return }
        // The folder's notes moved with it, so their paths — and the open one's —
        // changed under us.
        if let open, open.hasPrefix(folder + "/") {
            model.openNoteID = path + String(open.dropFirst(folder.count))
        }
        model.expanded = Set(model.expanded.map { $0 == folder ? path : ($0.hasPrefix(folder + "/") ? path + String($0.dropFirst(folder.count)) : $0) })
    }
}

/// A note in the list: its title, and under it the first line of what it says. The
/// one being read is filled in. Dragging it carries its path, so a folder can take it.
private struct NoteRow: View {
    let store: NoteStore
    let note: Note
    let depth: Int
    let selected: Bool
    var showsFolder = false
    @Environment(NoteDashboardModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: NoteDashboardQuery.carriesFiles(note) ? "doc.richtext" : "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(selected ? NotionStyle.text : NotionStyle.tertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(NotionStyle.tertiary)
                    if showsFolder, !note.folder.isEmpty {
                        Text(note.folder)
                            .font(.system(size: 11))
                            .foregroundStyle(NotionStyle.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    } else if !note.summary.isEmpty {
                        Text(note.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(NotionStyle.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6 + CGFloat(depth) * 14 + 20)
        .padding(.trailing, 8)
        .frame(height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? NotionStyle.selectedRow : hovering ? NotionStyle.hover : Color.clear)
        )
        .onHover { hovering = $0 }
        .onTapGesture { model.openNoteID = note.id }
        .draggable(note.id) {
            Text(note.title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(NotionStyle.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .contextMenu { NoteRowMenu(store: store, note: note) }
        .accessibilityLabel(note.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// What can be done to a note, in the … menu and on a right-click.
struct NoteRowMenu: View {
    let store: NoteStore
    let note: Note
    @Environment(NoteDashboardModel.self) private var model

    var body: some View {
        Button("Open") { model.openNoteID = note.id }
        Divider()
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note.text, forType: .string)
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(for: note)])
        }
        if !note.folder.isEmpty {
            Button("Move to Top") {
                let after = store.move(note, to: "")
                if model.openNoteID == note.id { model.openNoteID = after?.id }
            }
        }
        Divider()
        Button("Delete Note", role: .destructive) { model.pendingNoteDeletion = note }
    }
}

/// The line being typed in the list: a new note's title, or a new folder's name.
/// ↩ makes it, ⎋ puts the line away.
private struct NewThingLine: View {
    let store: NoteStore
    let composing: NoteDashboardModel.Composing
    let depth: Int
    @Environment(NoteDashboardModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: composing.kind == .folder ? "folder.badge.plus" : "square.and.pencil")
                .font(.system(size: 12))
                .foregroundStyle(NotionStyle.tertiary)
                .frame(width: 16)
            TextField(composing.kind == .folder ? "Folder name" : "Note title", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit(commit)
        }
        .padding(.leading, 6 + CGFloat(depth) * 14 + 20)
        .padding(.trailing, 8)
        .frame(height: 32)
        .onAppear { focused = true }
        .onChange(of: model.composeTick) { _, _ in focused = true }
        .onExitCommand { dismiss() }
        .onChange(of: focused) { _, focused in
            if !focused, text.trimmingCharacters(in: .whitespaces).isEmpty { dismiss() }
        }
    }

    private func commit() {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return dismiss() }
        text = ""
        switch composing.kind {
        case .note:
            guard let note = store.add(text: wanted, in: composing.parent) else { return }
            model.composing = nil
            model.openNoteID = note.id
        case .folder:
            guard let path = store.createFolder(named: wanted, in: composing.parent) else { return }
            model.composing = nil
            model.expanded.insert(path)
        }
    }

    private func dismiss() {
        text = ""
        model.composing = nil
    }
}
