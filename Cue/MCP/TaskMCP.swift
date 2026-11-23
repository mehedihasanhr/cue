import Foundation
import UserNotifications

/// The Model Context Protocol, as Cue speaks it to AI agents: the task list, to read and
/// to work through.
///
/// The tools cover the whole way work moves: tasks and their steps (a plan), who does
/// them, what they wait on, the commits and pull requests that prove them, review and a
/// summary of the day. An agent archives a task rather than delete it, unless asked,
/// and a task on the website is never deleted there. Every change goes through `TaskStore`'s own methods, so it saves, syncs, fires
/// webhooks and shows in the dashboard exactly as a change made by hand does.
///
/// Messages are JSON-RPC 2.0, handled one at a time on the main actor; see `MCPServer`.
final class TaskMCP {
    private let store: TaskStore

    /// Hears which agent a session belongs to, from what it says about itself when it
    /// connects — for Settings › MCP's list of who is connected.
    var onClient: (_ session: UUID, _ name: String, _ version: String?) -> Void = { _, _, _ in }

    init(store: TaskStore) {
        self.store = store
    }

    /// Protocol versions this server can speak, newest first. A client asking for one of
    /// them gets it; any other gets the newest, and decides for itself whether to go on.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    // MARK: - JSON-RPC

    /// The reply to one message, or nil when it was a notification.
    func handle(_ data: Data, session: UUID = UUID()) -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        // A notification (no id) gets no reply, whatever it says.
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            let result = try respond(to: method, params: params, session: session)
            return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch {
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
        }
    }

    struct RPCError: Error {
        var code: Int
        var message: String
        static func methodNotFound(_ method: String) -> RPCError { RPCError(code: -32601, message: "Method not found: \(method)") }
        static func invalidParams(_ message: String) -> RPCError { RPCError(code: -32602, message: message) }
    }

    private func respond(to method: String, params: [String: Any], session: UUID) throws(RPCError) -> [String: Any] {
        switch method {
        case "initialize":
            let client = params["clientInfo"] as? [String: Any]
            onClient(session, client?["title"] as? String ?? client?["name"] as? String ?? "An MCP client", client?["version"] as? String)
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "cue", "title": "Cue Tasks", "version": Self.appVersion],
                "instructions": Self.instructions,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": Self.tools]
        case "tools/call":
            guard let name = params["name"] as? String else { throw .invalidParams("tools/call needs a name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return call(name, arguments)
        default:
            throw .methodNotFound(method)
        }
    }

    /// A tool's result. A tool that fails says so in its result (`isError`), not as a
    /// protocol error: the model reads it and can try again differently.
    private func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let outcome: Result<Any, ToolError>
        switch name {
        case "list_tasks": outcome = listTasks(arguments)
        case "get_task": outcome = getTask(arguments)
        case "list_projects": outcome = .success(["projects": store.projects.map(projectJSON)])
        case "create_task": outcome = createTask(arguments)
        case "update_task": outcome = updateTask(arguments)
        case "add_note": outcome = addNote(arguments)
        case "move_task": outcome = moveTask(arguments)
        case "archive_task": outcome = archiveTask(arguments)
        case "list_people": outcome = listPeople()
        case "list_subtasks": outcome = listSubtasks(arguments)
        case "create_plan": outcome = createPlan(arguments)
        case "add_checklist": outcome = addChecklist(arguments)
        case "check_item": outcome = checkItem(arguments)
        case "link_task": outcome = linkTask(arguments)
        case "find_by_link": outcome = findByLink(arguments)
        case "search_tasks": outcome = searchTasks(arguments)
        case "list_labels": outcome = listLabels()
        case "summary", "my_day": outcome = summary(arguments)
        case "request_review": outcome = requestReview(arguments)
        case "complete_with_proof": outcome = completeWithProof(arguments)
        default: outcome = .failure(ToolError("Unknown tool: \(name)"))
        }
        switch outcome {
        case .success(let value):
            let text = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            var result: [String: Any] = ["content": [["type": "text", "text": text]]]
            if value is [String: Any] { result["structuredContent"] = value }
            return result
        case .failure(let error):
            return ["content": [["type": "text", "text": error.message]], "isError": true]
        }
    }

    struct ToolError: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: - Reading

    private func listTasks(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        var tasks = store.tasks.filter { arguments["include_archived"] as? Bool == true || !$0.isArchived }
        if let kind = Self.string(arguments["kind"]) {
            guard let wanted = TaskKind(rawValue: kind.lowercased()) else { return .failure(ToolError("Unknown kind \"\(kind)\". Use task or owner_step.")) }
            tasks = tasks.filter { $0.kind == wanted }
        }
        if let label = Self.string(arguments["label"]) {
            tasks = tasks.filter { $0.labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
        }
        if let parent = Self.string(arguments["parent_id"]) {
            switch task(parent) {
            case .success(let found): tasks = tasks.filter { $0.parentID == found.id }
            case .failure(let error): return .failure(error)
            }
        }
        // Statuses asked for; without any, everything still open.
        let statuses: Set<TaskStatus>
        switch arguments["status"] {
        case let name as String:
            guard let status = Self.status(named: name) else { return .failure(Self.badStatus(name)) }
            statuses = [status]
        case let names as [String]:
            var set = Set<TaskStatus>()
            for name in names {
                guard let status = Self.status(named: name) else { return .failure(Self.badStatus(name)) }
                set.insert(status)
            }
            statuses = set
        default:
            statuses = arguments["include_complete"] as? Bool == true
                ? Set(TaskStatus.allCases) : [.pending, .inProcess, .review]
        }
        tasks = tasks.filter { statuses.contains($0.status) }

        if let reference = Self.string(arguments["project"]) {
            if reference.lowercased() == "none" {
                tasks = tasks.filter { $0.projectID == nil }
            } else {
                guard let project = project(matching: reference) else {
                    return .failure(ToolError("No project called \"\(reference)\". list_projects shows them all."))
                }
                // A project includes the projects inside it, as in the dashboard's sidebar.
                let ids = store.descendants(of: project.id).union([project.id])
                tasks = tasks.filter { $0.projectID.map(ids.contains) ?? false }
            }
        }
        if let query = Self.string(arguments["query"])?.lowercased() {
            tasks = tasks.filter { $0.title.lowercased().contains(query) || $0.text.lowercased().contains(query) }
        }
        if let priority = Self.string(arguments["priority"]) {
            guard let wanted = TaskPriority(rawValue: priority.lowercased()) else {
                return .failure(ToolError("Unknown priority \"\(priority)\". Use urgent, high, medium or low."))
            }
            tasks = tasks.filter { $0.priority == wanted }
        }
        if let assignee = Self.string(arguments["assignee"]) {
            tasks = assignee.lowercased() == "none"
                ? tasks.filter { $0.assignee == nil }
                : tasks.filter { $0.assignee?.caseInsensitiveCompare(assignee) == .orderedSame }
        }

        // The dashboard's order: by status, then priority, newest first within each.
        let statusOrder = Dictionary(uniqueKeysWithValues: TaskStatus.allCases.enumerated().map { ($1, $0) })
        let priorityOrder = Dictionary(uniqueKeysWithValues: TaskPriority.allCases.enumerated().map { ($1, $0) })
        tasks.sort {
            if $0.status != $1.status { return statusOrder[$0.status]! < statusOrder[$1.status]! }
            if $0.priority != $1.priority { return priorityOrder[$0.priority]! < priorityOrder[$1.priority]! }
            return $0.createdAt > $1.createdAt
        }
        let total = tasks.count
        let limit = min(max(arguments["limit"] as? Int ?? 50, 1), 500)
        return .success([
            "total": total,
            "shown": min(total, limit),
            "tasks": tasks.prefix(limit).map { taskJSON($0, full: false) },
        ])
    }

    private func getTask(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        task(arguments["id"]).map { taskJSON($0, full: true) as Any }
    }

    // MARK: - Changing

    /// What `create_task`, `update_task` and `create_plan` can set besides the title,
    /// status, priority and project, read and checked before anything changes. A key left
    /// out is left alone; "none" (or an empty list) clears it.
    private struct Fields {
        var assignee: String??
        var due: Date??
        var labels: [String]?
        var parent: UUID??
        var blockedBy: [UUID]?
        var kind: TaskKind?
        var doneWhen: String??
        var sessionID: String??
        var links: [TaskLink] = []
        var checklist: [String] = []

        var isEmpty: Bool {
            assignee == nil && due == nil && labels == nil && parent == nil && blockedBy == nil && kind == nil
                && doneWhen == nil && sessionID == nil && links.isEmpty && checklist.isEmpty
        }
    }

    private func fields(_ arguments: [String: Any], for task: TaskItem? = nil) -> Result<Fields, ToolError> {
        var fields = Fields()
        func clearable(_ key: String) -> String?? {
            guard arguments.keys.contains(key) else { return .none }
            return .some(Self.string(arguments[key]).flatMap { $0.lowercased() == "none" ? nil : $0 })
        }
        fields.assignee = clearable("assignee")
        fields.doneWhen = clearable("done_when")
        fields.sessionID = clearable("session_id")
        if case .some(let due) = clearable("due") {
            if let due {
                guard let date = Self.date(due) else { return .failure(ToolError("due \"\(due)\" is not a date. Use YYYY-MM-DD, or none.")) }
                fields.due = .some(date)
            } else {
                fields.due = .some(nil)
            }
        }
        if arguments.keys.contains("labels") {
            fields.labels = Self.strings(arguments["labels"]).filter { $0.lowercased() != "none" }
        }
        if let kind = Self.string(arguments["kind"]) {
            guard let value = TaskKind(rawValue: kind.lowercased()) else { return .failure(ToolError("Unknown kind \"\(kind)\". Use task or owner_step.")) }
            fields.kind = value
        }
        if case .some(let parent) = clearable("parent_id") {
            if let parent {
                switch self.task(parent) {
                case .success(let found):
                    if let task, found.id == task.id || isStep(found, of: task) {
                        return .failure(ToolError("A task can't be a step of itself or of one of its own steps."))
                    }
                    fields.parent = .some(found.id)
                case .failure(let error): return .failure(error)
                }
            } else {
                fields.parent = .some(nil)
            }
        }
        if arguments.keys.contains("blocked_by") {
            var ids: [UUID] = []
            for reference in Self.strings(arguments["blocked_by"]) where reference.lowercased() != "none" {
                switch self.task(reference) {
                case .success(let found):
                    if found.id == task?.id { return .failure(ToolError("A task can't wait on itself.")) }
                    ids.append(found.id)
                case .failure(let error): return .failure(error)
                }
            }
            fields.blockedBy = ids
        }
        if let links = arguments["links"] {
            for raw in (links as? [Any]) ?? [links] {
                switch Self.link(raw) {
                case .success(let link): fields.links.append(link)
                case .failure(let error): return .failure(error)
                }
            }
        }
        fields.checklist = Self.strings(arguments["checklist"])
        return .success(fields)
    }

    /// Whether `task` is among `parent`'s steps, however deep.
    private func isStep(_ task: TaskItem, of parent: TaskItem) -> Bool {
        var next = task.parentID
        var seen = Set<UUID>()
        while let id = next, seen.insert(id).inserted {
            if id == parent.id { return true }
            next = store.tasks.first { $0.id == id }?.parentID
        }
        return false
    }

    /// Writes what `fields` holds onto the task: the assignee as the dashboard sets it,
    /// the rest as one change.
    private func apply(_ fields: Fields, to task: TaskItem) {
        if case .some(let assignee) = fields.assignee { store.setAssignee(assignee, for: current(task)) }
        var rest = fields
        rest.assignee = nil
        guard !rest.isEmpty else { return }
        store.edit(current(task)) { task in
            if case .some(let due) = fields.due { task.due = due }
            if let labels = fields.labels { task.labels = Self.unique(labels) }
            if case .some(let parent) = fields.parent { task.parentID = parent }
            if let blockedBy = fields.blockedBy { task.blockedBy = blockedBy }
            if let kind = fields.kind { task.kind = kind }
            if case .some(let doneWhen) = fields.doneWhen { task.doneWhen = doneWhen }
            if case .some(let session) = fields.sessionID { task.sessionID = session }
            for link in fields.links where !task.links.contains(where: { $0.kind == link.kind && $0.target == link.target }) {
                task.links.append(link)
            }
            task.checklist += fields.checklist.map { ChecklistItem(text: $0) }
        }
    }

    /// The task as the store has it now (after earlier changes in the same call).
    private func current(_ task: TaskItem) -> TaskItem { store.tasks.first { $0.id == task.id } ?? task }

    private func priority(_ arguments: [String: Any]) -> Result<TaskPriority?, ToolError> {
        guard let name = Self.string(arguments["priority"]) else { return .success(nil) }
        guard let value = TaskPriority(rawValue: name.lowercased()) else {
            return .failure(ToolError("Unknown priority \"\(name)\". Use urgent, high, medium or low."))
        }
        return .success(value)
    }

    /// Where a task should go: a project by name or id (made when there is none), or no
    /// project for "none"; `.none` when no project was named. Fails for a move Sensory OS
    /// can't take, rather than make it and have the next sync undo it.
    private func projectChange(_ arguments: [String: Any], for task: TaskItem?) -> Result<UUID??, ToolError> {
        guard arguments.keys.contains("project") else { return .success(.none) }
        let reference = Self.string(arguments["project"])
        let target: UUID? = reference.flatMap { $0.lowercased() == "none" ? nil : projectCreatingIfNeeded($0)?.id }
        if let task, let reason = store.moveRefusal(task, to: target) { return .failure(ToolError(reason)) }
        return .success(.some(target))
    }

    private func createTask(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        guard let title = Self.string(arguments["title"]) else { return .failure(ToolError("create_task needs a title")) }
        let priority: TaskPriority?
        switch self.priority(arguments) {
        case .success(let value): priority = value
        case .failure(let error): return .failure(error)
        }
        var status: TaskStatus?
        if let name = Self.string(arguments["status"]) {
            guard let value = Self.status(named: name) else { return .failure(Self.badStatus(name)) }
            status = value
        }
        let fields: Fields
        switch self.fields(arguments) {
        case .success(let value): fields = value
        case .failure(let error): return .failure(error)
        }
        // A step goes where its task is, unless a project is named.
        var projectID = Self.string(arguments["project"]).flatMap { projectCreatingIfNeeded($0)?.id }
        if projectID == nil, case .some(.some(let parent)) = fields.parent {
            projectID = store.tasks.first { $0.id == parent }?.projectID
        }
        guard let task = store.addTask(titled: title, notes: arguments["notes"] as? String ?? "", in: projectID, priority: priority ?? .medium) else {
            return .failure(ToolError("The task was not added: its title is empty."))
        }
        if let status { store.setStatus(status, for: task) }
        apply(fields, to: task)
        return .success(taskJSON(current(task), full: true))
    }

    private func updateTask(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        let task: TaskItem
        switch self.task(arguments["id"]) {
        case .success(let found): task = found
        case .failure(let error): return .failure(error)
        }
        // Everything is checked before anything changes, so a bad argument changes nothing,
        // and only what is named changes: a status alone leaves the project where it is.
        var status: TaskStatus?
        if let name = Self.string(arguments["status"]) {
            guard let value = Self.status(named: name) else { return .failure(Self.badStatus(name)) }
            status = value
        }
        let priority: TaskPriority?
        switch self.priority(arguments) {
        case .success(let value): priority = value
        case .failure(let error): return .failure(error)
        }
        let title = Self.string(arguments["title"])
        let projectChange: UUID??
        switch self.projectChange(arguments, for: task) {
        case .success(let value): projectChange = value
        case .failure(let error): return .failure(error)
        }
        let fields: Fields
        switch self.fields(arguments, for: task) {
        case .success(let value): fields = value
        case .failure(let error): return .failure(error)
        }
        guard status != nil || priority != nil || title != nil || projectChange != nil || !fields.isEmpty else {
            return .failure(ToolError("Nothing to change: give a status, priority, title, project, assignee, due date, labels or another field."))
        }

        if let title { store.rename(current(task), to: title) }
        if let status, status != current(task).status { store.setStatus(status, for: current(task)) }
        if let priority, priority != current(task).priority { store.setPriority(priority, for: current(task)) }
        if case .some(let projectID) = projectChange, projectID != current(task).projectID { store.move(current(task), to: projectID) }
        apply(fields, to: task)
        return .success(taskJSON(current(task), full: true))
    }

    /// To another project (its steps with it), or out of any with "none".
    private func moveTask(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        let task: TaskItem
        switch self.task(arguments["id"]) {
        case .success(let found): task = found
        case .failure(let error): return .failure(error)
        }
        guard arguments.keys.contains("project") else { return .failure(ToolError("move_task needs a project: a name, an id, or none.")) }
        let target: UUID??
        switch projectChange(arguments, for: task) {
        case .success(let value): target = value
        case .failure(let error): return .failure(error)
        }
        guard case .some(let projectID) = target else { return .failure(ToolError("move_task needs a project.")) }
        let leavesWebsite = task.remote?.taskID != nil && store.orgProject(projectID) == nil
        store.move(task, to: projectID)
        for step in store.subtasks(of: task) where store.moveRefusal(step, to: projectID) == nil {
            store.move(step, to: projectID)
        }
        var json = taskJSON(current(task), full: false)
        if leavesWebsite {
            json["note"] = "It is out of the organization now: Cue keeps it as a task of its own, and the website keeps its copy as it was."
        }
        return .success(json)
    }

    /// Out of the lists (kept, and back with restore), or deleted with delete.
    private func archiveTask(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        let task: TaskItem
        switch self.task(arguments["id"]) {
        case .success(let found): task = found
        case .failure(let error): return .failure(error)
        }
        if arguments["restore"] as? Bool == true {
            store.setArchived(false, for: task)
            for step in store.subtasks(of: task) { store.setArchived(false, for: step) }
            return .success(taskJSON(current(task), full: false))
        }
        if arguments["delete"] as? Bool == true {
            let onWebsite = task.remote?.taskID != nil
            store.delete(task)
            return .success(["deleted": task.title,
                             "note": onWebsite ? "Gone from Cue; the website keeps it." : "Deleted for good."])
        }
        store.setArchived(true, for: task)
        for step in store.subtasks(of: task) { store.setArchived(true, for: step) }
        return .success(taskJSON(current(task), full: false))
    }

    /// The names tasks can be assigned to: those used so far, most open tasks first.
    private func listPeople() -> Result<Any, ToolError> {
        let people = store.assignees.map { name -> [String: Any] in
            let theirs = store.tasks.filter { $0.assignee == name && !$0.isArchived }
            return ["name": name, "open": theirs.filter { $0.status != .complete }.count]
        }
        return .success(["people": people,
                         "note": "Names already used in Cue. Sensory OS does not share its team with Cue yet, so any new name can be assigned too."])
    }

    private func listLabels() -> Result<Any, ToolError> {
        .success(["labels": store.labels.map { label -> [String: Any] in
            ["name": label, "tasks": store.tasks.filter { !$0.isArchived && $0.labels.contains(label) }.count]
        }])
    }

    // MARK: - Steps, plans, checklists

    private func listSubtasks(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        task(arguments["id"]).map { parent in
            let steps = store.subtasks(of: parent).filter { arguments["include_archived"] as? Bool == true || !$0.isArchived }
            return ["parent": taskJSON(parent, full: false),
                    "done": steps.filter { $0.status == .complete }.count,
                    "subtasks": steps.map { taskJSON($0, full: false) }] as [String: Any]
        }
    }

    /// A feature and its steps in one call: the feature as a task, each step a task of it
    /// with what "done" looks like. In order (the default), each step waits on the last.
    private func createPlan(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        guard Self.string(arguments["title"]) != nil else { return .failure(ToolError("create_plan needs a title")) }
        guard let steps = arguments["steps"] as? [Any], !steps.isEmpty else {
            return .failure(ToolError("create_plan needs steps: a list of {title, done_when}."))
        }
        // Every step checked before anything is made.
        var parsed: [(title: String, notes: String, fields: Fields, priority: TaskPriority?)] = []
        for (index, raw) in steps.enumerated() {
            var step = (raw as? [String: Any]) ?? (raw as? String).map { ["title": $0] } ?? [:]
            guard let title = Self.string(step["title"]) else { return .failure(ToolError("Step \(index + 1) has no title.")) }
            if step["assignee"] == nil, let assignee = arguments["assignee"] { step["assignee"] = assignee }
            if step["labels"] == nil, let labels = arguments["labels"] { step["labels"] = labels }
            step["parent_id"] = nil
            let fields: Fields
            switch self.fields(step) {
            case .success(let value): fields = value
            case .failure(let error): return .failure(ToolError("Step \(index + 1): \(error.message)"))
            }
            let priority: TaskPriority?
            switch self.priority(step) {
            case .success(let value): priority = value
            case .failure(let error): return .failure(ToolError("Step \(index + 1): \(error.message)"))
            }
            parsed.append((title, step["notes"] as? String ?? "", fields, priority))
        }
        var featureArguments = arguments
        featureArguments["steps"] = nil
        featureArguments["sequential"] = nil
        let feature: TaskItem
        switch createTask(featureArguments) {
        case .success(let json):
            guard let id = (json as? [String: Any])?["id"] as? String, case .success(let found) = task(id) else {
                return .failure(ToolError("The plan's task was not added."))
            }
            feature = found
        case .failure(let error): return .failure(error)
        }
        let sequential = arguments["sequential"] as? Bool ?? true
        var previous: TaskItem?
        var made: [TaskItem] = []
        for step in parsed {
            guard let task = store.addTask(titled: step.title, notes: step.notes, in: feature.projectID,
                                           priority: step.priority ?? feature.priority) else { continue }
            var fields = step.fields
            fields.parent = .some(feature.id)
            if sequential, fields.blockedBy == nil, let previous { fields.blockedBy = [previous.id] }
            apply(fields, to: task)
            previous = task
            made.append(current(task))
        }
        return .success(["plan": taskJSON(current(feature), full: true), "steps": made.map { taskJSON($0, full: false) }])
    }

    private func addChecklist(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        let task: TaskItem
        switch self.task(arguments["id"]) {
        case .success(let found): task = found
        case .failure(let error): return .failure(error)
        }
        let items = Self.strings(arguments["items"])
        guard !items.isEmpty else { return .failure(ToolError("add_checklist needs items: a list of short steps.")) }
        store.edit(task) { $0.checklist += items.map { ChecklistItem(text: $0) } }
        return .success(taskJSON(current(task), full: true))
    }

    /// Ticks (or with done false, unticks) one item: by its number from 1, or its words.
    private func checkItem(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        let task: TaskItem
        switch self.task(arguments["id"]) {
        case .success(let found): task = found
        case .failure(let error): return .failure(error)
        }
        let reference = arguments["item"].map { "\($0)" }?.trimmingCharacters(in: .whitespaces) ?? ""
        let index: Int? = {
            if let number = Int(reference) { return task.checklist.indices.contains(number - 1) ? number - 1 : nil }
            if let id = UUID(uuidString: reference) { return task.checklist.firstIndex { $0.id == id } }
            return task.checklist.firstIndex { $0.text.caseInsensitiveCompare(reference) == .orderedSame }
                ?? task.checklist.firstIndex { $0.text.localizedCaseInsensitiveContains(reference) }
        }()
        guard !reference.isEmpty, let index else {
            return .failure(ToolError("No checklist item \"\(reference)\". get_task lists them, numbered from 1."))
        }
        let done = arguments["done"] as? Bool ?? true
        store.edit(task) { $0.checklist[index].done = done }
        return .success(taskJSON(current(task), full: true))
    }

    // MARK: - Links

    private func linkTask(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        let task: TaskItem
        switch self.task(arguments["id"]) {
        case .success(let found): task = found
        case .failure(let error): return .failure(error)
        }
        var fields = Fields()
        switch Self.link(arguments) {
        case .success(let link): fields.links = [link]
        case .failure(let error): return .failure(error)
        }
        apply(fields, to: task)
        return .success(taskJSON(current(task), full: true))
    }

    /// Tasks tied to a pull request ("#592" or its URL), a commit (its hash, 7 characters
    /// or more), a branch or a page.
    private func findByLink(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        guard let query = Self.string(arguments["link"]) ?? Self.string(arguments["target"]) else {
            return .failure(ToolError("find_by_link needs a link: a URL, \"#592\", a commit hash or a branch."))
        }
        let wanted = query.lowercased()
        let number = wanted.hasPrefix("#") ? String(wanted.dropFirst()) : nil
        let found = store.tasks.filter { task in
            task.links.contains { link in
                let target = link.target.lowercased()
                if let number { return link.kind == .pr && (target.hasSuffix("/" + number) || target == number || link.label == "#" + number) }
                if target == wanted { return true }
                // A commit by its hash, short or long, whether the link is the hash or its URL.
                if link.kind == .commit {
                    let hash = target.split(separator: "/").last.map(String.init) ?? target
                    let given = wanted.split(separator: "/").last.map(String.init) ?? wanted
                    if min(hash.count, given.count) >= 7, hash.hasPrefix(given) || given.hasPrefix(hash) { return true }
                }
                return wanted.count >= 10 && target.contains(wanted)
            }
        }
        return .success(["tasks": found.map { taskJSON($0, full: false) }])
    }

    // MARK: - Finding and reporting

    private func searchTasks(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        var tasks = store.tasks.filter { arguments["include_archived"] as? Bool == true || !$0.isArchived }
        if let text = Self.string(arguments["text"]) {
            tasks = tasks.filter { TaskDashboardQuery.matches($0, query: text) || $0.labels.contains { $0.localizedCaseInsensitiveContains(text) } }
        }
        let statuses = Self.strings(arguments["status"])
        if !statuses.isEmpty {
            var wanted = Set<TaskStatus>()
            for name in statuses {
                guard let status = Self.status(named: name) else { return .failure(Self.badStatus(name)) }
                wanted.insert(status)
            }
            tasks = tasks.filter { wanted.contains($0.status) }
        }
        if let assignee = Self.string(arguments["assignee"]) {
            tasks = assignee.lowercased() == "none"
                ? tasks.filter { $0.assignee == nil }
                : tasks.filter { $0.assignee?.caseInsensitiveCompare(assignee) == .orderedSame }
        }
        if let reference = Self.string(arguments["project"]) {
            guard let project = project(matching: reference) else { return .failure(ToolError("No project called \"\(reference)\". list_projects shows them all.")) }
            let ids = store.descendants(of: project.id).union([project.id])
            tasks = tasks.filter { $0.projectID.map(ids.contains) ?? false }
        }
        for label in Self.strings(arguments["label"]) {
            tasks = tasks.filter { $0.labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
        }
        if let since = Self.string(arguments["updated_since"]) {
            guard let date = Self.date(since) else { return .failure(ToolError("updated_since \"\(since)\" is not a date or time.")) }
            tasks = tasks.filter { $0.updatedAt >= date }
        }
        if let kind = Self.string(arguments["kind"]) {
            guard let wanted = TaskKind(rawValue: kind.lowercased()) else { return .failure(ToolError("Unknown kind \"\(kind)\". Use task or owner_step.")) }
            tasks = tasks.filter { $0.kind == wanted }
        }
        tasks.sort { $0.updatedAt > $1.updatedAt }
        let limit = min(max(arguments["limit"] as? Int ?? 50, 1), 500)
        return .success(["total": tasks.count, "shown": min(tasks.count, limit), "tasks": tasks.prefix(limit).map { taskJSON($0, full: false) }])
    }

    /// The day so far: in progress, in review, blocked, waiting on the owner, and done since
    /// the start of the day (or `since`), as lists and as Markdown ready to post.
    private func summary(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        let since: Date
        if let given = Self.string(arguments["since"]) {
            guard let date = Self.date(given) else { return .failure(ToolError("since \"\(given)\" is not a date or time.")) }
            since = date
        } else {
            since = Calendar.current.startOfDay(for: .now)
        }
        var tasks = store.tasks.filter { !$0.isArchived }
        if let assignee = Self.string(arguments["assignee"]) {
            tasks = tasks.filter { $0.assignee?.caseInsensitiveCompare(assignee) == .orderedSame }
        }
        let blocked = tasks.filter { $0.status != .complete && !store.blockers(of: $0).isEmpty }
        let blockedIDs = Set(blocked.map(\.id))
        let sections: [(key: String, heading: String, tasks: [TaskItem])] = [
            ("in_progress", "In progress", tasks.filter { $0.status == .inProcess && !blockedIDs.contains($0.id) }),
            ("in_review", "In review", tasks.filter { $0.status == .review }),
            ("blocked", "Blocked", blocked),
            ("waiting_on_you", "Waiting on you", tasks.filter { $0.kind == .ownerStep && $0.status != .complete }),
            ("done", "Done", tasks.filter { $0.status == .complete && $0.updatedAt >= since }),
        ]
        var markdown = "## \(since.formatted(date: .abbreviated, time: .omitted))\n"
        var json: [String: Any] = ["since": Self.dates.string(from: since)]
        for section in sections {
            json[section.key] = section.tasks.map { taskJSON($0, full: false) }
            guard !section.tasks.isEmpty else { continue }
            markdown += "\n**\(section.heading)**\n"
            for task in section.tasks {
                var line = "- \(task.title)"
                if let assignee = task.assignee { line += " (\(assignee))" }
                if section.key == "blocked" { line += ", waiting on " + store.blockers(of: task).map(\.title).joined(separator: ", ") }
                if let proof = task.links.last(where: \.isProof) { line += " [\(proof.label)](\(proof.target))" }
                markdown += line + "\n"
            }
        }
        if sections.allSatisfy({ $0.tasks.isEmpty }) { markdown += "\nNothing in progress, in review, blocked or done yet.\n" }
        json["markdown"] = markdown
        return .success(json)
    }

    // MARK: - Review

    /// Any link given in the call (link, or target/url with kind and title), checked.
    private func givenLinks(_ arguments: [String: Any]) -> Result<[TaskLink], ToolError> {
        let raw: Any? = arguments["link"] ?? (arguments["target"] != nil || arguments["url"] != nil ? arguments : nil)
        guard let raw else { return .success([]) }
        return Self.link(raw).map { [$0] }
    }

    /// In review, with what shows the work attached, and a notification for the person.
    private func requestReview(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        let task: TaskItem
        switch self.task(arguments["id"]) {
        case .success(let found): task = found
        case .failure(let error): return .failure(error)
        }
        var fields = Fields()
        switch givenLinks(arguments) {
        case .success(let links): fields.links = links
        case .failure(let error): return .failure(error)
        }
        apply(fields, to: task)
        if let note = Self.string(arguments["note"]) {
            let now = current(task)
            store.update(now, title: now.customTitle, text: now.text + "\n\n" + note)
        }
        store.setStatus(.review, for: current(task))
        let reviewed = current(task)
        Self.notify(id: "cue.review.\(task.id.uuidString)", title: "Ready for review", body: reviewed.title,
                    url: reviewed.links.last?.url)
        return .success(taskJSON(reviewed, full: true))
    }

    /// Complete, only with a commit or pull request attached (now or before), so "done"
    /// always comes with what shows it; and not while it still waits on another task.
    private func completeWithProof(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        let task: TaskItem
        switch self.task(arguments["id"]) {
        case .success(let found): task = found
        case .failure(let error): return .failure(error)
        }
        var fields = Fields()
        switch givenLinks(arguments) {
        case .success(let links): fields.links = links
        case .failure(let error): return .failure(error)
        }
        guard (task.links + fields.links).contains(where: \.isProof) else {
            return .failure(ToolError("No proof yet: attach a commit or pull request (link_task, or kind and target here), then complete."))
        }
        let blockers = store.blockers(of: task)
        guard blockers.isEmpty else {
            return .failure(ToolError("It still waits on: " + blockers.map(\.title).joined(separator: ", ") + "."))
        }
        apply(fields, to: task)
        store.setStatus(.complete, for: current(task))
        return .success(taskJSON(current(task), full: true))
    }

    private static func notify(id: String, title: String, body: String, url: URL?) {
        FeedbackHUD.show(title, symbol: "checkmark.seal", subtitle: body)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.subtitle = "Cue"
        content.sound = .default
        // A "cue." id is Cue's own: a click opens the link, and the website is told nothing.
        var info: [String: String] = ["id": id]
        if let url { info["url"] = url.absoluteString }
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func addNote(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        let task: TaskItem
        switch self.task(arguments["id"]) {
        case .success(let found): task = found
        case .failure(let error): return .failure(error)
        }
        guard let note = Self.string(arguments["text"]) else { return .failure(ToolError("add_note needs some text")) }
        // Added at the end, as its own paragraph: what was written stays as it was.
        store.update(task, title: task.customTitle, text: task.text + "\n\n" + note)
        return .success(taskJSON(store.tasks.first { $0.id == task.id } ?? task, full: true))
    }

    // MARK: - Finding

    /// A task by its id, or by the start of one (as long as only one task starts so).
    private func task(_ reference: Any?) -> Result<TaskItem, ToolError> {
        guard let reference = Self.string(reference)?.lowercased() else { return .failure(ToolError("Give the task's id")) }
        if let uuid = UUID(uuidString: reference), let task = store.tasks.first(where: { $0.id == uuid }) { return .success(task) }
        guard reference.count >= 4 else { return .failure(ToolError("No task with id \"\(reference)\"")) }
        let matches = store.tasks.filter { $0.id.uuidString.lowercased().hasPrefix(reference) }
        switch matches.count {
        case 1: return .success(matches[0])
        case 0: return .failure(ToolError("No task with id \"\(reference)\". list_tasks shows the ids."))
        default: return .failure(ToolError("\"\(reference)\" is the start of \(matches.count) tasks' ids; give more of it."))
        }
    }

    /// A project by id, or by name — any case, spaces ignored, as `#project` matches.
    private func project(matching reference: String) -> TaskProject? {
        if let uuid = UUID(uuidString: reference) { return store.project(uuid) }
        let key = TaskTokens.compact(reference)
        return store.projects.first { TaskTokens.compact($0.name) == key }
    }

    /// As `project(matching:)`, making a top-level project of that name when there is
    /// none — the rule `cue://task/new` and imports follow.
    private func projectCreatingIfNeeded(_ reference: String) -> TaskProject? {
        project(matching: reference) ?? store.addProject(named: reference)
    }

    // MARK: - JSON

    private func taskJSON(_ task: TaskItem, full: Bool) -> [String: Any] {
        var json: [String: Any] = [
            "id": task.id.uuidString.lowercased(),
            "title": task.title,
            "status": Self.name(of: task.status),
            "priority": task.priority.rawValue,
            "assignee": task.assignee ?? NSNull(),
            "createdAt": Self.dates.string(from: task.createdAt),
            "updatedAt": Self.dates.string(from: task.updatedAt),
        ]
        if let projectID = task.projectID, let project = store.project(projectID) {
            json["project"] = store.path(to: projectID).map(\.name).joined(separator: " / ")
            json["projectID"] = project.id.uuidString.lowercased()
        }
        if task.kind != .task { json["kind"] = task.kind.rawValue }
        if task.isArchived { json["archived"] = true }
        if let due = task.due { json["due"] = Self.day.string(from: due) }
        if !task.labels.isEmpty { json["labels"] = task.labels }
        if let parent = task.parentID { json["parent_id"] = parent.uuidString.lowercased() }
        if !task.blockedBy.isEmpty {
            json["blocked_by"] = task.blockedBy.map { $0.uuidString.lowercased() }
            json["blocked"] = !store.blockers(of: task).isEmpty
        }
        if let doneWhen = task.doneWhen { json["done_when"] = doneWhen }
        if let session = task.sessionID { json["session_id"] = session }
        if !task.links.isEmpty {
            json["links"] = task.links.map { ["kind": $0.kind.rawValue, "target": $0.target, "label": $0.label] }
        }
        if !task.checklist.isEmpty {
            json["checklist"] = task.checklist.enumerated().map { ["item": $0.offset + 1, "text": $0.element.text, "done": $0.element.done] as [String: Any] }
        }
        let steps = store.subtasks(of: task)
        if !steps.isEmpty { json["subtasks"] = ["total": steps.count, "done": steps.filter { $0.status == .complete }.count] }
        if full {
            json["text"] = task.text
        } else if !task.summary.isEmpty {
            json["summary"] = String(task.summary.prefix(200))
        }
        return json
    }

    private func projectJSON(_ project: TaskProject) -> [String: Any] {
        var json: [String: Any] = [
            "id": project.id.uuidString.lowercased(),
            "name": project.name,
            "path": store.path(to: project.id).map(\.name).joined(separator: " / "),
            "openTasks": store.tasks(in: project.id).filter { $0.status != .complete }.count,
        ]
        if let parentID = project.parentID { json["parentID"] = parentID.uuidString.lowercased() }
        return json
    }

    private static let dates = ISO8601DateFormatter()

    /// Status names as agents use them; `pending` is what the store calls To do.
    static func name(of status: TaskStatus) -> String {
        switch status {
        case .pending: "todo"
        case .inProcess: "in_process"
        case .review: "review"
        case .complete: "complete"
        }
    }

    /// Generous on purpose: a model writes "done", "in progress", "To do".
    static func status(named name: String) -> TaskStatus? {
        switch name.lowercased().filter({ $0.isLetter }) {
        case "todo", "pending", "open", "new": .pending
        case "inprocess", "inprogress", "doing", "started", "active": .inProcess
        case "review", "inreview": .review
        case "complete", "completed", "done", "closed", "finished": .complete
        default: nil
        }
    }

    private static func badStatus(_ name: String) -> ToolError {
        ToolError("Unknown status \"\(name)\". Use todo, in_process, review or complete.")
    }

    /// A list of strings from a list or from one string ("a, b" is two).
    private static func strings(_ value: Any?) -> [String] {
        let raw: [String] = (value as? [Any])?.compactMap { $0 as? String }
            ?? (value as? String).map { $0.split(separator: ",").map(String.init) } ?? []
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// "2026-11-24", an ISO 8601 time, or today, tomorrow, yesterday.
    static func date(_ text: String) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        switch text.lowercased() {
        case "today": return today
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
        default:
            if let date = day.date(from: text) ?? dates.date(from: text) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: text)
        }
    }

    /// A link from {kind, target, title} (or url for target), or from a bare string; its
    /// kind is worked out from the target when not given.
    static func link(_ raw: Any) -> Result<TaskLink, ToolError> {
        let object = (raw as? [String: Any]) ?? (raw as? String).map { ["target": $0] } ?? [:]
        guard let target = string(object["target"]) ?? string(object["url"]) ?? string(object["link"]) else {
            return .failure(ToolError("A link needs a target: a URL, a commit hash, a branch or a file path."))
        }
        let kind: TaskLink.Kind
        if let name = string(object["kind"]) {
            guard let value = TaskLink.Kind(rawValue: name.lowercased()) else {
                return .failure(ToolError("Unknown link kind \"\(name)\". Use commit, pr, branch, plan, staging or url."))
            }
            kind = value
        } else if target.contains("/pull/") || target.contains("/merge_requests/") {
            kind = .pr
        } else if target.contains("/commit/") || target.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil {
            kind = .commit
        } else if target.hasPrefix("/") || target.hasPrefix("~") {
            kind = .plan
        } else if target.contains("staging") {
            kind = .staging
        } else {
            kind = .url
        }
        return .success(TaskLink(kind: kind, target: target, title: string(object["title"])))
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - What the agent is told

    static let instructions = """
    Cue is the user's task manager on this Mac. A task has a title, a Markdown description, \
    a status (todo, in_process, review, complete), a priority (urgent, high, medium, low), \
    an assignee (a name), labels, a due date and optionally a project; projects can nest. \
    A task can have steps (subtasks), a checklist, tasks it is blocked by, links (commits, \
    pull requests, branches, plan files, staging pages) and the Claude session that worked \
    on it. A step only the user can take is kind owner_step: it shows under "Waiting on you".

    The flow: a feature asked for → create_plan (the feature and its steps, each with \
    done_when). Starting a step → update_task status in_process with session_id. Something \
    only the user can do → create_task kind owner_step, and blocked_by on the step that waits. \
    Built → link_task the commit, then request_review. Shipped → link_task the pull request, \
    then complete_with_proof. End of day → summary.

    update_task changes only the fields it is given. list_tasks and search_tasks leave \
    archived tasks out unless asked. Archive a mistake (archive_task) rather than leave it; \
    delete only when asked to. Changes appear in Cue at once. Tasks from Sensory OS can't be \
    moved to another board from here.
    """

    static let tools: [[String: Any]] = {
        let statusSchema: [String: Any] = ["type": "string", "enum": ["todo", "in_process", "review", "complete"]]
        let prioritySchema: [String: Any] = ["type": "string", "enum": ["urgent", "high", "medium", "low"]]
        let kindSchema: [String: Any] = ["type": "string", "enum": ["task", "owner_step"],
                                         "description": "owner_step: a step only the user can take (it shows under Waiting on you)."]
        let id: [String: Any] = ["type": "string", "description": "The task's id from list_tasks (the first 8 characters are enough)."]
        let ids: [String: Any] = ["type": "array", "items": ["type": "string"], "description": "Task ids; an empty list or [\"none\"] clears."]
        let labels: [String: Any] = ["type": "array", "items": ["type": "string"], "description": "Labels, for example feature, bug, owner-step, waiting-on-meta. Replaces the task's labels."]
        let linkKind: [String: Any] = ["type": "string", "enum": ["commit", "pr", "branch", "plan", "staging", "url"]]
        let link: [String: Any] = ["type": "object", "properties": [
            "kind": linkKind,
            "target": ["type": "string", "description": "A URL, a commit hash, a branch name or a file path."],
            "title": ["type": "string", "description": "A short name for its chip, for example #592."],
        ], "required": ["target"]]
        let fields: [String: Any] = [
            "assignee": ["type": "string", "description": "Who it is for, by name (list_people); \"none\" clears."],
            "due": ["type": "string", "description": "YYYY-MM-DD, today or tomorrow; \"none\" clears."],
            "labels": labels,
            "parent_id": ["type": "string", "description": "Makes it a step (subtask) of that task; \"none\" makes it a task of its own."],
            "blocked_by": ids,
            "kind": kindSchema,
            "done_when": ["type": "string", "description": "What \"done\" looks like for it."],
            "session_id": ["type": "string", "description": "The Claude Code session working on it, to resume later."],
            "links": ["type": "array", "items": link, "description": "Links to attach."],
            "checklist": ["type": "array", "items": ["type": "string"], "description": "Checklist items to add."],
        ]
        func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: Any], required: [String] = [],
                  readOnly: Bool, destructive: Bool = false) -> [String: Any] {
            [
                "name": name,
                "title": title,
                "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
                "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive, "idempotentHint": readOnly, "openWorldHint": false],
            ]
        }
        return [
            tool("list_tasks", "List tasks",
                 "Lists tasks, most pressing first: by status, then priority. Without a status, only open tasks (not complete), and never archived ones unless include_archived. Each has an id, title, status, priority, assignee, project and a short summary; get_task reads one in full.",
                 [
                    "status": ["description": "One status, or a list of them.", "oneOf": [statusSchema, ["type": "array", "items": statusSchema]]],
                    "include_complete": ["type": "boolean", "description": "With no status given, include complete tasks too."],
                    "include_archived": ["type": "boolean"],
                    "project": ["type": "string", "description": "A project's name or id (its sub-projects are included), or \"none\" for tasks in no project."],
                    "priority": prioritySchema,
                    "assignee": ["type": "string", "description": "Only tasks for this person, or \"none\" for unassigned ones."],
                    "label": ["type": "string"],
                    "kind": kindSchema,
                    "parent_id": ["type": "string", "description": "Only the steps of this task."],
                    "query": ["type": "string", "description": "Only tasks whose title or description contains this (any case)."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "At most this many (default 50)."],
                 ], readOnly: true),
            tool("search_tasks", "Search tasks",
                 "Finds tasks by any mix of words, status, assignee, project, label, kind and when they last changed; newest change first.",
                 [
                    "text": ["type": "string", "description": "Words in the title, description or labels, in any order."],
                    "status": ["description": "One status, or a list.", "oneOf": [statusSchema, ["type": "array", "items": statusSchema]]],
                    "assignee": ["type": "string", "description": "A name, or \"none\"."],
                    "project": ["type": "string"],
                    "label": ["description": "A label, or a list that must all be on the task.", "oneOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]],
                    "kind": kindSchema,
                    "updated_since": ["type": "string", "description": "YYYY-MM-DD, an ISO 8601 time, today or yesterday."],
                    "include_archived": ["type": "boolean"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 500],
                 ], readOnly: true),
            tool("get_task", "Read a task", "One task in full: its whole description, checklist, links, steps and what it waits on.",
                 ["id": id], required: ["id"], readOnly: true),
            tool("list_subtasks", "List a task's steps", "A task's steps (subtasks), in order, and how many are done.",
                 ["id": id, "include_archived": ["type": "boolean"]], required: ["id"], readOnly: true),
            tool("list_projects", "List projects", "Every project, with its path (for nested ones), id and how many open tasks it has.",
                 [:], readOnly: true),
            tool("list_people", "List people", "The names tasks can be assigned to: those already used, with how many open tasks each has. A new name can be assigned too.",
                 [:], readOnly: true),
            tool("list_labels", "List labels", "Every label in use, with how many tasks carry it.",
                 [:], readOnly: true),
            tool("find_by_link", "Find tasks by link", "The tasks tied to a pull request (#592 or its URL), a commit hash, a branch or a page.",
                 ["link": ["type": "string"]], required: ["link"], readOnly: true),
            tool("summary", "Summary of the day",
                 "What is in progress, in review, blocked, waiting on the user, and done since the start of today (or since), as lists and as Markdown ready to post. Also answers to my_day.",
                 [
                    "since": ["type": "string", "description": "YYYY-MM-DD or an ISO 8601 time; default the start of today."],
                    "assignee": ["type": "string", "description": "Only this person's tasks."],
                 ], readOnly: true),
            tool("create_task", "Create a task", "Adds a task. A project named that does not exist yet is created; a step (parent_id) goes in its task's project unless one is named.",
                 [
                    "title": ["type": "string"],
                    "notes": ["type": "string", "description": "The description, in Markdown."],
                    "project": ["type": "string", "description": "A project's name or id."],
                    "priority": prioritySchema,
                    "status": statusSchema,
                 ].merging(fields) { first, _ in first }, required: ["title"], readOnly: false),
            tool("create_plan", "Create a plan",
                 "A feature and its steps in one call: the feature as a task, each step a subtask with what done looks like. With sequential (the default), each step is blocked by the one before. assignee and labels given for the plan go to every step that names none.",
                 [
                    "title": ["type": "string"],
                    "notes": ["type": "string"],
                    "project": ["type": "string"],
                    "priority": prioritySchema,
                    "assignee": ["type": "string"],
                    "labels": labels,
                    "due": ["type": "string"],
                    "session_id": ["type": "string"],
                    "sequential": ["type": "boolean", "description": "Each step waits on the one before (default true)."],
                    "steps": ["type": "array", "items": ["type": "object", "properties": [
                        "title": ["type": "string"],
                        "done_when": ["type": "string", "description": "What done looks like for this step."],
                        "notes": ["type": "string"],
                        "assignee": ["type": "string"],
                        "priority": prioritySchema,
                        "labels": labels,
                        "kind": kindSchema,
                        "due": ["type": "string"],
                        "checklist": ["type": "array", "items": ["type": "string"]],
                    ], "required": ["title"]]],
                 ], required: ["title", "steps"], readOnly: false),
            tool("update_task", "Update a task",
                 "Changes only the fields given and leaves every other one as it is. Use \"none\" to clear the project, assignee, due date, parent or session.",
                 [
                    "id": id,
                    "status": statusSchema,
                    "priority": prioritySchema,
                    "title": ["type": "string"],
                    "project": ["type": "string", "description": "A project's name or id, or \"none\"."],
                 ].merging(fields) { first, _ in first }, required: ["id"], readOnly: false),
            tool("move_task", "Move a task", "Moves a task, with its steps, to another project (\"none\" for no project). A task from Sensory OS can't change boards from here.",
                 ["id": id, "project": ["type": "string"]], required: ["id", "project"], readOnly: false),
            tool("archive_task", "Archive a task",
                 "Takes a task (and its steps) out of every list but Archived; restore brings it back. delete removes it for good instead — only when the user asks; a Sensory OS task stays on the website.",
                 ["id": id, "restore": ["type": "boolean"], "delete": ["type": "boolean"]], required: ["id"], readOnly: false, destructive: true),
            tool("add_note", "Add a note to a task",
                 "Adds a paragraph to the end of a task's description — say what was done, found or decided. What is already there is kept.",
                 ["id": id, "text": ["type": "string", "description": "Markdown."]], required: ["id", "text"], readOnly: false),
            tool("add_checklist", "Add checklist items", "Adds small steps inside one task, as a checklist.",
                 ["id": id, "items": ["type": "array", "items": ["type": "string"]]], required: ["id", "items"], readOnly: false),
            tool("check_item", "Tick a checklist item", "Ticks one checklist item (by its number from 1, or its words); done false unticks it.",
                 ["id": id, "item": ["description": "Its number from 1, or its words.", "oneOf": [["type": "integer"], ["type": "string"]]],
                  "done": ["type": "boolean"]], required: ["id", "item"], readOnly: false),
            tool("link_task", "Link a task", "Attaches a commit, pull request, branch, plan file or staging URL; it shows on the task as a chip. The kind is worked out from the target when not given.",
                 ["id": id, "kind": linkKind, "target": ["type": "string"], "title": ["type": "string"]], required: ["id", "target"], readOnly: false),
            tool("request_review", "Request review", "Sets the task to review, attaches the link given (if any) and notifies the user.",
                 ["id": id, "kind": linkKind, "target": ["type": "string"], "title": ["type": "string"], "note": ["type": "string", "description": "Added to the description."]],
                 required: ["id"], readOnly: false),
            tool("complete_with_proof", "Complete with proof",
                 "Completes the task only when a commit or pull request is attached (already, or given here as kind and target), and nothing it is blocked by is still open.",
                 ["id": id, "kind": linkKind, "target": ["type": "string"], "title": ["type": "string"]], required: ["id"], readOnly: false),
        ]
    }()
}
