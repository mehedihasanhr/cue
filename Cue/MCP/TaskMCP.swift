import Foundation

/// The Model Context Protocol, as Cue speaks it to AI agents: the task list, to read and
/// to work through.
///
/// Six tools — list, read, list projects; create, update, add a note. Nothing deletes:
/// an agent that gets a task wrong should leave something a person can put right, not a
/// gap. Every change goes through `TaskStore`'s own methods, so it saves, syncs, fires
/// webhooks and shows in the dashboard exactly as a change made by hand does.
///
/// Messages are JSON-RPC 2.0, handled one at a time on the main actor; see `MCPServer`.
final class TaskMCP {
    private let store: TaskStore

    init(store: TaskStore) {
        self.store = store
    }

    /// Protocol versions this server can speak, newest first. A client asking for one of
    /// them gets it; any other gets the newest, and decides for itself whether to go on.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    // MARK: - JSON-RPC

    /// The reply to one message, or nil when it was a notification.
    func handle(_ data: Data) -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        // A notification (no id) gets no reply, whatever it says.
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            let result = try respond(to: method, params: params)
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

    private func respond(to method: String, params: [String: Any]) throws(RPCError) -> [String: Any] {
        switch method {
        case "initialize":
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
        var tasks = store.tasks
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

    private func createTask(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        guard let title = Self.string(arguments["title"]) else { return .failure(ToolError("create_task needs a title")) }
        let priority: TaskPriority
        if let name = Self.string(arguments["priority"]) {
            guard let value = TaskPriority(rawValue: name.lowercased()) else {
                return .failure(ToolError("Unknown priority \"\(name)\". Use urgent, high, medium or low."))
            }
            priority = value
        } else {
            priority = .medium
        }
        let projectID = Self.string(arguments["project"]).flatMap { projectCreatingIfNeeded($0)?.id }
        guard var task = store.addTask(titled: title, notes: arguments["notes"] as? String ?? "", in: projectID, priority: priority) else {
            return .failure(ToolError("The task was not added: its title is empty."))
        }
        if let name = Self.string(arguments["status"]) {
            guard let status = Self.status(named: name) else { return .failure(Self.badStatus(name)) }
            store.setStatus(status, for: task)
            task = store.tasks.first { $0.id == task.id } ?? task
        }
        return .success(taskJSON(task, full: true))
    }

    private func updateTask(_ arguments: [String: Any]) -> Result<Any, ToolError> {
        let task: TaskItem
        switch self.task(arguments["id"]) {
        case .success(let found): task = found
        case .failure(let error): return .failure(error)
        }
        // Everything checked before anything changes, so a bad argument changes nothing.
        var status: TaskStatus?
        if let name = Self.string(arguments["status"]) {
            guard let value = Self.status(named: name) else { return .failure(Self.badStatus(name)) }
            status = value
        }
        var priority: TaskPriority?
        if let name = Self.string(arguments["priority"]) {
            guard let value = TaskPriority(rawValue: name.lowercased()) else {
                return .failure(ToolError("Unknown priority \"\(name)\". Use urgent, high, medium or low."))
            }
            priority = value
        }
        let title = Self.string(arguments["title"])
        let projectChange: UUID?? = arguments.keys.contains("project")
            ? .some(Self.string(arguments["project"]).flatMap { $0.lowercased() == "none" ? nil : projectCreatingIfNeeded($0)?.id })
            : .none
        guard status != nil || priority != nil || title != nil || projectChange != nil else {
            return .failure(ToolError("Nothing to change: give a status, priority, title or project."))
        }

        if let title { store.rename(task, to: title) }
        if let status, status != task.status { store.setStatus(status, for: task) }
        if let priority, priority != task.priority { store.setPriority(priority, for: task) }
        if case .some(let projectID) = projectChange, projectID != task.projectID { store.move(task, to: projectID) }
        return .success(taskJSON(store.tasks.first { $0.id == task.id } ?? task, full: true))
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
            "createdAt": Self.dates.string(from: task.createdAt),
            "updatedAt": Self.dates.string(from: task.updatedAt),
        ]
        if let projectID = task.projectID, let project = store.project(projectID) {
            json["project"] = store.path(to: projectID).map(\.name).joined(separator: " / ")
            json["projectID"] = project.id.uuidString.lowercased()
        }
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
    Cue is the user's task manager on this Mac. Tasks have a title, a Markdown description, \
    a status (todo, in_process, review, complete), a priority (urgent, high, medium, low) and \
    optionally a project; projects can nest. list_tasks shows open tasks by default — pass \
    include_complete or a status to see others — and get_task reads one in full. When you \
    finish work a task describes, set its status (review if the user should check it, \
    complete if not) and use add_note to say what you did. Changes appear in Cue at once. \
    Tasks cannot be deleted from here.
    """

    static let tools: [[String: Any]] = {
        let statusSchema: [String: Any] = ["type": "string", "enum": ["todo", "in_process", "review", "complete"]]
        let prioritySchema: [String: Any] = ["type": "string", "enum": ["urgent", "high", "medium", "low"]]
        let id: [String: Any] = ["type": "string", "description": "The task's id from list_tasks (the first 8 characters are enough)."]
        func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: Any], required: [String] = [], readOnly: Bool) -> [String: Any] {
            [
                "name": name,
                "title": title,
                "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
                "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": false, "idempotentHint": readOnly, "openWorldHint": false],
            ]
        }
        return [
            tool("list_tasks", "List tasks",
                 "Lists tasks in Cue, most pressing first: by status, then priority. Without a status, only open tasks (not complete). Each has an id, title, status, priority, project and a short summary; use get_task for the whole description.",
                 [
                    "status": ["description": "One status, or a list of them.", "oneOf": [statusSchema, ["type": "array", "items": statusSchema]]],
                    "include_complete": ["type": "boolean", "description": "With no status given, include complete tasks too."],
                    "project": ["type": "string", "description": "A project's name or id (its sub-projects are included), or \"none\" for tasks in no project."],
                    "priority": prioritySchema,
                    "query": ["type": "string", "description": "Only tasks whose title or description contains this (any case)."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "At most this many (default 50)."],
                 ], readOnly: true),
            tool("get_task", "Read a task", "One task in full, with its whole Markdown description.",
                 ["id": id], required: ["id"], readOnly: true),
            tool("list_projects", "List projects", "Every project, with its path (for nested ones), id and how many open tasks it has.",
                 [:], readOnly: true),
            tool("create_task", "Create a task", "Adds a task to Cue. A project named that does not exist yet is created.",
                 [
                    "title": ["type": "string"],
                    "notes": ["type": "string", "description": "The description, in Markdown."],
                    "project": ["type": "string", "description": "A project's name or id."],
                    "priority": prioritySchema,
                    "status": statusSchema,
                 ], required: ["title"], readOnly: false),
            tool("update_task", "Update a task",
                 "Changes a task's status, priority, title or project — any of them, leaving the rest. Use project \"none\" to take it out of its project.",
                 [
                    "id": id,
                    "status": statusSchema,
                    "priority": prioritySchema,
                    "title": ["type": "string"],
                    "project": ["type": "string", "description": "A project's name or id, or \"none\"."],
                 ], required: ["id"], readOnly: false),
            tool("add_note", "Add a note to a task",
                 "Adds a paragraph to the end of a task's description — say what was done, found or decided. What is already there is kept.",
                 ["id": id, "text": ["type": "string", "description": "Markdown."]], required: ["id", "text"], readOnly: false),
        ]
    }()
}
