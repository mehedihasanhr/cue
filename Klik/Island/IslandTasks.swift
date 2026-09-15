import AppKit
import SwiftUI

/// The Tasks tab: every task to start with, grouped by project; a group's header
/// opens that project (its tasks by day, sub-projects as pills to drill into), and
/// "Projects" shows the projects themselves as cards or rows.
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
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                        pill(project.name, symbol: nil, prominent: project.id == id) { selection = .project(project.id) }
                    }
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                    pill("All tasks", symbol: nil, prominent: true) {}
                }
            } else {
                Text("Projects").font(.system(size: 13, weight: .semibold))
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
                if let id = selectedProjectID {
                    plus("New sub-project", symbol: "folder.badge.plus") { onPrompt(IslandPrompt(kind: .project(parent: id), context: store.project(id)?.name)) }
                }
                plus("New task") { onPrompt(IslandPrompt(kind: .task(project: selectedProjectID))) }
            }
        }
        .frame(height: 28)
    }

    private func pill(_ title: String, symbol: String?, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(prominent ? .black : .white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(prominent ? Color.white : Color.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func layoutButton(_ layout: ProjectLayout, symbol: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { projectLayout = layout }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(projectLayout == layout ? .black : .white.opacity(0.7))
                .frame(width: 24, height: 22)
                .background(projectLayout == layout ? Color.white : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(layout == .grid ? "Grid" : "List")
    }

    private func plus(_ help: String, symbol: String = "plus", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
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
                        Button("Delete Project", role: .destructive) { store.deleteProject(entry.project) }
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
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).frame(width: 18)
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
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(hovering ? 0.7 : 0.3))
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
            Button("Delete Project", role: .destructive) { store.deleteProject(project) }
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
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.white.opacity(0.85))
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
                            .contextMenu { Button("Delete Project", role: .destructive) { store.deleteProject(project) } }
                        }
                    }
                    .padding(.bottom, 4)
                }
                if tasks.isEmpty {
                    Text("No tasks yet — add one with +.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.top, 8)
                }
                if selection == .all {
                    // Every task, one group per project; the header opens the project.
                    ForEach(projectGroups(tasks), id: \.id) { group in
                        projectHeader(group)
                        ForEach(group.tasks) { task in taskRow(task, showProject: false) }
                    }
                } else {
                    ForEach(dayGroups(tasks), id: \.day) { group in
                        Text(group.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .textCase(.uppercase)
                            .padding(.horizontal, 6)
                            .padding(.top, 6)
                        ForEach(group.tasks) { task in taskRow(task, showProject: task.projectID != selectedProjectID) }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func taskRow(_ task: TaskItem, showProject: Bool) -> some View {
        TaskRow(task: task, store: store, showProject: showProject) {
            onShowTask(task)
        } edit: {
            onPrompt(IslandPrompt(kind: .task(project: task.projectID), editing: task))
        }
    }

    private struct ProjectGroup {
        /// nil: tasks outside any project.
        let id: UUID?
        let title: String
        var tasks: [TaskItem]
    }

    /// Tasks by project in the projects' own order (nested ones under their path),
    /// tasks outside any project last.
    private func projectGroups(_ tasks: [TaskItem]) -> [ProjectGroup] {
        var groups: [ProjectGroup] = []
        for entry in projectTree(under: nil, depth: 0) {
            let own = tasks.filter { $0.projectID == entry.project.id }
            guard !own.isEmpty else { continue }
            groups.append(ProjectGroup(id: entry.project.id, title: store.path(to: entry.project.id).map(\.name).joined(separator: " › "), tasks: own))
        }
        let loose = tasks.filter { store.project($0.projectID) == nil }
        if !loose.isEmpty { groups.append(ProjectGroup(id: nil, title: "No project", tasks: loose)) }
        return groups
    }

    private func projectHeader(_ group: ProjectGroup) -> some View {
        Button {
            guard let id = group.id else { return }
            withAnimation(.easeOut(duration: 0.15)) { selection = .project(id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: group.id == nil ? "tray" : "folder.fill").font(.system(size: 10, weight: .semibold))
                Text(group.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text("\(group.tasks.count { $0.status != .complete })/\(group.tasks.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                if group.id != nil {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(group.id == nil)
    }

    private struct DayGroup {
        let day: Date
        let title: String
        var tasks: [TaskItem]
    }

    private func dayGroups(_ tasks: [TaskItem]) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        for task in tasks {
            let day = calendar.startOfDay(for: task.createdAt)
            if let index = groups.firstIndex(where: { $0.day == day }) {
                groups[index].tasks.append(task)
            } else {
                let title = calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday"
                    : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                groups.append(DayGroup(day: day, title: title, tasks: [task]))
            }
        }
        return groups
    }

    /// Status icon (click cycles, menu picks), title (click to rename), project, time.
    private struct TaskRow: View {
        let task: TaskItem
        let store: TaskStore
        let showProject: Bool
        let open: () -> Void
        let edit: () -> Void
        @State private var hovering = false
        @State private var renaming = false

        var body: some View {
            HStack(spacing: 8) {
                Menu {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Button {
                            store.setStatus(status, for: task)
                        } label: {
                            Label(status.title, systemImage: status.symbol)
                        }
                    }
                } label: {
                    Image(systemName: task.status.symbol)
                        .font(.system(size: 13, weight: .medium))
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
                if !task.notes.isEmpty {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .help(task.notes)
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
                // The status as a pill with its own menu, so it changes without opening the task.
                Menu {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Button { store.setStatus(status, for: task) } label: { Label(status.title, systemImage: status.symbol) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(task.status.title).font(.system(size: 10, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.7)
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
                if hovering {
                    Button { store.delete(task) } label: {
                        Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).foregroundStyle(.red.opacity(0.9))
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(hovering ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if !renaming { open() } } // anywhere on the row; the status and trash buttons take precedence
            .contextMenu {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Button(status.title) { store.setStatus(status, for: task) }
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
                Button("Delete", role: .destructive) { store.delete(task) }
            }
        }
    }
}
