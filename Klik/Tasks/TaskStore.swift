import Foundation
import Observation
import SwiftUI

/// A project (a group of tasks); projects can nest inside one another.
nonisolated struct TaskProject: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var createdAt: Date

    init(name: String, parentID: UUID? = nil) {
        id = UUID()
        self.name = name
        self.parentID = parentID
        createdAt = .now
    }
}

nonisolated enum TaskStatus: String, Codable, CaseIterable {
    case pending, inProcess, review, complete

    var title: String {
        switch self {
        case .pending: "Pending"
        case .inProcess: "In process"
        case .review: "Review"
        case .complete: "Complete"
        }
    }

    var symbol: String {
        switch self {
        case .pending: "circle"
        case .inProcess: "circle.lefthalf.filled"
        case .review: "eye.circle.fill"
        case .complete: "checkmark.circle.fill"
        }
    }

    /// The next status when the icon is clicked.
    var next: TaskStatus {
        switch self {
        case .pending: .inProcess
        case .inProcess: .review
        case .review: .complete
        case .complete: .pending
        }
    }
}

extension TaskStatus {
    var color: Color {
        switch self {
        case .pending: .white.opacity(0.55)
        case .inProcess: .blue
        case .review: .orange
        case .complete: .green
        }
    }
}

/// How pressing a task is; the list orders each status group by it.
nonisolated enum TaskPriority: String, Codable, CaseIterable {
    case urgent, high, medium, low

    var title: String {
        switch self {
        case .urgent: "Urgent"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    var symbol: String {
        switch self {
        case .urgent: "flame.fill"
        case .high: "chevron.up.2"
        case .medium: "equal"
        case .low: "chevron.down"
        }
    }
}

extension TaskPriority {
    var color: Color {
        switch self {
        case .urgent: .red
        case .high: .orange
        case .medium: .white.opacity(0.55)
        case .low: .cyan
        }
    }
}

/// Shorthand typed into a task's title: `#project` picks (or creates) the project,
/// `!urgent` / `!high` / `!medium` / `!low` (or `!1`–`!4`) sets the priority. The
/// tokens are stripped from the saved title.
nonisolated enum TaskTokens {
    struct Parsed: Equatable {
        var title: String
        /// The `#` token as typed, without the `#`.
        var project: String?
        var priority: TaskPriority?
    }

    /// Lower-cased with the spaces removed, so "#NewWebsite" matches "New Website".
    static func compact(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace }
    }

    /// The `!` token's priority, from its name, a prefix of it ("!u", "!hi") or a number.
    static func priority(from token: String) -> TaskPriority? {
        var body = token.lowercased()
        guard body.hasPrefix("!") else { return nil }
        body.removeFirst()
        if body.hasPrefix("p") { body.removeFirst() }
        if let number = Int(body), (1...TaskPriority.allCases.count).contains(number) { return TaskPriority.allCases[number - 1] }
        guard !body.isEmpty else { return nil }
        return TaskPriority.allCases.first { $0.rawValue.hasPrefix(body) }
    }

    static func parse(_ title: String) -> Parsed {
        var parsed = Parsed(title: "", project: nil, priority: nil)
        var words: [String] = []
        for word in title.split(whereSeparator: \.isWhitespace).map(String.init) {
            if word.count > 1, word.hasPrefix("#"), parsed.project == nil {
                parsed.project = String(word.dropFirst())
            } else if word.hasPrefix("!"), let priority = priority(from: word) {
                parsed.priority = priority
            } else {
                words.append(word)
            }
        }
        parsed.title = words.joined(separator: " ")
        return parsed
    }
}

/// Something the user asked to delete and must confirm first.
nonisolated enum TaskDeletion: Hashable {
    case task(TaskItem)
    case project(TaskProject)
}

nonisolated struct TaskItem: Identifiable, Codable, Hashable {
    let id: UUID
    /// The whole task as Markdown. There is no title of its own: lists show the
    /// first line that says anything (`title`), plain.
    var text: String
    var projectID: UUID?
    var status: TaskStatus
    var priority: TaskPriority
    var createdAt: Date

    init(text: String, projectID: UUID?, priority: TaskPriority = .medium) {
        id = UUID()
        self.text = text
        self.projectID = projectID
        status = .pending
        self.priority = priority
        createdAt = .now
    }

    /// The first line that says anything, without Markdown — for lists.
    var title: String { TaskText.title(of: text) }
    /// What follows the title line, plain and on one line — for a card's preview.
    var summary: String { TaskText.summary(of: text) }
    /// Whether there is more than the title line.
    var hasMore: Bool { !summary.isEmpty }

    // `title` and `notes` are what older builds wrote (and read): the text is their join.
    private enum CodingKeys: String, CodingKey { case id, text, title, notes, projectID, status, priority, createdAt }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self.text = text
        } else {
            let title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            let notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
            text = TaskText.join(title: title, notes: notes)
        }
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        status = try container.decode(TaskStatus.self, forKey: .status)
        priority = try container.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .medium
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(projectID, forKey: .projectID)
        try container.encode(status, forKey: .status)
        try container.encode(priority, forKey: .priority)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// A task's text and the lines in it: the title line, what follows, and plain
/// renderings of Markdown for places that show one line.
nonisolated enum TaskText {
    /// A line's block mark (`## `, `- [ ] `, `1. `, `> `…) and what follows it.
    static func splitMark(_ line: String) -> (mark: String, body: String) {
        guard let match = line.firstMatch(of: #/^(#{1,6}\s+|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+|>\s+)/#) else { return ("", line) }
        return (String(match.0), String(line[match.range.upperBound...]))
    }

    /// The lines, and the index of the first that says anything.
    private static func lines(of text: String) -> (lines: [String], first: Int?) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return (lines, lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// The first line that says anything, as written.
    static func titleLine(of text: String) -> String {
        let (lines, first) = lines(of: text)
        return first.map { lines[$0].trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// The title line without its block mark or inline Markdown.
    static func title(of text: String) -> String {
        plain(splitMark(titleLine(of: text)).body)
    }

    /// Everything after the title line, plain, on one line.
    static func summary(of text: String) -> String {
        let (lines, first) = lines(of: text)
        guard let first else { return "" }
        return lines[(first + 1)...]
            .map { plain(splitMark($0.trimmingCharacters(in: .whitespaces)).body) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The text with its title line's body replaced (the block mark, if any, stays).
    static func replacingTitle(of text: String, with title: String) -> String {
        var (lines, first) = lines(of: text)
        guard let first else { return title }
        lines[first] = splitMark(lines[first].trimmingCharacters(in: .whitespaces)).mark + title
        return lines.joined(separator: "\n")
    }

    /// A title and a description as one text (what older builds stored).
    static func join(title: String, notes: String) -> String {
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? title : title + "\n\n" + notes
    }

    /// Inline Markdown stripped: emphasis and code marks gone, links and images
    /// reduced to their text.
    static func plain(_ inline: String) -> String {
        var text = inline
        text = text.replacing(#/!\[([^\]]*)\]\([^)]*\)/#) { match in match.1.isEmpty ? "Image" : String(match.1) }
        text = text.replacing(#/\[([^\]]+)\]\([^)]*\)/#) { match in String(match.1) }
        text = text.replacing(#/(\*\*|__|~~|`)(.+?)\1/#) { match in String(match.2) }
        text = text.replacing(#/(^|[^\w*_])[*_](\S(?:.*?\S)?)[*_]($|[^\w*_])/#) { match in String(match.1) + String(match.2) + String(match.3) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Quick tasks in the island: a flat list of tasks and a tree of projects, kept as
/// one small JSON file in the app container.
@Observable
@MainActor
final class TaskStore {
    private(set) var projects: [TaskProject] = []
    private(set) var tasks: [TaskItem] = []   // newest first
    /// Where the Tasks tab should land after the island's prompt finishes.
    enum PendingSelection: Equatable { case all, project(UUID) }
    var pendingSelection: PendingSelection?

    /// The file, in the container or the sync folder (attachments stay local).
    @ObservationIgnored private let file: SyncedFile
    /// Images pasted or dropped into descriptions, referenced as `klik://<name>`.
    private let imagesFolder: URL
    /// Other files dropped into descriptions, referenced as `klik-file://<id>/<name>`.
    private let attachmentsFolder: URL
    @ObservationIgnored private let storage = DispatchQueue(label: "com.stackrover.klik.tasks", qos: .utility)

    private struct File: Codable {
        var projects: [TaskProject]
        var tasks: [TaskItem]
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = support.appendingPathComponent("Klik", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = SyncedFile(name: "klik-tasks.json", local: folder.appendingPathComponent("tasks.json"))
        imagesFolder = folder.appendingPathComponent("TaskImages", isDirectory: true)
        attachmentsFolder = folder.appendingPathComponent("TaskAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: attachmentsFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file.url), let decoded = try? JSONDecoder().decode(File.self, from: data) {
            projects = decoded.projects
            tasks = decoded.tasks
        }
        file.changed = { [weak self] data in self?.load(data) }
    }

    /// Keeps the tasks in `folder` (nil: the container), taking what is there.
    func useSyncFolder(_ folder: URL?) {
        if let data = file.relocate(to: folder, current: try? JSONEncoder().encode(File(projects: projects, tasks: tasks))) { load(data) }
    }

    private func load(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode(File.self, from: data) else { return }
        projects = decoded.projects
        tasks = decoded.tasks
    }

    // MARK: - Projects

    func project(_ id: UUID?) -> TaskProject? {
        id.flatMap { id in projects.first { $0.id == id } }
    }

    /// Direct children of a project (nil: the top level).
    func subprojects(of parentID: UUID?) -> [TaskProject] {
        projects.filter { $0.parentID == parentID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The project and every project nested under it, for counting and listing.
    func descendants(of projectID: UUID) -> Set<UUID> {
        var result: Set<UUID> = [projectID]
        var frontier = [projectID]
        while let current = frontier.popLast() {
            for child in projects where child.parentID == current && !result.contains(child.id) {
                result.insert(child.id)
                frontier.append(child.id)
            }
        }
        return result
    }

    /// The project's own tasks plus those of its sub-projects (nil: every task).
    func tasks(in projectID: UUID?) -> [TaskItem] {
        guard let projectID else { return tasks }
        let ids = descendants(of: projectID)
        return tasks.filter { $0.projectID.map(ids.contains) ?? false }
    }

    /// From the top level down to the project, for the breadcrumb.
    func path(to projectID: UUID?) -> [TaskProject] {
        var path: [TaskProject] = []
        var current = project(projectID)
        while let project = current {
            path.insert(project, at: 0)
            current = self.project(project.parentID)
        }
        return path
    }

    @discardableResult
    func addProject(named name: String, in parentID: UUID? = nil) -> TaskProject? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let project = TaskProject(name: cleaned, parentID: parentID)
        projects.append(project)
        save()
        return project
    }

    func renameProject(_ project: TaskProject, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].name = cleaned
        save()
    }

    /// What deleting the project takes with it, for a confirmation.
    func deletionSummary(for project: TaskProject) -> String {
        let nested = descendants(of: project.id).count - 1
        let count = tasks(in: project.id).count
        var parts = [project.name]
        if count > 0 { parts.append(count == 1 ? "1 task moves to No project" : "\(count) tasks move to No project") }
        if nested > 0 { parts.append(nested == 1 ? "1 sub-project" : "\(nested) sub-projects") }
        return parts.joined(separator: " · ")
    }

    /// A confirmed deletion; returns what the island's status should say.
    @discardableResult
    func delete(_ deletion: TaskDeletion) -> (title: String, subtitle: String) {
        switch deletion {
        case .task(let task):
            delete(task)
            return ("Task deleted", task.title)
        case .project(let project):
            deleteProject(project)
            return ("Project deleted", project.name)
        }
    }

    /// Deletes the project and everything nested in it; their tasks move to no project.
    func deleteProject(_ project: TaskProject) {
        let ids = descendants(of: project.id)
        projects.removeAll { ids.contains($0.id) }
        for index in tasks.indices where tasks[index].projectID.map(ids.contains) ?? false {
            tasks[index].projectID = nil
        }
        save()
    }

    // MARK: - Tasks

    /// Adds a task from its whole text; nothing is added for a text that says nothing.
    @discardableResult
    func addTask(text: String, in projectID: UUID?, priority: TaskPriority = .medium) -> TaskItem? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TaskText.title(of: cleaned).isEmpty else { return nil }
        let task = TaskItem(text: cleaned, projectID: projectID, priority: priority)
        tasks.insert(task, at: 0)
        save()
        return task
    }

    /// Adds a task from a title and a description (URL commands, imports).
    @discardableResult
    func addTask(titled title: String, notes: String = "", in projectID: UUID?, priority: TaskPriority = .medium) -> TaskItem? {
        addTask(text: TaskText.join(title: title.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes), in: projectID, priority: priority)
    }

    /// One task to import: `{"project": "Klik", "title": "…", "notes": "…", "priority": "high"}`.
    nonisolated struct Import: Decodable {
        var project: String?
        var title: String
        var notes: String?
        var priority: TaskPriority?
    }

    /// Adds tasks from a JSON list, making projects by name as needed. Listed order is
    /// kept (the first ends up on top). Returns how many were added.
    @discardableResult
    func importTasks(from data: Data) -> Int {
        guard let entries = try? JSONDecoder().decode([Import].self, from: data) else { return 0 }
        var added = 0
        for entry in entries.reversed() {
            var projectID: UUID?
            if let name = entry.project?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                projectID = (projects.first { $0.parentID == nil && $0.name == name } ?? addProject(named: name))?.id
            }
            if addTask(titled: entry.title, notes: entry.notes ?? "", in: projectID, priority: entry.priority ?? .medium) != nil { added += 1 }
        }
        return added
    }

    /// Sets the status of every task whose title starts with one of `titles`
    /// (case-insensitive). Returns how many changed. For scripts, like `importTasks`.
    @discardableResult
    func setStatus(_ status: TaskStatus, forTitlesStartingWith titles: [String]) -> Int {
        var changed = 0
        for task in tasks where task.status != status {
            if titles.contains(where: { task.title.lowercased().hasPrefix($0.lowercased()) }) {
                setStatus(status, for: task)
                changed += 1
            }
        }
        return changed
    }

    /// Edits a task's text, project and priority in one go.
    func update(_ task: TaskItem, text: String, projectID: UUID?, priority: TaskPriority) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TaskText.title(of: cleaned).isEmpty else { return }
        update(task) {
            $0.text = cleaned
            $0.projectID = projectID
            $0.priority = priority
        }
    }

    // MARK: - Description images

    /// Stores image data for a description and returns the Markdown to embed it.
    func saveImage(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let name = "\(UUID().uuidString).png"
        let url = imagesFolder.appendingPathComponent(name)
        let isPNG = (CGImageSourceGetType(source) as String?) == "public.png"
        let png = isPNG ? data : CGImageSourceCreateImageAtIndex(source, 0, nil).flatMap(ImageEncoding.png)
        guard let png, (try? png.write(to: url, options: .atomic)) != nil else { return nil }
        return "![image](klik://\(name))"
    }

    /// Copies a file into the attachments folder and returns the Markdown to link it.
    func saveAttachment(_ url: URL) -> String? {
        let id = UUID().uuidString
        let destination = attachmentsFolder.appendingPathComponent(id, isDirectory: true).appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            return nil
        }
        let name = url.lastPathComponent.replacingOccurrences(of: "]", with: ")")
        let escaped = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.lastPathComponent
        return "[\(name)](klik-file://\(id)/\(escaped))"
    }

    /// The file behind a `klik-file://<id>/<name>` attachment reference.
    func attachmentURL(for source: String) -> URL? {
        guard source.hasPrefix("klik-file://") else { return nil }
        let parts = source.dropFirst(12).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, !parts[0].contains(".."), let name = String(parts[1]).removingPercentEncoding, !name.contains("/") else { return nil }
        let url = attachmentsFolder.appendingPathComponent(String(parts[0]), isDirectory: true).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The file behind a `klik://<name>` image reference.
    func imageURL(for source: String) -> URL? {
        guard source.hasPrefix("klik://") else { return nil }
        let name = String(source.dropFirst(7))
        guard !name.contains("/"), !name.contains("..") else { return nil }
        let url = imagesFolder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func setStatus(_ status: TaskStatus, for task: TaskItem) {
        update(task) { $0.status = status }
    }

    func setPriority(_ priority: TaskPriority, for task: TaskItem) {
        update(task) { $0.priority = priority }
    }

    /// Replaces the title line (the rest of the text stays).
    func rename(_ task: TaskItem, to title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        update(task) { $0.text = TaskText.replacingTitle(of: $0.text, with: cleaned) }
    }

    func move(_ task: TaskItem, to projectID: UUID?) {
        update(task) { $0.projectID = projectID }
    }

    func delete(_ task: TaskItem) {
        tasks.removeAll { $0.id == task.id }
        save()
    }

    private func update(_ task: TaskItem, _ change: (inout TaskItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        change(&tasks[index])
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(File(projects: projects, tasks: tasks)) else { return }
        file.write(data)
    }
}
