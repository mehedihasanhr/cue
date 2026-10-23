import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - State

/// Which list is showing, how, what is searched for and which task is open —
/// shared with the window controller so a task can be opened from outside.
@Observable
@MainActor
final class TaskDashboardModel {
    enum Layout: String { case list, board }

    /// A name asked for in a sheet: a new project (in a parent, or at the top) or a new name.
    enum ProjectPrompt: Identifiable {
        case new(parent: UUID?)
        case rename(TaskProject)

        var id: String {
            switch self {
            case .new(let parent): "new-\(parent?.uuidString ?? "top")"
            case .rename(let project): "rename-\(project.id.uuidString)"
            }
        }
    }

    private static let selectionKey = "tasks.dashboard.selection"
    private static let layoutKey = "tasks.dashboard.layout"
    private static let sidebarKey = "tasks.dashboard.sidebarCollapsed"
    private static let iconsKey = "tasks.dashboard.icons"
    private static let peekWidthKey = "tasks.dashboard.peekWidth"
    private static let orderKey = "tasks.dashboard.order"

    /// The side peek's width, dragged to by its left edge.
    var peekWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(peekWidth), forKey: Self.peekWidthKey) }
    }

    /// Icons picked for lists and projects, by `TaskDashboardSelection.rawValue`.
    private var icons: [String: String] {
        didSet { UserDefaults.standard.set(icons, forKey: Self.iconsKey) }
    }

    var selection: TaskDashboardSelection {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: Self.selectionKey) }
    }
    var layout: Layout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey) }
    }
    /// The sidebar folded away (⌃⌘S), for more room for the tasks.
    var sidebarCollapsed: Bool {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: Self.sidebarKey) }
    }
    var query = ""
    /// The task in the side peek — or on its own page.
    var openTaskID: UUID? {
        didSet { if openTaskID == nil { taskAsPage = false } }
    }
    /// The open task fills the main column, in place of the table, instead of
    /// peeking in beside it.
    var taskAsPage = false
    /// Status groups folded away in the table; Complete starts folded.
    var collapsed: Set<TaskStatus> = [.complete]
    /// The group (or board column) showing a line to type a new task in.
    var composing: TaskStatus?
    /// Bumped to put the caret in that line, even when it is already showing.
    var composeTick = 0
    /// Asked of the user before it happens.
    var pendingDeletion: TaskDeletion?
    var projectPrompt: ProjectPrompt?
    /// Bumped to put the caret in the search field (⌘F).
    var searchFocus = 0
    /// An image from a task's description, shown over the whole window.
    var viewingImage: URL?
    /// The order tasks were dragged into (a task never placed sorts by priority, on top).
    var manualOrder: [UUID] {
        didSet { UserDefaults.standard.set(manualOrder.map(\.uuidString), forKey: Self.orderKey) }
    }
    /// A task being dragged by its row or card, and where it would land.
    var draggingTaskID: UUID?
    var taskDrop: TaskDrop?

    struct TaskDrop: Equatable {
        var id: UUID
        var below: Bool
    }

    /// A task dropped above or below another: it takes that place, and that task's
    /// group (its status) when it came from another.
    func place(_ dragged: TaskItem, onto target: TaskItem, below: Bool, store: TaskStore) {
        if dragged.status != target.status { store.setStatus(target.status, for: dragged) }
        manualOrder = TaskDashboardQuery.reordered(store.tasks, order: manualOrder, moving: dragged.id, to: target.id, below: below)
    }

    init() {
        let defaults = UserDefaults.standard
        selection = defaults.string(forKey: Self.selectionKey).flatMap(TaskDashboardSelection.init(rawValue:)) ?? .list(.all)
        layout = defaults.string(forKey: Self.layoutKey).flatMap(Layout.init(rawValue:)) ?? .list
        sidebarCollapsed = defaults.bool(forKey: Self.sidebarKey)
        icons = defaults.dictionary(forKey: Self.iconsKey) as? [String: String] ?? [:]
        manualOrder = (defaults.stringArray(forKey: Self.orderKey) ?? []).compactMap(UUID.init(uuidString:))
        let stored = defaults.double(forKey: Self.peekWidthKey)
        peekWidth = stored > 0 ? min(max(CGFloat(stored), TaskDashboardView.peekWidths.lowerBound), TaskDashboardView.peekWidths.upperBound) : TaskDashboardView.peekWidth
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A list's or project's icon: the one picked for it, else its own.
    func icon(for selection: TaskDashboardSelection, hasSubprojects: Bool = false) -> PageIcon {
        if let picked = icons[selection.rawValue].flatMap(PageIcon.init(rawValue:)) { return picked }
        switch selection {
        case .list(let list): return .symbol(list.symbol)
        case .project: return .symbol(hasSubprojects ? "folder" : "doc.text")
        }
    }

    /// Picks an icon for a list or project; nil puts its own back.
    func setIcon(_ icon: PageIcon?, for selection: TaskDashboardSelection) {
        icons[selection.rawValue] = icon?.rawValue
    }

    /// The icon over the page now showing (a search has the magnifying glass).
    func currentIcon(in store: TaskStore) -> PageIcon {
        if isSearching { return .symbol("magnifyingglass") }
        if case .project(let id) = selection { return icon(for: selection, hasSubprojects: !store.subprojects(of: id).isEmpty) }
        return icon(for: selection)
    }

    /// What the main column is showing, for its title and the breadcrumb.
    func title(in store: TaskStore) -> String {
        if isSearching { return "Search" }
        switch selection {
        case .list(let list): return list.title
        case .project(let id): return store.project(id)?.name ?? "Project"
        }
    }

    /// Closes the side peek; a task open as a page stays.
    func closePeek() {
        guard openTaskID != nil, !taskAsPage else { return }
        openTaskID = nil
    }

    func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.2)) { sidebarCollapsed.toggle() }
    }

    /// Opens the new-task line in `status`'s group, unfolding it.
    func compose(in status: TaskStatus) {
        taskAsPage = false
        collapsed.remove(status)
        composing = status
        composeTick += 1
    }

    /// ⌘N and the New button: a pending task — or, on Completed, a completed one.
    func composeNew() {
        compose(in: selection == .list(.completed) ? .complete : .pending)
    }
}

// MARK: - Window

/// The task dashboard: every task in a window of its own, laid out the way Notion
/// lays out a database — a quiet sidebar of lists and projects, the tasks as a table
/// grouped by status or as a board, and the open task in a side peek or as a page of
/// its own. It remembers its size, the list, the layout and the sidebar.
final class TaskDashboardWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let model = TaskDashboardModel()

    init(store: TaskStore) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1240, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let buttons = WindowButtons(close: { [weak window] in window?.performClose(nil) },
                                    minimize: { [weak window] in window?.miniaturize(nil) },
                                    zoom: { [weak window] in window?.zoom(nil) })
        let root = TaskDashboardView(store: store, buttons: buttons)
            .environment(model)
            .frame(minWidth: 900, minHeight: 560)
        window.contentViewController = NSHostingController(rootView: root)
        window.title = "Cue Tasks"
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
        window.setContentSize(CGSize(width: 1240, height: 780))
        window.center()
        window.setFrameAutosaveName("CueTaskDashboard")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Opens in front of every other app's windows and takes focus, however Cue was
    /// asked; with a task, that task is open in the side peek.
    func present(task: TaskItem? = nil) {
        if let task {
            model.query = ""
            model.selection = .list(task.status == .complete ? .completed : .all)
            model.openTaskID = task.id
        }
        let wasOpen = window?.isVisible ?? false
        showWindow(nil)
        guard let window else { return }
        NSApp.present(window)
        // Only a window opening afresh starts with nothing focused; one already open
        // keeps the caret where it was left.
        if !wasOpen { window.makeFirstResponder(nil) }
    }

    /// Clicked back into, the window comes up over every other app's, with Cue
    /// active — a menu-bar app is not always activated by a click on its window, and
    /// would otherwise take the keyboard while staying behind the app in front.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window, !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    #if DEBUG
    /// The open task as a page or in the peek (for `cue://debug/open`).
    func showAsPage(_ page: Bool) {
        model.taskAsPage = page
    }
    #endif
}

// MARK: - Root

struct TaskDashboardView: View {
    let store: TaskStore
    let buttons: WindowButtons
    @Environment(TaskDashboardModel.self) private var model

    static let sidebarWidth: CGFloat = 240
    static let peekWidth: CGFloat = 460
    static let peekWidths: ClosedRange<CGFloat> = 380...1100
    static let topBarHeight: CGFloat = 44
    /// Rounder than Notion's own window, to sit with Cue's other windows.
    static let windowRadius: CGFloat = 14

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            if !model.sidebarCollapsed {
                TaskDashboardSidebar(store: store, buttons: buttons)
                    .frame(width: Self.sidebarWidth)
                    .background(NotionStyle.sidebar)
                    .overlay(alignment: .trailing) { Hairline(axis: .vertical) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                TaskTopBar(store: store, buttons: buttons, task: openTask)
                Group {
                    if model.taskAsPage, let task = openTask {
                        TaskPageView(store: store, task: task, style: .page)
                            .id(task.id)
                            .transition(.opacity)
                    } else {
                        TaskDashboardMain(store: store)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !model.taskAsPage, let task = openTask {
                TaskPageView(store: store, task: task, style: .peek)
                    .id(task.id)
                    .frame(width: model.peekWidth)
                    .background(NotionStyle.page)
                    .overlay(alignment: .leading) {
                        PeekResizer(width: Binding(get: { model.peekWidth }, set: { model.peekWidth = $0 }))
                    }
                    .transition(.move(edge: .trailing))
            }
        }
        .foregroundStyle(NotionStyle.text)
        .background(NotionStyle.page)
        .overlay {
            if let url = model.viewingImage {
                TaskImageViewer(url: url) { model.viewingImage = nil }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.viewingImage)
        // Opening and closing the peek slide; switching tasks inside it does not.
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: openTask == nil)
        .animation(.easeOut(duration: 0.2), value: model.sidebarCollapsed)
        .animation(.easeOut(duration: 0.2), value: model.taskAsPage)
        .clipShape(RoundedRectangle(cornerRadius: Self.windowRadius, style: .continuous))
        .ignoresSafeArea()
        .background { shortcuts }
        // ⎋ leaves the task, from the peek or the page alike.
        .onExitCommand {
            if model.viewingImage != nil { model.viewingImage = nil } else { model.openTaskID = nil }
        }
        .onChange(of: store.projects) { _, projects in
            // A project deleted (here or by a sync) leaves nothing to show.
            if case .project(let id) = model.selection, !projects.contains(where: { $0.id == id }) { model.selection = .list(.all) }
        }
        .confirmationDialog(deletionTitle, isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }), presenting: model.pendingDeletion) { deletion in
            Button("Delete", role: .destructive) {
                if case .task(let task) = deletion, model.openTaskID == task.id { model.openTaskID = nil }
                store.delete(deletion)
                model.pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
        } message: { deletion in
            switch deletion {
            case .task(let task): Text(task.title)
            case .project(let project): Text(store.deletionSummary(for: project))
            }
        }
        .sheet(item: $model.projectPrompt) { prompt in
            ProjectNameSheet(prompt: prompt, store: store) { created in
                if let created { model.selection = .project(created.id) }
                model.projectPrompt = nil
            }
        }
    }

    private var openTask: TaskItem? {
        model.openTaskID.flatMap { id in store.tasks.first { $0.id == id } }
    }

    private var deletionTitle: String {
        switch model.pendingDeletion {
        case .task: "Delete this task?"
        case .project: "Delete this project?"
        case nil: ""
        }
    }

    /// The window's keys: ⌘N a new task, ⌘F search, ⌘1 / ⌘2 table or board,
    /// ⌘⌫ delete the open task, ⌃⌘S the sidebar.
    private var shortcuts: some View {
        ZStack {
            Button("") { model.composeNew() }.keyboardShortcut("n")
            Button("") { model.searchFocus += 1 }.keyboardShortcut("f")
            Button("") { model.layout = .list }.keyboardShortcut("1")
            Button("") { model.layout = .board }.keyboardShortcut("2")
            Button("") { if let task = openTask { model.pendingDeletion = .task(task) } }.keyboardShortcut(.delete, modifiers: .command)
            Button("") { model.toggleSidebar() }.keyboardShortcut("s", modifiers: [.control, .command])
        }
        .hidden()
    }
}

/// The side peek's left edge: a hairline that turns blue under the pointer and drags
/// the peek wider or narrower, leaving the table at least some room.
private struct PeekResizer: View {
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
                            let origin = start ?? width
                            start = origin
                            let windowWidth = NSApp.keyWindow?.frame.width ?? 1200
                            let most = min(TaskDashboardView.peekWidths.upperBound, windowWidth - 420)
                            width = min(max(origin - value.translation.width, TaskDashboardView.peekWidths.lowerBound), max(most, TaskDashboardView.peekWidths.lowerBound))
                        }
                        .onEnded { _ in start = nil }
                )
        }
        .help("Drag to resize")
    }
}

/// The traffic lights and the button that folds the sidebar: at the top of the
/// sidebar, or of the window when the sidebar is away.
private struct WindowChrome: View {
    let buttons: WindowButtons
    @Environment(TaskDashboardModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            TrafficLights(onClose: buttons.close, onMinimize: buttons.minimize, onZoom: buttons.zoom)
            NotionIconButton(symbol: "sidebar.left", help: model.sidebarCollapsed ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)", size: 14) {
                model.toggleSidebar()
            }
        }
    }
}

// MARK: - Top bar

/// The thin bar over the content: where you are as a breadcrumb (Tasks › list ›
/// task), and on a task's page when it was last edited and what can be done to it.
private struct TaskTopBar: View {
    let store: TaskStore
    let buttons: WindowButtons
    let task: TaskItem?
    @Environment(TaskDashboardModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            if model.sidebarCollapsed {
                WindowChrome(buttons: buttons)
            }
            NotionIconButton(symbol: "chevron.left", help: model.taskAsPage ? "Back to \(model.title(in: store)) (⎋)" : "Back", size: 13,
                             tint: model.taskAsPage ? NotionStyle.secondary : NotionStyle.tertiary.opacity(0.6)) { leavePage() }
                .disabled(!model.taskAsPage)
                .keyboardShortcut("[", modifiers: .command)
                .padding(.trailing, 4)
            crumb("Tasks", icon: .symbol("checklist")) { leavePage() }
            separator
            crumb(model.title(in: store), icon: model.currentIcon(in: store)) { leavePage() }
            if model.taskAsPage, let task {
                separator
                crumb(task.title, icon: .symbol(task.status.symbol)) {}
            }
            Spacer(minLength: 12)
            if model.taskAsPage, let task {
                Text("Edited \(task.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 13))
                    .foregroundStyle(NotionStyle.tertiary)
                    .padding(.trailing, 6)
                NotionIconButton(symbol: "sidebar.right", help: "Open in side peek") { model.taskAsPage = false }
                TaskMoreMenu(store: store, task: task)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: TaskDashboardView.topBarHeight)
    }

    private func leavePage() {
        if model.taskAsPage { model.openTaskID = nil }
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

/// The … menu on a task: copy its text, delete it.
struct TaskMoreMenu: View {
    let store: TaskStore
    let task: TaskItem
    @Environment(TaskDashboardModel.self) private var model

    var body: some View {
        Menu {
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.text, forType: .string)
            }
            Divider()
            Button("Delete…", role: .destructive) { model.pendingDeletion = .task(task) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14))
                .foregroundStyle(NotionStyle.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

/// A light square under the pointer, as Notion's text buttons have.
struct NotionHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(configuration.isPressed ? NotionStyle.selectedRow : hovering ? NotionStyle.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Sidebar

private struct TaskDashboardSidebar: View {
    let store: TaskStore
    let buttons: WindowButtons
    @Environment(TaskDashboardModel.self) private var model
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                WindowChrome(buttons: buttons)
                Spacer(minLength: 0)
                NotionIconButton(symbol: "square.and.pencil", help: "New task (⌘N)", size: 14) { model.composeNew() }
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(height: TaskDashboardView.topBarHeight)

            searchField
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(TaskDashboardList.allCases) { list in
                        SidebarItem(title: list.title, icon: model.icon(for: .list(list)), depth: 0,
                                    count: TaskDashboardQuery.count(store.tasks, list: list),
                                    selected: !model.isSearching && model.selection == .list(list)) {
                            select(.list(list))
                        }
                        .dropDestination(for: String.self) { ids, _ in drop(ids, on: list) }
                    }
                    sectionHeader("Projects") { model.projectPrompt = .new(parent: nil) }
                    ForEach(tree, id: \.project.id) { entry in
                        projectRow(entry.project, depth: entry.depth)
                    }
                    if store.projects.isEmpty {
                        Button {
                            model.projectPrompt = .new(parent: nil)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus").font(.system(size: 13)).frame(width: 20)
                                Text("Add a project").font(.system(size: 14))
                                Spacer()
                            }
                            .foregroundStyle(NotionStyle.tertiary)
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(NotionHoverStyle())
                    }
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
            if model.sidebarCollapsed { model.toggleSidebar() }
            searching = true
        }
    }

    private var tree: [(project: TaskProject, depth: Int)] {
        func under(_ parent: UUID?, depth: Int) -> [(project: TaskProject, depth: Int)] {
            store.subprojects(of: parent).flatMap { [(project: $0, depth: depth)] + under($0.id, depth: depth + 1) }
        }
        return under(nil, depth: 0)
    }

    private func select(_ selection: TaskDashboardSelection) {
        model.query = ""
        searching = false
        model.composing = nil
        model.openTaskID = nil
        model.selection = selection
    }

    private func sectionHeader(_ title: String, add: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NotionStyle.tertiary)
            Spacer()
            NotionIconButton(symbol: "plus", help: "New project", size: 12, tint: NotionStyle.tertiary, action: add)
        }
        .padding(.leading, 8)
        .padding(.top, 18)
        .padding(.bottom, 2)
    }

    private func projectRow(_ project: TaskProject, depth: Int) -> some View {
        let open = store.tasks(in: project.id).filter { $0.status != .complete }.count
        return SidebarItem(title: project.name, icon: model.icon(for: .project(project.id), hasSubprojects: !store.subprojects(of: project.id).isEmpty), depth: depth, count: open,
                           selected: !model.isSearching && model.selection == .project(project.id)) {
            select(.project(project.id))
        }
        .dropDestination(for: String.self) { ids, _ in
            let moved = tasks(for: ids)
            moved.forEach { store.move($0, to: project.id) }
            return !moved.isEmpty
        }
        .contextMenu {
            Button("New Sub-project…") { model.projectPrompt = .new(parent: project.id) }
            Button("Rename…") { model.projectPrompt = .rename(project) }
            Divider()
            Button("Delete Project…", role: .destructive) { model.pendingDeletion = .project(project) }
        }
    }

    /// Tasks dropped on a fixed list take what it means where that is one thing:
    /// No project, Urgent, Completed.
    private func drop(_ ids: [String], on list: TaskDashboardList) -> Bool {
        let dropped = tasks(for: ids)
        switch list {
        case .unassigned: dropped.forEach { store.move($0, to: nil) }
        case .urgent: dropped.forEach { store.setPriority(.urgent, for: $0) }
        case .completed: dropped.forEach { store.setStatus(.complete, for: $0) }
        case .all, .today: return false
        }
        return !dropped.isEmpty
    }

    private func tasks(for ids: [String]) -> [TaskItem] {
        let wanted = Set(ids.compactMap(UUID.init(uuidString:)))
        return store.tasks.filter { wanted.contains($0.id) }
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
        .help("Search every task (⌘F)")
    }
}

/// A list or project in the sidebar: a grey glyph, its name and how many are open;
/// a light fill when chosen or under the pointer, an outline while a task is
/// dragged over it.
private struct SidebarItem: View {
    let title: String
    let icon: PageIcon
    let depth: Int
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
            .padding(.leading, 8 + CGFloat(depth) * 14)
            .padding(.trailing, 8)
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
        .accessibilityValue(count > 0 ? "\(count) open" : "")
    }
}

// MARK: - Main column

/// The database page: an icon and a big title, the views as tabs with a New button,
/// then the table or the board.
private struct TaskDashboardMain: View {
    let store: TaskStore
    @Environment(TaskDashboardModel.self) private var model

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
                Text("No task matches “\(model.query)”.")
                    .font(.system(size: 14))
                    .foregroundStyle(NotionStyle.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.layout == .list {
                TaskTable(store: store, tasks: shown, groups: groups)
            } else {
                TaskBoard(store: store, tasks: shown)
            }
        }
        // A click on the page outside the side peek closes it. Rows, cards, buttons
        // and menus take their own clicks first, so a click on another task opens
        // that one instead.
        .contentShape(Rectangle())
        .onTapGesture { model.closePeek() }
    }

    /// What the page lists: every match for a search, else the chosen list or project.
    private var shown: [TaskItem] {
        if model.isSearching { return store.tasks.filter { TaskDashboardQuery.matches($0, query: model.query) } }
        switch model.selection {
        case .list(let list): return TaskDashboardQuery.filter(store.tasks, list: list)
        case .project(let id): return store.tasks(in: id)
        }
    }

    /// The table's groups: those with tasks, plus the one new tasks go into (so there
    /// is always somewhere to add one) and the one being typed into.
    private var groups: [TaskStatus] {
        let home: TaskStatus = model.selection == .list(.completed) ? .complete : .pending
        return TaskDashboardQuery.statusOrder.filter { status in
            shown.contains { $0.status == status } || (!model.isSearching && (status == home || status == model.composing))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            PageIconButton(store: store)
            Text(model.title(in: store))
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
        }
    }

    /// Notion's view tabs: the chosen one underlined, then New on the right.
    private var tabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tab(.list, title: "Table", symbol: "tablecells")
                tab(.board, title: "Board", symbol: "rectangle.split.3x1")
                Spacer()
                if case .project(let id) = model.selection {
                    Button {
                        model.projectPrompt = .new(parent: id)
                    } label: {
                        Label("Sub-project", systemImage: "folder.badge.plus")
                            .font(.system(size: 13))
                            .foregroundStyle(NotionStyle.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                    }
                    .buttonStyle(NotionHoverStyle())
                    .help("New sub-project")
                }
                Button(action: model.composeNew) {
                    Text("New")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(NotionStyle.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("New task (⌘N)")
            }
            .padding(.bottom, 6)
            Hairline()
        }
    }

    private func tab(_ layout: TaskDashboardModel.Layout, title: String, symbol: String) -> some View {
        let active = model.layout == layout
        return Button {
            model.layout = layout
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(title).font(.system(size: 14, weight: active ? .medium : .regular))
            }
            // Never cut to "T…" when the side peek leaves the page narrow.
            .fixedSize()
            .foregroundStyle(active ? NotionStyle.text : NotionStyle.secondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotionHoverStyle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(active ? NotionStyle.text : .clear).frame(height: 2).offset(y: 7)
        }
        .help(layout == .list ? "Table (⌘1)" : "Board (⌘2)")
    }
}

/// The page's icon beside its title: a click opens the picker, as in Notion.
private struct PageIconButton: View {
    let store: TaskStore
    @Environment(TaskDashboardModel.self) private var model
    @State private var picking = false
    @State private var hovering = false

    var body: some View {
        let icon = model.currentIcon(in: store)
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
        // The glyph's box is larger than the glyph; pulled back so it lines up with the text below.
        .padding(.leading, -8)
    }
}

// MARK: - Table

/// The table's columns: a gutter for the drag handle, the name taking what is left,
/// and fixed widths for the properties.
private enum TableColumns {
    static let gutter: CGFloat = 28
    static let name: CGFloat = 280
    static let status: CGFloat = 150
    static let priority: CGFloat = 120
    static let project: CGFloat = 170
    static let updated: CGFloat = 150
    static var minimumWidth: CGFloat { gutter + name + status + priority + project + updated + 4 }
}

/// Every task in groups by status, each a ▸ toggle with its tag and count, the column
/// headings, the rows, and a "+ New task" line — Notion's grouped table.
private struct TaskTable: View {
    let store: TaskStore
    let tasks: [TaskItem]
    let groups: [TaskStatus]
    @Environment(TaskDashboardModel.self) private var model
    @Namespace private var motion

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.self) { status in
                            TableGroup(store: store, status: status, tasks: TaskDashboardQuery.sorted(tasks.filter { $0.status == status }, order: model.manualOrder))
                        }
                    }
                    .frame(width: max(proxy.size.width - (TaskDashboardMain.margin - TableColumns.gutter) * 2, TableColumns.minimumWidth), alignment: .leading)
                    .padding(.horizontal, TaskDashboardMain.margin - TableColumns.gutter)
                    .padding(.bottom, 40)
                }
            }
            .thinScrollers()
            .environment(\.taskMotion, motion)
        }
    }
}

private struct TableGroup: View {
    let store: TaskStore
    let status: TaskStatus
    let tasks: [TaskItem]
    @Environment(TaskDashboardModel.self) private var model

    var body: some View {
        let folded = model.collapsed.contains(status)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if folded { model.collapsed.remove(status) } else { model.collapsed.insert(status) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(NotionStyle.secondary)
                        .rotationEffect(.degrees(folded ? 0 : 90))
                    NotionTag.status(status)
                    Text("\(tasks.count)")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(NotionStyle.tertiary)
                }
                .padding(.leading, TableColumns.gutter - 18)
                .padding(.trailing, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.bottom, 4)
            .accessibilityLabel("\(status.title), \(tasks.count) tasks, \(folded ? "folded" : "unfolded")")

            if !folded {
                columnHeadings
                ForEach(tasks) { task in
                    TableRow(store: store, task: task, open: model.openTaskID == task.id)
                }
                if model.composing == status {
                    NewTaskLine(store: store, status: status)
                        .padding(.leading, TableColumns.gutter)
                        .overlay(alignment: .bottom) { Hairline().padding(.leading, TableColumns.gutter) }
                } else {
                    Button {
                        model.compose(in: status)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 13))
                            Text("New task").font(.system(size: 14))
                            Spacer()
                        }
                        .foregroundStyle(NotionStyle.tertiary)
                        .padding(.horizontal, 8)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NotionHoverStyle())
                    .padding(.leading, TableColumns.gutter)
                }
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            let wanted = Set(ids.compactMap(UUID.init(uuidString:)))
            let moved = store.tasks.filter { wanted.contains($0.id) && $0.status != status }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { moved.forEach { store.setStatus(status, for: $0) } }
            return !moved.isEmpty
        }
    }

    private var columnHeadings: some View {
        HStack(spacing: 0) {
            heading("Task name", symbol: "textformat", width: nil)
            Hairline(axis: .vertical)
            heading("Status", symbol: "circle.dotted", width: TableColumns.status)
            Hairline(axis: .vertical)
            heading("Priority", symbol: "flag", width: TableColumns.priority)
            Hairline(axis: .vertical)
            heading("Project", symbol: "folder", width: TableColumns.project)
            Hairline(axis: .vertical)
            heading("Updated", symbol: "clock", width: TableColumns.updated)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
        .padding(.leading, TableColumns.gutter)
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
        .frame(minWidth: width == nil ? TableColumns.name : nil, maxWidth: width ?? .infinity)
        .frame(width: width)
    }
}

/// One task as a table row: its name (with OPEN on hover), then status, priority and
/// project as tags that change from a menu, and when it last changed. A drag handle
/// shows in the gutter under the pointer; a click opens the task beside the table.
private struct TableRow: View {
    let store: TaskStore
    let task: TaskItem
    let open: Bool
    @Environment(TaskDashboardModel.self) private var model
    @State private var hovering = false
    @State private var height: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            DragDots()
                .frame(width: TableColumns.gutter, height: 24)
                .opacity(hovering ? 1 : 0)
                .help("Drag to reorder, to another group, a board column or a project")
            HStack(spacing: 0) {
                nameCell
                Hairline(axis: .vertical)
                cell(width: TableColumns.status) {
                    TagMenu(tag: .status(task.status), help: "Status") { TaskStatusItems(store: store, task: task) }
                }
                Hairline(axis: .vertical)
                cell(width: TableColumns.priority) {
                    TagMenu(tag: .priority(task.priority), help: "Priority") { TaskPriorityItems(store: store, task: task) }
                }
                Hairline(axis: .vertical)
                cell(width: TableColumns.project) {
                    TagMenu(tag: store.project(task.projectID).map { .project($0.name) }, placeholder: hovering ? "Add a project" : "", help: "Project") {
                        TaskProjectItems(store: store, task: task)
                    }
                }
                Hairline(axis: .vertical)
                cell(width: TableColumns.updated) {
                    Text(task.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 13))
                        .foregroundStyle(NotionStyle.secondary)
                        .help(task.updatedAt.formatted(date: .complete, time: .shortened))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(open ? NotionStyle.openRow : hovering ? NotionStyle.hover : .clear)
            .overlay(alignment: .bottom) { Hairline() }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.openTaskID = task.id }
        .taskDragging(task, store: store, height: height)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { height = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, value in height = value }
            }
        }
        .contextMenu { TaskRowMenu(store: store, task: task) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.title)
        .accessibilityAddTraits(open ? [.isSelected, .isButton] : .isButton)
    }

    private var nameCell: some View {
        HStack(spacing: 6) {
            Text(task.title)
                .font(.system(size: 14, weight: .medium))
                .strikethrough(task.status == .complete, color: NotionStyle.tertiary)
                .foregroundStyle(task.status == .complete ? NotionStyle.secondary : NotionStyle.text)
                // One line, cut short with "…": a row is the same height whatever its title.
                .lineLimit(1)
                .truncationMode(.tail)
                .help(task.title)
            Spacer(minLength: 4)
            if hovering {
                Button {
                    model.openTaskID = task.id
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
        .frame(minWidth: TableColumns.name, maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private func cell(width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 8)
            .frame(width: width, alignment: .leading)
            .frame(minHeight: 36)
    }
}

/// A line to type a new task in, at the foot of a group or a column: `#project` and
/// `!priority` work as in the island; it lands in the chosen project with the
/// group's status. ↩ adds and keeps the line for the next one, ⎋ puts it away.
private struct NewTaskLine: View {
    let store: TaskStore
    let status: TaskStatus
    @Environment(TaskDashboardModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(NotionStyle.tertiary)
            TextField("Type a name — #project, !urgent", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit(add)
                .onExitCommand { model.composing = nil }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .onAppear { focused = true }
        .onChange(of: model.composeTick) { _, _ in focused = true }
        .onChange(of: focused) { _, isFocused in
            guard !isFocused else { return }
            // Clicked elsewhere in the window with nothing typed: the line goes, as
            // Notion's does. Switching to another app is not that — the window loses
            // its focus with it, and the line must be there, caret and all, on the
            // way back. Asked a moment later, once the app's state has caught up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard NSApp.isActive, NSApp.keyWindow?.title == "Cue Tasks", !focused,
                      text.trimmingCharacters(in: .whitespaces).isEmpty, model.composing == status else { return }
                model.composing = nil
            }
        }
    }

    private func add() {
        let parsed = TaskTokens.parse(text)
        guard !parsed.title.isEmpty else {
            model.composing = nil
            return
        }
        var projectID: UUID?
        if case .project(let id) = model.selection { projectID = id }
        if let name = parsed.project {
            let wanted = TaskTokens.compact(name)
            projectID = store.projects.first { TaskTokens.compact($0.name) == wanted }?.id ?? store.addProject(named: name)?.id
        }
        let priority = parsed.priority ?? (model.selection == .list(.urgent) ? .urgent : .medium)
        if let task = store.addTask(text: parsed.title, in: projectID, priority: priority) {
            if status != .pending { store.setStatus(status, for: task) }
            text = ""
        }
        focused = true
    }
}

/// A row's or card's right-click menu.
private struct TaskRowMenu: View {
    let store: TaskStore
    let task: TaskItem
    @Environment(TaskDashboardModel.self) private var model

    var body: some View {
        Button("Open in Side Peek") { model.openTaskID = task.id }
        Button("Open as Page") {
            model.openTaskID = task.id
            model.taskAsPage = true
        }
        Divider()
        Menu("Status") { TaskStatusItems(store: store, task: task) }
        Menu("Priority") { TaskPriorityItems(store: store, task: task) }
        Menu("Move to") { TaskProjectItems(store: store, task: task) }
        Divider()
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.text, forType: .string)
        }
        Divider()
        Button("Delete…", role: .destructive) { model.pendingDeletion = .task(task) }
    }
}

extension View {
    /// A task's row or card: dragged by itself (onto another task to take its place —
    /// and its group —, onto a board column, a group or a project), and a place another
    /// task can be dropped above or below, with a blue line where it would land.
    fileprivate func taskDragging(_ task: TaskItem, store: TaskStore, height: CGFloat, inset: CGFloat = TableColumns.gutter, look: TaskDragLook = .row) -> some View {
        modifier(TaskDragging(task: task, store: store, height: height, inset: inset, look: look))
    }
}

private struct TaskDragging: ViewModifier {
    let task: TaskItem
    let store: TaskStore
    let height: CGFloat
    let inset: CGFloat
    let look: TaskDragLook
    @Environment(TaskDashboardModel.self) private var model

    private var dragged: Bool { model.draggingTaskID == task.id }

    func body(content: Content) -> some View {
        content
            // Left behind while it is carried: a faded placeholder of itself.
            .opacity(dragged ? 0.35 : 1)
            .scaleEffect(dragged ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: dragged)
            .modifier(TaskMotion(id: task.id))
            .onDrag {
                model.draggingTaskID = task.id
                DragEnd.whenReleased { [model] in
                    model.draggingTaskID = nil
                    model.taskDrop = nil
                }
                return NSItemProvider(object: task.id.uuidString as NSString)
            } preview: {
                TaskDragPreview(store: store, task: task, look: look)
            }
            .onDrop(of: [.plainText], delegate: TaskDropDelegate(target: task, height: height, store: store, model: model))
            .overlay { TaskDropLine(id: task.id, inset: inset, look: look) }
    }
}

/// The blue line where a dragged task would land. Its own small view: it alone reads
/// where the drop is, so as the pointer moves only these lines redraw, not the rows.
private struct TaskDropLine: View {
    let id: UUID
    let inset: CGFloat
    let look: TaskDragLook
    @Environment(TaskDashboardModel.self) private var model

    var body: some View {
        let drop = model.taskDrop?.id == id ? model.taskDrop : nil
        let gap: CGFloat = look == .card ? 5 : 1.5
        ZStack {
            if let drop {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(NotionStyle.accent.opacity(0.7))
                    .frame(height: 3)
                    .padding(.leading, inset)
                    .frame(maxHeight: .infinity, alignment: drop.below ? .bottom : .top)
                    .offset(y: drop.below ? gap : -gap)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: drop)
        .allowsHitTesting(false)
    }
}

/// Where a dragged task would land: above or below the row (or card) under the pointer.
private struct TaskDropDelegate: DropDelegate {
    let target: TaskItem
    let height: CGFloat
    let store: TaskStore
    let model: TaskDashboardModel

    func validateDrop(info: DropInfo) -> Bool {
        model.draggingTaskID != nil && model.draggingTaskID != target.id
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard model.draggingTaskID != nil else { return nil }
        let drop = TaskDashboardModel.TaskDrop(id: target.id, below: info.location.y > height / 2)
        if model.taskDrop != drop { model.taskDrop = drop }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.taskDrop?.id == target.id { model.taskDrop = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            model.taskDrop = nil
            model.draggingTaskID = nil
        }
        guard let id = model.draggingTaskID, let drop = model.taskDrop, let dragged = store.tasks.first(where: { $0.id == id }) else { return false }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { model.place(dragged, onto: target, below: drop.below, store: store) }
        return true
    }
}

/// What a task card shows: its name, a line of its description, its priority and
/// project — on the board, and on the card that follows the pointer in a drag.
private struct TaskCardFace: View {
    let store: TaskStore
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title)
                .font(.system(size: 14, weight: .medium))
                .strikethrough(task.status == .complete, color: NotionStyle.tertiary)
                .foregroundStyle(task.status == .complete ? NotionStyle.secondary : NotionStyle.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if task.hasMore {
                Text(task.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(NotionStyle.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                NotionTag.priority(task.priority)
                if let project = store.project(task.projectID) { NotionTag.project(project.name) }
            }
        }
        .padding(10)
    }
}

/// The task as it follows the pointer: the whole card (or, from the table, the row),
/// lifted — a deeper shadow and a slight tilt — rather than a line of text.
private struct TaskDragPreview: View {
    let store: TaskStore
    let task: TaskItem
    let look: TaskDragLook

    var body: some View {
        Group {
            switch look {
            case .card:
                TaskCardFace(store: store, task: task)
                    .frame(width: 254, alignment: .leading)
            case .row:
                HStack(spacing: 10) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    NotionTag.status(task.status)
                    NotionTag.priority(task.priority)
                }
                .padding(.horizontal, 12)
                .frame(width: 420, height: 40)
            }
        }
        .foregroundStyle(NotionStyle.text)
        .background(NotionStyle.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(NotionStyle.divider))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
        .rotationEffect(.degrees(look == .card ? 2 : 0))
        // Room for the shadow and the tilt inside the drag image.
        .padding(18)
    }
}

enum TaskDragLook { case card, row }

#if DEBUG
/// The drag image a task gets, drawn to a picture (for `cue://debug/drag-preview`).
@MainActor
func debugDragPreview(store: TaskStore, task: TaskItem, look: TaskDragLook) -> NSImage? {
    let renderer = ImageRenderer(content: TaskDragPreview(store: store, task: task, look: look).background(NotionStyle.page))
    renderer.scale = 2
    return renderer.nsImage
}
#endif

/// The board's (or table's) shared space, so a task moved to another column or group
/// glides there rather than vanishing from one and appearing in the other.
private struct TaskMotionKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    fileprivate var taskMotion: Namespace.ID? {
        get { self[TaskMotionKey.self] }
        set { self[TaskMotionKey.self] = newValue }
    }
}

private struct TaskMotion: ViewModifier {
    let id: UUID
    @Environment(\.taskMotion) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// Runs `action` once the mouse button is up — however a drag ended: dropped on a
/// target, or let go anywhere else (when no drop is told to the app at all).
@MainActor
enum DragEnd {
    static func whenReleased(_ action: @escaping @MainActor () -> Void) {
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { timer in
            guard NSEvent.pressedMouseButtons == 0 else { return }
            timer.invalidate()
            // After the drop has been handled, which also happens on the release.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { action() } }
        }
    }
}

// MARK: - Board

/// A column per status, tinted with its colour, cards on it and "+ New" at the foot;
/// a card dropped on a column takes its status.
private struct TaskBoard: View {
    let store: TaskStore
    let tasks: [TaskItem]
    @Environment(TaskDashboardModel.self) private var model
    @Namespace private var motion

    private static let spacing: CGFloat = 12
    private static let minimumColumn: CGFloat = 220

    var body: some View {
        GeometryReader { proxy in
            // The columns share the page's width (never narrower than a card needs); a
            // window too narrow for all four scrolls sideways rather than cutting one off.
            let count = CGFloat(TaskDashboardQuery.statusOrder.count)
            let room = proxy.size.width - TaskDashboardMain.margin * 2 - Self.spacing * (count - 1)
            let width = max(room / count, Self.minimumColumn)
            board(columnWidth: width)
        }
    }

    private func board(columnWidth: CGFloat) -> some View {
        ScrollView(.vertical) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(TaskDashboardQuery.statusOrder, id: \.self) { status in
                        BoardColumn(store: store, status: status, tasks: TaskDashboardQuery.sorted(tasks.filter { $0.status == status }, order: model.manualOrder))
                            .frame(width: columnWidth)
                    }
                }
                .padding(.horizontal, TaskDashboardMain.margin)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .thinScrollers()
        .environment(\.taskMotion, motion)
    }
}

private struct BoardColumn: View {
    let store: TaskStore
    let status: TaskStatus
    let tasks: [TaskItem]
    @Environment(TaskDashboardModel.self) private var model
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                NotionTag.status(status)
                Text("\(tasks.count)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(NotionStyle.tertiary)
                Spacer()
                NotionIconButton(symbol: "plus", help: "New task in \(status.title)", size: 12, tint: NotionStyle.tertiary) { model.compose(in: status) }
            }
            .padding(.leading, 2)
            ForEach(tasks) { task in
                BoardCard(store: store, task: task, open: model.openTaskID == task.id)
            }
            if model.composing == status {
                NewTaskLine(store: store, status: status)
                    .background(NotionStyle.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(NotionStyle.divider))
            } else {
                Button {
                    model.compose(in: status)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 13))
                        Text("New").font(.system(size: 14))
                        Spacer()
                    }
                    .foregroundStyle(NotionStyle.tertiary)
                    .padding(.horizontal, 6)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NotionHoverStyle())
            }
        }
        .padding(8)
        .background(status.notionColor.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(targeted ? NotionStyle.accent.opacity(0.7) : .clear, lineWidth: 2))
        .animation(.easeOut(duration: 0.12), value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            let wanted = Set(ids.compactMap(UUID.init(uuidString:)))
            let moved = store.tasks.filter { wanted.contains($0.id) && $0.status != status }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { moved.forEach { store.setStatus(status, for: $0) } }
            return !moved.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

/// A task on the board: its name, then its priority and project as tags.
private struct BoardCard: View {
    let store: TaskStore
    let task: TaskItem
    let open: Bool
    @Environment(TaskDashboardModel.self) private var model
    @State private var hovering = false

    var body: some View {
        TaskCardFace(store: store, task: task)
            .help(task.title)
            .background(NotionStyle.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(open ? NotionStyle.accent.opacity(0.8) : NotionStyle.divider, lineWidth: open ? 1.5 : 1))
            // Under the pointer the card lifts a little, as if picked up.
            .shadow(color: .black.opacity(hovering ? 0.1 : 0.04), radius: hovering ? 6 : 2, y: hovering ? 3 : 1)
            .offset(y: hovering ? -1 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
            .onTapGesture { model.openTaskID = task.id }
            .taskDragging(task, store: store, height: 80, inset: 0, look: .card)
        .contextMenu { TaskRowMenu(store: store, task: task) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(open ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Project names

/// A project's name, asked for in a sheet: a new project (at the top or in a parent)
/// or a new name for one.
private struct ProjectNameSheet: View {
    let prompt: TaskDashboardModel.ProjectPrompt
    let store: TaskStore
    /// The project made (nil: cancelled or renamed).
    let finish: (TaskProject?) -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            if case .rename(let project) = prompt { name = project.name }
            focused = true
        }
    }

    private var title: String {
        switch prompt {
        case .new(let parent): parent.flatMap { store.project($0) }.map { "New project in \($0.name)" } ?? "New project"
        case .rename: "Rename project"
        }
    }

    private var confirmTitle: String {
        if case .rename = prompt { return "Rename" }
        return "Create"
    }

    private func confirm() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        switch prompt {
        case .new(let parent): finish(store.addProject(named: name, in: parent))
        case .rename(let project):
            store.renameProject(project, to: name)
            finish(nil)
        }
    }
}
