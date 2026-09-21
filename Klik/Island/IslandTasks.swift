import AppKit
import SwiftUI

/// The Tasks tab: every task to start with, grouped by status (in process first,
/// complete last) and filtered — completed tasks are hidden until asked for; a
/// project shows its own tasks the same way, with sub-projects as pills to drill
/// into, and "Projects" shows the projects themselves as cards or rows.
struct IslandTasksView: View {
    let store: TaskStore
    /// New projects are named in the island's compact box.
    var onPrompt: (IslandPrompt) -> Void = { _ in }
    /// Tasks open in the compact island.
    var onShowTask: (TaskItem) -> Void = { _ in }

    private enum Selection: Equatable {
        case projects
        case all
        case project(UUID)
    }

    @State private var selection: Selection = .all
    @AppStorage("tasks.projectLayout") private var projectLayout: ProjectLayout = .grid
    @AppStorage("tasks.filter") private var filter: StatusFilter = .active

    /// Which statuses the list shows. `active` is everything but complete.
    private enum StatusFilter: String, CaseIterable {
        case active, all, inProcess, pending, review, complete

        var title: String {
            switch self {
            case .active: "Active"
            case .all: "All"
            case .inProcess: TaskStatus.inProcess.title
            case .pending: TaskStatus.pending.title
            case .review: TaskStatus.review.title
            case .complete: TaskStatus.complete.title
            }
        }

        var symbol: String {
            switch self {
            case .active: "bolt.circle"
            case .all: "tray.full"
            case .inProcess: TaskStatus.inProcess.symbol
            case .pending: TaskStatus.pending.symbol
            case .review: TaskStatus.review.symbol
            case .complete: TaskStatus.complete.symbol
            }
        }

        func includes(_ status: TaskStatus) -> Bool {
            switch self {
            case .active: status != .complete
            case .all: true
            case .inProcess: status == .inProcess
            case .pending: status == .pending
            case .review: status == .review
            case .complete: status == .complete
            }
        }
    }

    /// The list's order: what is being worked on first, what is done last.
    private static let statusOrder: [TaskStatus] = [.inProcess, .pending, .review, .complete]

    private enum ProjectLayout: String {
        case grid, list
    }

    private var selectedProjectID: UUID? {
        if case .project(let id) = selection { return id }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch selection {
            case .projects:
                if projectLayout == .grid { projectsRow } else { projectsList }
            case .all, .project: taskList
            }
        }
        .foregroundStyle(.white)
        .onAppear(perform: openPendingSelection)
        .onChange(of: store.pendingSelection) { _, _ in openPendingSelection() }
    }

    /// The island re-opens where its compact form left off (the new task's project).
    private func openPendingSelection() {
        guard let pending = store.pendingSelection else { return }
        store.pendingSelection = nil
        withAnimation(.easeOut(duration: 0.15)) {
            switch pending {
            case .all: selection = .all
            case .project(let id): selection = .project(id)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            if selection != .projects {
                pill("Projects", symbol: "chevron.left", prominent: true) { withAnimation(.easeOut(duration: 0.15)) { selection = .projects } }
                if case .project(let id) = selection {
                    ForEach(store.path(to: id)) { project in
                        Icon("chevron.right", size: 11, weight: .bold).foregroundStyle(.white.opacity(0.4))
                        pill(project.name, symbol: nil, prominent: project.id == id) { selection = .project(project.id) }
                    }
                } else {
                    Icon("chevron.right", size: 11, weight: .bold).foregroundStyle(.white.opacity(0.4))
                    pill("All tasks", symbol: nil, prominent: true) {}
                }
            } else {
                Text("Projects").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 0)
            if selection == .projects {
                HStack(spacing: 2) {
                    layoutButton(.grid, symbol: "square.grid.2x2")
                    layoutButton(.list, symbol: "list.bullet")
                }
                .padding(2)
                .background(.white.opacity(0.08), in: Capsule())
                plus("New project") { onPrompt(IslandPrompt(kind: .project(parent: nil))) }
            } else {
                filterMenu
                if let id = selectedProjectID {
                    plus("New sub-project", symbol: "folder.badge.plus") { onPrompt(IslandPrompt(kind: .project(parent: id), context: store.project(id)?.name)) }
                }
                plus("New task") { onPrompt(IslandPrompt(kind: .task(project: selectedProjectID))) }
            }
        }
        .frame(height: 24)
    }

    // The same chips as the group strip on the other tabs.
    private func pill(_ title: String, symbol: String?, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Icon(symbol, size: 12, weight: .semibold) }
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(prominent ? Color.white : .white.opacity(0.75))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(prominent ? Color.brand.opacity(0.85) : .white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Status filter: Active (default), All, or one status.
    private var filterMenu: some View {
        Menu {
            ForEach(StatusFilter.allCases, id: \.self) { value in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { filter = value }
                } label: {
                    Label { Text(value.title) } icon: { Icon(value.symbol, weight: .medium) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Icon(filter.symbol, size: 12, weight: .semibold)
                Text(filter.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Icon("chevron.down", size: 10, weight: .bold).opacity(0.7)
            }
            .foregroundStyle(filter == .active ? .white.opacity(0.75) : .yellow)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which tasks to list")
    }

    private func layoutButton(_ layout: ProjectLayout, symbol: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { projectLayout = layout }
        } label: {
            Icon(symbol, size: 12, weight: .semibold)
                .foregroundStyle(projectLayout == layout ? Color.white : .white.opacity(0.7))
                .frame(width: 24, height: 18)
                .background(projectLayout == layout ? Color.brand.opacity(0.85) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(layout == .grid ? "Grid" : "List")
    }

    private func plus(_ help: String, symbol: String = "plus", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(symbol, size: 12, weight: .semibold)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Projects

    private var projectsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ProjectCard(title: "All tasks", symbol: "tray.full", count: store.tasks.count, done: store.tasks.filter { $0.status == .complete }.count, subprojects: 0) {
                    withAnimation(.easeOut(duration: 0.15)) { selection = .all }
                }
                ForEach(store.subprojects(of: nil)) { project in
                    projectCard(project)
                }
                if store.projects.isEmpty {
                    Text("Add a project with + — or open All tasks.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.leading, 6)
                }
            }
            .padding(.bottom, 2)
        }
    }

    /// Every project as a row, nested ones indented under their parent.
    private var projectsList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ProjectRow(title: "All tasks", symbol: "tray.full", depth: 0, count: store.tasks.count, done: store.tasks.filter { $0.status == .complete }.count) {
                    withAnimation(.easeOut(duration: 0.15)) { selection = .all }
                }
                ForEach(projectTree(under: nil, depth: 0), id: \.project.id) { entry in
                    let tasks = store.tasks(in: entry.project.id)
                    ProjectRow(title: entry.project.name, symbol: entry.depth == 0 ? "folder.fill" : "folder", depth: entry.depth,
                               count: tasks.count, done: tasks.filter { $0.status == .complete }.count) {
                        withAnimation(.easeOut(duration: 0.15)) { selection = .project(entry.project.id) }
                    }
                    .contextMenu {
                        Button("New Sub-project…") { onPrompt(IslandPrompt(kind: .project(parent: entry.project.id), context: entry.project.name)) }
                        Button("Delete Project…", role: .destructive) { onPrompt(IslandPrompt(kind: .delete(.project(entry.project)))) }
                    }
                }
                if store.projects.isEmpty {
                    Text("Add a project with +.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(6)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func projectTree(under parentID: UUID?, depth: Int) -> [(project: TaskProject, depth: Int)] {
        store.subprojects(of: parentID).flatMap { [(project: $0, depth: depth)] + projectTree(under: $0.id, depth: depth + 1) }
    }

    private struct ProjectRow: View {
        let title: String
        let symbol: String
        let depth: Int
        let count: Int
        let done: Int
        let open: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 8) {
                Icon(symbol, size: 15).foregroundStyle(.white.opacity(0.8)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                if count > 0 {
                    Capsule().fill(.white.opacity(0.12))
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule().fill(.green).frame(width: proxy.size.width * CGFloat(done) / CGFloat(count))
                            }
                        }
                        .frame(width: 60, height: 4)
                }
                Text(count == 0 ? "No tasks" : "\(done)/\(count)")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
                    .frame(width: 52, alignment: .trailing)
                Icon("chevron.right", size: 11, weight: .bold).foregroundStyle(.white.opacity(hovering ? 0.7 : 0.3))
            }
            .padding(.leading, 6 + CGFloat(depth) * 16)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(hovering ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: open)
        }
    }

    private func projectCard(_ project: TaskProject) -> some View {
        let tasks = store.tasks(in: project.id)
        return ProjectCard(title: project.name, symbol: "folder.fill", count: tasks.count, done: tasks.filter { $0.status == .complete }.count,
                           subprojects: store.subprojects(of: project.id).count) {
            withAnimation(.easeOut(duration: 0.15)) { selection = .project(project.id) }
        }
        .contextMenu {
            Button("Delete Project…", role: .destructive) { onPrompt(IslandPrompt(kind: .delete(.project(project)))) }
        }
    }

    private struct ProjectCard: View {
        let title: String
        let symbol: String
        let count: Int
        let done: Int
        let subprojects: Int
        let open: () -> Void
        @State private var hovering = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Icon(symbol, size: 22).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(count == 0 ? "No tasks" : "\(done)/\(count) done")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6))
                    if subprojects > 0 {
                        Text("· \(subprojects) sub").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                if count > 0 {
                    GeometryReader { proxy in
                        Capsule().fill(.white.opacity(0.12))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.green).frame(width: proxy.size.width * CGFloat(done) / CGFloat(count))
                            }
                    }
                    .frame(height: 4)
                }
            }
            .padding(12)
            .frame(width: 160, height: 140, alignment: .topLeading)
            .background(.white.opacity(hovering ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(hovering ? Color.brand : .white.opacity(0.1), lineWidth: hovering ? 2 : 1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: open)
        }
    }

    // MARK: - Tasks

    private var taskList: some View {
        let tasks = store.tasks(in: selectedProjectID)
        let subprojects = selectedProjectID.map { store.subprojects(of: $0) } ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if !subprojects.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(subprojects) { project in
                            pill(project.name, symbol: "folder", prominent: false) {
                                withAnimation(.easeOut(duration: 0.15)) { selection = .project(project.id) }
                            }
                            .contextMenu { Button("Delete Project…", role: .destructive) { onPrompt(IslandPrompt(kind: .delete(.project(project)))) } }
                        }
                    }
                    .padding(.bottom, 4)
                }
                let groups = statusGroups(tasks)
                if groups.isEmpty {
                    Text(tasks.isEmpty ? "No tasks yet — add one with +." : filter == .active ? "Everything is complete." : "No \(filter.title.lowercased()) tasks.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.top, 8)
                }
                ForEach(groups, id: \.status) { group in
                    statusHeader(group)
                    ForEach(group.tasks) { task in taskRow(task, showProject: task.projectID != selectedProjectID) }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private struct StatusGroup {
        let status: TaskStatus
        var tasks: [TaskItem]
    }

    /// The filtered tasks in status order (in process, pending, review, complete);
    /// within a status the most urgent first, then newest. Empty statuses are skipped.
    private func statusGroups(_ tasks: [TaskItem]) -> [StatusGroup] {
        let rank = Dictionary(uniqueKeysWithValues: TaskPriority.allCases.enumerated().map { ($1, $0) })
        return Self.statusOrder.compactMap { status in
            guard filter.includes(status) else { return nil }
            let own = tasks.filter { $0.status == status }.sorted { (rank[$0.priority]!, $1.createdAt) < (rank[$1.priority]!, $0.createdAt) }
            return own.isEmpty ? nil : StatusGroup(status: status, tasks: own)
        }
    }

    private func statusHeader(_ group: StatusGroup) -> some View {
        HStack(spacing: 6) {
            Icon(group.status.symbol, size: 12, weight: .semibold)
                .foregroundStyle(group.status == .pending ? .white.opacity(0.85) : group.status.color)
            Text(group.status.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text("\(group.tasks.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func taskRow(_ task: TaskItem, showProject: Bool) -> some View {
        TaskRow(task: task, store: store, showProject: showProject) {
            onShowTask(task)
        } edit: {
            onPrompt(IslandPrompt(kind: .task(project: task.projectID), editing: task))
        } delete: {
            onPrompt(IslandPrompt(kind: .delete(.task(task))))
        }
    }

    /// Status icon (click cycles, menu picks), title (click to rename), project, time.
    private struct TaskRow: View {
        let task: TaskItem
        let store: TaskStore
        let showProject: Bool
        let open: () -> Void
        let edit: () -> Void
        let delete: () -> Void
        @State private var hovering = false
        @State private var renaming = false

        var body: some View {
            HStack(spacing: 8) {
                Menu {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Button {
                            store.setStatus(status, for: task)
                        } label: {
                            Label { Text(status.title) } icon: { Icon(status.symbol, weight: .medium) }
                        }
                    }
                } label: {
                    Icon(task.status.symbol, size: 16, weight: .medium)
                        .foregroundStyle(task.status.color)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                } primaryAction: {
                    store.setStatus(task.status.next, for: task)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(task.status.title)

                if renaming {
                    InlineTextField(initial: task.title, font: .system(size: 12)) { title in
                        renaming = false
                        store.rename(task, to: title)
                    } cancel: {
                        renaming = false
                    }
                } else {
                    Text(task.title)
                        .font(.system(size: 12))
                        .strikethrough(task.status == .complete, color: .white.opacity(0.5))
                        .foregroundStyle(task.status == .complete ? .white.opacity(0.5) : .white)
                        .lineLimit(1)
                }
                if task.hasMore {
                    Icon("text.alignleft", size: 11, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.45))
                        .help(task.summary)
                }
                Spacer(minLength: 4)
                if showProject, let project = store.project(task.projectID) {
                    Text(project.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.white.opacity(0.1), in: Capsule())
                        .lineLimit(1)
                }
                Text(task.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                // Priority and status as pills with their own menus, so they change
                // without opening the task.
                Menu {
                    ForEach(TaskPriority.allCases, id: \.self) { value in
                        Button { store.setPriority(value, for: task) } label: { Label { Text(value.title) } icon: { Icon(value.symbol, weight: .medium) } }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Icon(task.priority.symbol, size: 11, weight: .bold)
                        Text(task.priority.title).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(task.priority == .medium ? .white.opacity(0.7) : task.priority.color)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background((task.priority == .medium ? Color.white : task.priority.color).opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 78, alignment: .trailing)
                .help("Priority")
                Menu {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Button { store.setStatus(status, for: task) } label: { Label { Text(status.title) } icon: { Icon(status.symbol, weight: .medium) } }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(task.status.title).font(.system(size: 10, weight: .semibold))
                        Icon("chevron.down", size: 9, weight: .bold).opacity(0.7)
                    }
                    .foregroundStyle(task.status == .pending ? .white.opacity(0.8) : task.status.color)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background((task.status == .pending ? Color.white : task.status.color).opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 88, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(hovering ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if !renaming { open() } } // anywhere on the row; the status menu takes precedence
            .contextMenu {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Button(status.title) { store.setStatus(status, for: task) }
                }
                Menu("Priority") {
                    ForEach(TaskPriority.allCases, id: \.self) { value in
                        Button { store.setPriority(value, for: task) } label: { Label { Text(value.title) } icon: { Icon(value.symbol, weight: .medium) } }
                    }
                }
                Divider()
                Button("Open") { open() }
                Button("Edit…") { edit() }
                Button("Rename…") { renaming = true }
                Menu("Move to") {
                    Button("No project") { store.move(task, to: nil) }
                    ForEach(store.projects) { project in
                        Button(store.path(to: project.id).map(\.name).joined(separator: " › ")) { store.move(task, to: project.id) }
                    }
                }
                Divider()
                Button("Delete…", role: .destructive, action: delete)
            }
        }
    }
}
