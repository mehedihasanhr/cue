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

nonisolated struct TaskItem: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var notes: String
    var projectID: UUID?
    var status: TaskStatus
    var createdAt: Date

    init(title: String, notes: String = "", projectID: UUID?) {
        id = UUID()
        self.title = title
        self.notes = notes
        self.projectID = projectID
        status = .pending
        createdAt = .now
    }

    private enum CodingKeys: String, CodingKey { case id, title, notes, projectID, status, createdAt }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        status = try container.decode(TaskStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// Quick tasks in the island: a flat list of tasks and a tree of projects, kept as
/// one small JSON file in the app container.
@Observable
final class TaskStore {
    private(set) var projects: [TaskProject] = []
    private(set) var tasks: [TaskItem] = []   // newest first
    /// Where the Tasks tab should land after the island's prompt finishes.
    enum PendingSelection: Equatable { case all, project(UUID) }
    var pendingSelection: PendingSelection?

    private let fileURL: URL
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
        fileURL = folder.appendingPathComponent("tasks.json")
        imagesFolder = folder.appendingPathComponent("TaskImages", isDirectory: true)
        attachmentsFolder = folder.appendingPathComponent("TaskAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: attachmentsFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) {
            projects = file.projects
            tasks = file.tasks
        }
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

    @discardableResult
    func addTask(titled title: String, notes: String = "", in projectID: UUID?) -> TaskItem? {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let task = TaskItem(title: cleaned, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), projectID: projectID)
        tasks.insert(task, at: 0)
        save()
        return task
    }

    /// Edits a task's title, description and project in one go.
    func update(_ task: TaskItem, title: String, notes: String, projectID: UUID?) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        update(task) {
            $0.title = cleaned
            $0.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.projectID = projectID
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

    func rename(_ task: TaskItem, to title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        update(task) { $0.title = cleaned }
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
        let url = fileURL
        storage.async { try? data.write(to: url, options: .atomic) }
    }
}
