import CryptoKit
import Foundation

/// A task as it travels: what the remote server and webhooks get, and what a
/// server may send back. Dates are ISO 8601.
nonisolated struct RemoteTask: Codable, Sendable {
    var id: UUID
    var title: String
    var text: String
    var status: TaskStatus
    var priority: TaskPriority
    var projectID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        text = task.text
        status = task.status
        priority = task.priority
        projectID = task.projectID
        createdAt = task.createdAt
        updatedAt = task.updatedAt
    }

    /// The task as stored; a server that sends only a title gets it as the text, and
    /// one whose title is not the one the text gives has renamed the task.
    var item: TaskItem {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = text.isEmpty || title.isEmpty ? nil : TaskText.customTitle(title, for: text)
        return TaskItem(id: id, text: text.isEmpty ? title : text, customTitle: custom, projectID: projectID, status: status, priority: priority, createdAt: createdAt, updatedAt: updatedAt)
    }

    private enum CodingKeys: String, CodingKey { case id, title, text, status, priority, projectID, createdAt, updatedAt }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        status = try container.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .pending
        priority = try container.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .medium
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

nonisolated struct RemoteProject: Codable, Sendable {
    var id: UUID
    var name: String
    var parentID: UUID?
    var createdAt: Date

    init(_ project: TaskProject) {
        id = project.id
        name = project.name
        parentID = project.parentID
        createdAt = project.createdAt
    }

    var project: TaskProject { TaskProject(id: id, name: name, parentID: parentID, createdAt: createdAt) }

    private enum CodingKeys: String, CodingKey { case id, name, parentID, createdAt }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }
}

/// What Cue POSTs to the sync URL: everything it has, and what it deleted since
/// the last sync. The server answers with what Cue should take (all optional).
nonisolated struct TaskSyncRequest: Encodable, Sendable {
    var client = "cue"
    var version = 1
    var sentAt: Date
    var since: Date?
    var projects: [RemoteProject]
    var tasks: [RemoteTask]
    var deleted: [UUID]
}

nonisolated struct TaskSyncResponse: Decodable, Sendable {
    var projects: [RemoteProject]?
    var tasks: [RemoteTask]?
    var deleted: [UUID]?
}

/// One change, as a webhook gets it.
nonisolated struct TaskWebhookEvent: Encodable, Sendable {
    var event: String
    var sentAt: Date
    var task: RemoteTask?
    var project: RemoteProject?
}

nonisolated enum TaskSyncError: LocalizedError {
    case noURL
    case status(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noURL: "Enter a URL starting with https://"
        case .status(let code, let body): body.isEmpty ? "The server answered \(code)" : "The server answered \(code): \(body)"
        case .badResponse: "The server's answer is not JSON"
        }
    }
}

/// JSON as it goes over the wire (ISO 8601 dates, sorted keys) and the signature
/// on webhook bodies.
nonisolated enum TaskWire {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// `sha256=<hex HMAC-SHA256 of the body>`, for the receiver to check.
    static func signature(of body: Data, secret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
    }
}
