import AppKit
import Foundation
import Observation
import os
import SwiftUI

/// A project (a group of tasks); projects can nest inside one another.
nonisolated struct TaskProject: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var createdAt: Date
    /// Set on the projects that mirror a connected organization (Sensory OS): its root,
    /// and one per board. They are kept by the sync, not by hand.
    var org: OrgLink?

    /// Part of a connected organization: its tasks go to the web, it is not renamed or
    /// deleted here.
    var isOrg: Bool { org != nil }

    init(name: String, parentID: UUID? = nil) {
        id = UUID()
        self.name = name
        self.parentID = parentID
        createdAt = .now
    }

    /// A project as a server sent it.
    init(id: UUID, name: String, parentID: UUID?, createdAt: Date) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
    }
}

nonisolated enum TaskStatus: String, Codable, CaseIterable {
    case pending, inProcess, review, complete

    var title: String {
        switch self {
        // Still `pending` when saved and synced; called To do where it shows.
        case .pending: "To do"
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
/// A change to a task, for webhooks.
nonisolated enum TaskEvent {
    case created(TaskItem)
    case updated(TaskItem)
    case statusChanged(TaskItem)
    case deleted(TaskItem)

    var task: TaskItem {
        switch self {
        case .created(let task), .updated(let task), .statusChanged(let task), .deleted(let task): task
        }
    }

    /// The event's name on the wire: `task.created`, `task.updated`, `task.status`, `task.deleted`.
    var name: String { "task.\(kind)" }

    /// The kind as Settings › Tasks lists it: `created`, `updated`, `status`, `deleted`.
    var kind: String {
        switch self {
        case .created: "created"
        case .updated: "updated"
        case .statusChanged: "status"
        case .deleted: "deleted"
        }
    }
}

nonisolated enum TaskDeletion: Hashable {
    case task(TaskItem)
    case project(TaskProject)
}

nonisolated struct TaskItem: Identifiable, Codable, Hashable {
    let id: UUID
    /// The whole task as Markdown — its description, kept as written.
    var text: String
    /// A title given by renaming the task. nil: the title is taken from the text
    /// (its first line that says anything, plain and kept short).
    var customTitle: String?
    var projectID: UUID?
    var status: TaskStatus
    var priority: TaskPriority
    /// Who the task is for: a name, as it was typed ("Yat"). nil: no one.
    var assignee: String?
    /// The task this one is a step of. nil: a task on its own.
    var parentID: UUID?
    /// When it is due, if it has a date.
    var due: Date?
    /// Put away: kept, but out of every list but Archived. nil: in the lists.
    var archivedAt: Date?
    /// Labels it carries ("feature", "bug", "waiting-on-meta"), as written.
    var labels: [String] = []
    /// Commits, pull requests, branches, plan files and pages it is tied to.
    var links: [TaskLink] = []
    /// Small steps inside the task, ticked off one by one.
    var checklist: [ChecklistItem] = []
    /// Tasks that have to be complete before this one can go on.
    var blockedBy: [UUID] = []
    /// The Claude Code session that worked on it, to go back to.
    var sessionID: String?
    /// What "done" looks like for it, said when it was planned.
    var doneWhen: String?
    /// A task for the work, or a step only the owner can take.
    var kind: TaskKind = .task
    var createdAt: Date
    /// When it last changed here; what decides between two copies when syncing.
    var updatedAt: Date
    /// The copy of this task on a connected organization's website, once it has one (or
    /// is about to): a task in an organization project.
    var remote: RemoteLink?

    init(text: String, projectID: UUID?, priority: TaskPriority = .medium) {
        id = UUID()
        self.text = text
        self.projectID = projectID
        status = .pending
        self.priority = priority
        createdAt = .now
        updatedAt = createdAt
    }

    /// A task as a server sent it.
    init(id: UUID, text: String, customTitle: String? = nil, projectID: UUID?, status: TaskStatus, priority: TaskPriority, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.text = text
        self.customTitle = customTitle
        self.projectID = projectID
        self.status = status
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The name lists show: the one it was renamed to, else one taken from the text.
    var title: String {
        if let customTitle, !customTitle.trimmingCharacters(in: .whitespaces).isEmpty { return customTitle }
        return TaskText.autoTitle(of: text)
    }
    /// The description, plain and on one line, for a card's preview: what follows the
    /// line the title was taken from, or all of it when the title is its own.
    var summary: String { customTitle == nil ? TaskText.summary(of: text) : TaskText.oneLine(text) }
    /// Whether there is more to read than the title.
    var hasMore: Bool { !summary.isEmpty }

    // `title` and `notes` are what older builds wrote (and read): the text is their
    // join. `title` is still written, so they keep showing a name.
    private enum CodingKeys: String, CodingKey {
        case id, text, title, customTitle, notes, projectID, status, priority, assignee, createdAt, updatedAt, remote
        case parentID, due, archivedAt, labels, links, checklist, blockedBy, sessionID, doneWhen, kind
    }

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
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        status = try container.decode(TaskStatus.self, forKey: .status)
        priority = try container.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .medium
        assignee = try container.decodeIfPresent(String.self, forKey: .assignee)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        due = try container.decodeIfPresent(Date.self, forKey: .due)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        links = try container.decodeIfPresent([TaskLink].self, forKey: .links) ?? []
        checklist = try container.decodeIfPresent([ChecklistItem].self, forKey: .checklist) ?? []
        blockedBy = try container.decodeIfPresent([UUID].self, forKey: .blockedBy) ?? []
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        doneWhen = try container.decodeIfPresent(String.self, forKey: .doneWhen)
        kind = try container.decodeIfPresent(TaskKind.self, forKey: .kind) ?? .task
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        remote = try container.decodeIfPresent(RemoteLink.self, forKey: .remote)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encodeIfPresent(projectID, forKey: .projectID)
        try container.encode(status, forKey: .status)
        try container.encode(priority, forKey: .priority)
        try container.encodeIfPresent(assignee, forKey: .assignee)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(due, forKey: .due)
        try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
        if !labels.isEmpty { try container.encode(labels, forKey: .labels) }
        if !links.isEmpty { try container.encode(links, forKey: .links) }
        if !checklist.isEmpty { try container.encode(checklist, forKey: .checklist) }
        if !blockedBy.isEmpty { try container.encode(blockedBy, forKey: .blockedBy) }
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(doneWhen, forKey: .doneWhen)
        if kind != .task { try container.encode(kind, forKey: .kind) }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(remote, forKey: .remote)
    }
}

nonisolated extension TaskItem {
    var isArchived: Bool { archivedAt != nil }

    /// What only this Mac keeps of a task, carried over from `old` when a copy comes in
    /// from a server or the website, which know nothing of it (an assignee only when the
    /// copy brings none).
    mutating func keepLocal(from old: TaskItem) {
        if assignee == nil { assignee = old.assignee }
        parentID = old.parentID
        due = due ?? old.due
        archivedAt = old.archivedAt
        labels = old.labels
        links = old.links
        checklist = old.checklist
        blockedBy = old.blockedBy
        sessionID = old.sessionID
        doneWhen = old.doneWhen
        kind = old.kind
    }
}

/// A step only the owner can take is apart from the work: it has its own list,
/// "Waiting on you", so a blocked task does not hide among the others.
nonisolated enum TaskKind: String, Codable, CaseIterable {
    case task
    case ownerStep = "owner_step"
}

/// Something a task is tied to: a commit, a pull request, a branch, a plan file, a
/// staging page. Shown as a chip that opens it.
nonisolated struct TaskLink: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case commit, pr, branch, plan, staging, url
    }

    var id = UUID()
    var kind: Kind
    /// A URL, a path, a commit hash or a branch name, as given.
    var target: String
    /// A short name for the chip ("#592", "a1b2c3d"); the target's own when nil.
    var title: String?
    var addedAt = Date.now

    /// The chip's words.
    var label: String {
        if let title, !title.isEmpty { return title }
        switch kind {
        case .commit: return String(target.split(separator: "/").last.map(String.init)?.prefix(7) ?? Substring(target))
        case .pr:
            if let number = target.split(separator: "/").last, number.allSatisfy(\.isNumber) { return "#\(number)" }
            return target
        case .branch: return target
        case .plan: return URL(fileURLWithPath: target).lastPathComponent
        case .staging, .url: return URL(string: target)?.host() ?? target
        }
    }

    var symbol: String {
        switch kind {
        case .commit: "point.3.connected.trianglepath.dotted"
        case .pr: "arrow.triangle.pull"
        case .branch: "arrow.branch"
        case .plan: "doc.text"
        case .staging: "globe"
        case .url: "link"
        }
    }

    /// Where a click goes: the URL, or the file for a path; nil for a bare hash or branch.
    var url: URL? {
        if target.hasPrefix("/") || target.hasPrefix("~") { return URL(fileURLWithPath: (target as NSString).expandingTildeInPath) }
        guard let url = URL(string: target), url.scheme != nil else { return nil }
        return url
    }

    /// Whether a link proves work was shipped: a commit or a pull request.
    var isProof: Bool { kind == .commit || kind == .pr }
}

/// One small step inside a task.
nonisolated struct ChecklistItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var done = false
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

    /// The longest title taken from a text; longer, it is cut at a word and ends in "…".
    static let autoTitleLength = 80

    /// A title for a task that has none of its own: its first line, plain, kept short.
    static func autoTitle(of text: String) -> String {
        let title = title(of: text)
        guard title.count > autoTitleLength else { return title }
        let cut = title.prefix(autoTitleLength)
        let atWord = cut.lastIndex(where: \.isWhitespace).map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The custom title to keep for `title` given `text`: nil when it is just the one
    /// the text would give anyway, so the title goes on following the text.
    static func customTitle(_ title: String, for text: String) -> String? {
        title == autoTitle(of: text) ? nil : title
    }

    /// A line that is only an image or an attached file: nothing to read in a one-line
    /// preview, where it would show as the word "image".
    static func isMediaLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).wholeMatch(of: #/!?\[[^\]]*\]\([^)]*\)/#) != nil
    }

    /// Every line, plain, on one line.
    static func oneLine(_ text: String) -> String {
        text.split(separator: "\n")
            .filter { !isMediaLine(String($0)) }
            .map { plain(splitMark($0.trimmingCharacters(in: .whitespaces)).body) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Everything after the title line, plain, on one line.
    static func summary(of text: String) -> String {
        let (lines, first) = lines(of: text)
        guard let first else { return "" }
        return lines[(first + 1)...]
            .filter { !isMediaLine($0) }
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
    /// Tasks deleted here and not yet told to the server.
    private(set) var deletedIDs: [UUID] = []
    /// A change made here was saved (not one taken from the server).
    @ObservationIgnored var onChanged: () -> Void = {}
    /// The same, for the organization sync (`onChanged` belongs to the task server's).
    @ObservationIgnored var onLocalChange: () -> Void = {}
    /// A task changed here, for webhooks.
    @ObservationIgnored var onEvent: (TaskEvent) -> Void = { _ in }
    /// Changes from the server are being applied: they are neither pushed back nor announced.
    @ObservationIgnored private var applyingRemote = false
    /// Where the Tasks tab should land after the island's prompt finishes.
    enum PendingSelection: Equatable { case all, project(UUID) }
    var pendingSelection: PendingSelection?

    /// The file, in the container or the sync folder (attachments stay local).
    @ObservationIgnored private let file: SyncedFile
    /// Images pasted or dropped into descriptions, referenced as `cue://<name>`.
    private let imagesFolder: URL
    /// Other files dropped into descriptions, referenced as `cue-file://<id>/<name>`.
    private let attachmentsFolder: URL
    @ObservationIgnored private let storage = DispatchQueue(label: "com.stackrover.cue.tasks", qos: .utility)

    private struct File: Codable {
        var projects: [TaskProject]
        var tasks: [TaskItem]
        var deleted: [UUID]?
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = support.appendingPathComponent("Cue", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = SyncedFile(name: "cue-tasks.json", local: folder.appendingPathComponent("tasks.json"))
        imagesFolder = folder.appendingPathComponent("TaskImages", isDirectory: true)
        attachmentsFolder = folder.appendingPathComponent("TaskAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: attachmentsFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file.url), let decoded = try? JSONDecoder().decode(File.self, from: data) {
            projects = decoded.projects
            tasks = decoded.tasks
            deletedIDs = decoded.deleted ?? []
        }
        file.changed = { [weak self] data in self?.load(data) }
    }

    /// The folder the shared sync setting asks for (Settings › General), kept so a
    /// task folder of its own can be given up and this taken back.
    @ObservationIgnored private var syncFolderURL: URL?
    /// The folder chosen for the tasks alone (Settings › Tasks), which wins over the
    /// shared one.
    private(set) var ownFolderURL: URL?
    @ObservationIgnored private var accessingOwn = false
    private static let folderBookmarkKey = "tasks.folderBookmark"

    /// Where `tasks.json` is now: the folder chosen for the tasks, else the shared
    /// sync folder, else Cue's own.
    var folderURL: URL { file.url.deletingLastPathComponent() }
    /// Whether the tasks have a folder of their own, rather than following the
    /// shared one.
    var folderIsCustom: Bool { ownFolderURL != nil }

    /// Takes up the folder chosen for the tasks last time, if there still is one.
    /// Called once at launch, before `useSyncFolder`.
    func restoreOwnFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.folderBookmarkKey) else { return }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: resolved.path) else { return }
        ownFolderURL = resolved
        accessingOwn = resolved.startAccessingSecurityScopedResource()
    }

    /// Keeps the tasks in `folder` (nil: the container), taking what is there. A
    /// folder chosen for the tasks alone wins: the shared setting is remembered, and
    /// takes over again if that folder is given up.
    func useSyncFolder(_ folder: URL?) {
        syncFolderURL = folder
        relocate(to: ownFolderURL ?? folder)
    }

    /// Asks for a folder to keep `cue-tasks.json` in. One in iCloud Drive or Dropbox
    /// puts the tasks on another Mac; a file already there is taken as it is, rather
    /// than being written over.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Keep Tasks Here"
        panel.message = "Choose a folder for your tasks — one in iCloud Drive or Dropbox syncs them between Macs"
        panel.directoryURL = ownFolderURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let chosen = panel.url, chosen != ownFolderURL else { return }
        do {
            let bookmark = try chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.folderBookmarkKey)
            stopAccessingOwn()
            ownFolderURL = chosen
            accessingOwn = chosen.startAccessingSecurityScopedResource()
            relocate(to: chosen)
            Log.app.info("Tasks folder set to \(chosen.path, privacy: .public)")
        } catch {
            Log.app.error("Could not bookmark the tasks folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Gives up the tasks' own folder; the shared sync folder (or Cue's own) takes
    /// over again, and the tasks come along.
    func useDefaultFolder() {
        guard ownFolderURL != nil else { return }
        UserDefaults.standard.removeObject(forKey: Self.folderBookmarkKey)
        stopAccessingOwn()
        ownFolderURL = nil
        relocate(to: syncFolderURL)
    }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    private func stopAccessingOwn() {
        if accessingOwn { ownFolderURL?.stopAccessingSecurityScopedResource() }
        accessingOwn = false
    }

    private func relocate(to folder: URL?) {
        if let data = file.relocate(to: folder, current: try? JSONEncoder().encode(File(projects: projects, tasks: tasks, deleted: deletedIDs))) { load(data) }
    }

    private func load(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode(File.self, from: data) else { return }
        projects = decoded.projects
        tasks = decoded.tasks
        deletedIDs = decoded.deleted ?? []
    }

    // MARK: - Remote changes

    /// Takes what a server sent: tasks it has that are missing here or newer than
    /// the copy here, projects missing here (or renamed), and deletions. Returns
    /// how many tasks changed. Nothing taken is pushed back or announced.
    @discardableResult
    func applyRemote(tasks remote: [TaskItem], projects remoteProjects: [TaskProject], deleted: [UUID]) -> Int {
        applyingRemote = true
        defer { applyingRemote = false }
        var changed = 0
        for project in remoteProjects {
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                if projects[index].name != project.name || projects[index].parentID != project.parentID {
                    projects[index].name = project.name
                    projects[index].parentID = project.parentID
                }
            } else {
                projects.append(project)
            }
        }
        for var task in remote where !deletedIDs.contains(task.id) {
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                if task.updatedAt > tasks[index].updatedAt {
                    // What the server does not keep (subtasks, links, checklists…) stays.
                    task.keepLocal(from: tasks[index])
                    tasks[index] = task
                    changed += 1
                }
            } else {
                tasks.insert(task, at: 0)
                changed += 1
            }
        }
        if !deleted.isEmpty {
            let before = tasks.count
            tasks.removeAll { deleted.contains($0.id) }
            changed += before - tasks.count
        }
        tasks.sort { $0.createdAt > $1.createdAt }
        save()
        return changed
    }

    /// The server has been told about these deletions.
    func clearDeleted(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        deletedIDs.removeAll(where: ids.contains)
        save()
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
        guard let projectID else { return tasks.filter { !$0.isArchived } }
        let ids = descendants(of: projectID)
        return tasks.filter { !$0.isArchived && ($0.projectID.map(ids.contains) ?? false) }
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
        // An organization's projects are its boards, made on the website.
        guard !cleaned.isEmpty, project(parentID)?.isOrg != true else { return nil }
        let project = TaskProject(name: cleaned, parentID: parentID)
        projects.append(project)
        save()
        return project
    }

    func renameProject(_ project: TaskProject, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = projects.firstIndex(where: { $0.id == project.id }), !projects[index].isOrg else { return }
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
        guard !project.isOrg else { return }
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
        onEvent(.created(task))
        return task
    }

    /// Adds a task from a title and a description (URL commands, imports).
    @discardableResult
    func addTask(titled title: String, notes: String = "", in projectID: UUID?, priority: TaskPriority = .medium) -> TaskItem? {
        addTask(text: TaskText.join(title: title.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes), in: projectID, priority: priority)
    }

    /// One task to import: `{"project": "Cue", "title": "…", "notes": "…", "priority": "high"}`.
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
        guard !TaskText.title(of: cleaned).isEmpty || task.customTitle != nil else { return }
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
        return "![image](cue://\(name))"
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
        return "[\(name)](cue-file://\(id)/\(escaped))"
    }

    /// The file behind a `cue-file://<id>/<name>` attachment reference.
    func attachmentURL(for source: String) -> URL? {
        let scheme = "cue-file://"
        guard source.hasPrefix(scheme) else { return nil }
        let parts = source.dropFirst(scheme.count).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, !parts[0].contains(".."), let name = String(parts[1]).removingPercentEncoding, !name.contains("/") else { return nil }
        let url = attachmentsFolder.appendingPathComponent(String(parts[0]), isDirectory: true).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The file behind a `cue://<name>` image reference.
    func imageURL(for source: String) -> URL? {
        let scheme = "cue://"
        guard source.hasPrefix(scheme) else { return nil }
        let name = String(source.dropFirst(scheme.count))
        guard !name.contains("/"), !name.contains("..") else { return nil }
        let url = imagesFolder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func setStatus(_ status: TaskStatus, for task: TaskItem) {
        update(task, event: TaskEvent.statusChanged) { $0.status = status }
    }

    func setPriority(_ priority: TaskPriority, for task: TaskItem) {
        update(task) { $0.priority = priority }
    }

    /// Assigns the task to someone by name; nil or blank, to no one. A name already used
    /// on another task in another case ("yat" for "Yat") takes that spelling, so one
    /// person is one name in the column and its menu.
    func setAssignee(_ name: String?, for task: TaskItem) {
        let typed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let wanted = typed.isEmpty ? nil : assignees.first { $0.caseInsensitiveCompare(typed) == .orderedSame } ?? typed
        guard wanted != task.assignee else { return }
        update(task) { $0.assignee = wanted }
    }

    /// Any change to a task, saved and announced as one edit (the agents' tools use it
    /// for what has no button of its own: links, labels, checklists, dependencies).
    func edit(_ task: TaskItem, _ change: (inout TaskItem) -> Void) {
        update(task, change)
    }

    /// Puts a task away (it stays, out of the lists), or back.
    func setArchived(_ archived: Bool, for task: TaskItem) {
        guard archived != task.isArchived else { return }
        update(task) { $0.archivedAt = archived ? .now : nil }
    }

    /// The steps of a task, in the order they were made.
    func subtasks(of task: TaskItem) -> [TaskItem] {
        tasks.filter { $0.parentID == task.id }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The tasks holding this one up: those it waits on that are not complete.
    func blockers(of task: TaskItem) -> [TaskItem] {
        task.blockedBy.compactMap { id in tasks.first { $0.id == id } }.filter { $0.status != .complete && !$0.isArchived }
    }

    /// Every label in use, the most used first.
    var labels: [String] {
        var count: [String: Int] = [:]
        for task in tasks where !task.isArchived { for label in task.labels { count[label, default: 0] += 1 } }
        return count.keys.sorted { count[$0]! != count[$1]! ? count[$0]! > count[$1]! : $0 < $1 }
    }

    /// Whether a task may go to a project, and if not why: a task on the website can
    /// change boards only there (Sensory OS cannot be told of a move yet), and Cue would
    /// otherwise put it back at the next sync.
    func moveRefusal(_ task: TaskItem, to projectID: UUID?) -> String? {
        guard let remote = task.remote, remote.taskID != nil,
              let board = orgProject(projectID)?.org?.boardID, board != remote.boardID else { return nil }
        return "Sensory OS can't move a task to another board from Cue yet. Move it on the website."
    }

    /// Everyone tasks are assigned to, those with the most open tasks first.
    var assignees: [String] {
        var count: [String: Int] = [:]
        for task in tasks {
            guard let name = task.assignee else { continue }
            count[name, default: 0] += task.status == .complete ? 0 : 1
        }
        return count.keys.sorted { count[$0]! != count[$1]! ? count[$0]! > count[$1]! : $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Gives the task a title of its own; the description is left as it is. A title
    /// the same as the one taken from the text puts it back to following the text.
    func rename(_ task: TaskItem, to title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let custom = TaskText.customTitle(cleaned, for: task.text)
        guard custom != task.customTitle else { return }
        update(task) { $0.customTitle = custom }
    }

    /// Saves a task's title and description together (the dashboard's page): one
    /// change, one event. A nil or empty title follows the text again. Nothing is
    /// saved that would leave the task without any title at all.
    func update(_ task: TaskItem, title: String?, text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : TaskText.customTitle($0, for: cleaned) }
        guard custom != nil || !TaskText.title(of: cleaned).isEmpty else { return }
        guard custom != task.customTitle || cleaned != task.text else { return }
        update(task) {
            $0.text = cleaned
            $0.customTitle = custom
        }
    }

    func move(_ task: TaskItem, to projectID: UUID?) {
        if let reason = moveRefusal(task, to: projectID) {
            FeedbackHUD.show("Not moved", symbol: "arrow.uturn.backward", subtitle: reason)
            return
        }
        update(task) { $0.projectID = projectID }
    }

    func delete(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let gone = tasks.remove(at: index)
        if let remote = gone.remote {
            // Cue never deletes a task on the website: it only stops showing it here,
            // until it changes there again.
            onOrgDeleted(gone, remote)
            save()
            return
        }
        deletedIDs.append(gone.id)
        save()
        onEvent(.deleted(gone))
    }

    private func update(_ task: TaskItem, event: (TaskItem) -> TaskEvent = TaskEvent.updated, _ change: (inout TaskItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        change(&tasks[index])
        tasks[index].updatedAt = .now
        save()
        onEvent(event(tasks[index]))
    }

    // MARK: - Organizations

    /// An organization's task was deleted here (it stays on the website).
    @ObservationIgnored var onOrgDeleted: (TaskItem, RemoteLink) -> Void = { _, _ in }

    /// The organization project a project sits in, itself included: the board, or the root.
    func orgProject(_ id: UUID?) -> TaskProject? {
        var current = project(id)
        while let project = current {
            if project.isOrg { return project }
            current = self.project(project.parentID)
        }
        return nil
    }

    /// Whether a task belongs to a connected organization (and so goes to its website).
    func isOrgTask(_ task: TaskItem) -> Bool {
        task.remote != nil || orgProject(task.projectID) != nil
    }

    /// The organization's projects as the website has them now: made, renamed, moved,
    /// and those it no longer has removed (their tasks go with them). Not announced, not
    /// pushed back.
    func replaceOrgProjects(_ wanted: [TaskProject], source: String) {
        applyingRemote = true
        defer { applyingRemote = false }
        let keep = Set(wanted.map(\.id))
        let gone = Set(projects.filter { $0.org?.source == source && !keep.contains($0.id) }.map(\.id))
        projects.removeAll { gone.contains($0.id) }
        if !gone.isEmpty {
            // the website's tasks go with their board; one made here and never sent stays, as a local task
            tasks.removeAll { task in (task.projectID.map(gone.contains) ?? false) && task.remote?.taskID != nil }
            for index in tasks.indices where tasks[index].projectID.map(gone.contains) ?? false {
                tasks[index].projectID = nil
                tasks[index].remote = nil
            }
        }
        for project in wanted {
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                if projects[index] != project { projects[index] = project }
            } else {
                projects.append(project)
            }
        }
        save()
    }

    /// Writes tasks the sync worked out (taken from the website, or answered by it)
    /// without announcing them or pushing them back. `remove`: ids that left.
    func applyOrgTasks(_ changed: [TaskItem], remove: Set<UUID> = []) {
        guard !changed.isEmpty || !remove.isEmpty else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        if !remove.isEmpty { tasks.removeAll { remove.contains($0.id) } }
        for var task in changed {
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                // The website's copy carries none of what only Cue keeps; it stays.
                task.keepLocal(from: tasks[index])
                tasks[index] = task
            } else {
                tasks.insert(task, at: 0)
            }
        }
        tasks.sort { $0.createdAt > $1.createdAt }
        save()
    }

    /// Everything of one organization, when it is disconnected.
    func removeOrg(source: String) {
        applyingRemote = true
        defer { applyingRemote = false }
        let ids = Set(projects.filter { $0.org?.source == source }.map(\.id))
        projects.removeAll { ids.contains($0.id) }
        tasks.removeAll { task in task.remote?.source == source || (task.projectID.map(ids.contains) ?? false) }
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(File(projects: projects, tasks: tasks, deleted: deletedIDs)) else { return }
        file.write(data)
        if !applyingRemote {
            onChanged()
            onLocalChange()
        }
    }
}
