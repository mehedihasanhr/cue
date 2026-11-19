import CryptoKit
import Foundation

// MARK: - Links kept on tasks and projects

/// A project that mirrors part of a connected organization: its root (`boardID` nil)
/// or one of its boards.
nonisolated struct OrgLink: Codable, Hashable, Sendable {
    /// Which service: `sensory-os`.
    var source: String
    var agencyID: String
    /// Nil on the organization's root (or an agency, when there are several).
    var boardID: String?
    /// The board's project on the website, for where a task opens.
    var webProjectID: String?
}

/// A task's copy on a connected organization's website.
nonisolated struct RemoteLink: Codable, Hashable, Sendable {
    var source: String
    var agencyID: String
    /// The website's id for it; nil until the website has made it.
    var taskID: String?
    var boardID: String
    /// Path on the website that opens it.
    var href: String?
    /// The website's last change to it, as it said.
    var serverUpdatedAt: Date?
    /// The values last agreed with the website: what a change here is measured against,
    /// so only what was changed is sent, and a change there is only taken when nothing
    /// was changed here.
    var base: RemoteValues?
    /// Why the last send failed, shown on the task until a send works.
    var error: String?
    /// When that send was refused: it is not tried again until the task changes after it.
    var refusedAt: Date?
    /// Cue's own id for the create, so a retry is answered with the task the first try made.
    var clientRef: UUID?
}

/// What is kept in step: the four things both sides have.
nonisolated struct RemoteValues: Codable, Hashable, Sendable {
    var title: String
    var description: String
    var status: TaskStatus
    /// Nil: the website has none set (Cue shows Medium).
    var priority: TaskPriority?
}

// MARK: - The wire

nonisolated struct SOSAgency: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var slug: String
    var role: String
    var membershipId: String
    var canEdit: Bool
}

nonisolated struct SOSMe: Codable, Sendable {
    struct User: Codable, Sendable {
        var id: String
        var email: String
        var name: String?
    }

    struct Realtime: Codable, Sendable {
        var url: String?
        var key: String?
    }

    var user: User
    var agencies: [SOSAgency]
    var realtime: Realtime?
}

nonisolated struct SOSSection: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var done: Bool
}

nonisolated struct SOSBoard: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var projectId: String?
    var projectName: String?
    var sections: [SOSSection]
}

nonisolated struct SOSTask: Codable, Hashable, Sendable {
    var id: String
    var boardId: String
    var sectionId: String?
    var title: String
    var description: String
    var status: String
    var priority: String?
    var dueAt: String?
    var dueHasTime: Bool?
    var assignedToMe: Bool?
    var createdAt: Date
    var updatedAt: Date
    var href: String?
}

nonisolated struct SOSSync: Codable, Sendable {
    var serverTime: Date?
    var cursor: String?
    var more: Bool
    var boards: [SOSBoard]
    var tasks: [SOSTask]
    var taskIds: [String]
    var taskIdsComplete: Bool
}

nonisolated struct SOSNotification: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var agencyId: String
    var createdAt: Date
    var type: String
    var title: String
    var body: String?
    var entityType: String?
    var entityId: String?
    var readAt: Date?
    var href: String?
}

nonisolated struct SOSNotifications: Codable, Sendable {
    var serverTime: Date?
    var notifications: [SOSNotification]
}

nonisolated struct SOSTaskAnswer: Codable, Sendable {
    var task: SOSTask
    var replayed: Bool?
}

nonisolated struct SOSError: Codable, Sendable {
    var error: String
}

// MARK: - Mapping

/// How the two sides name the same things, and the stable ids Cue gives the
/// organization's projects.
nonisolated enum SOSMap {
    static let source = "sensory-os"

    static func status(_ wire: String) -> TaskStatus {
        switch wire {
        case "in_progress": .inProcess
        case "in_review": .review
        case "done": .complete
        default: .pending
        }
    }

    static func wire(_ status: TaskStatus) -> String {
        switch status {
        case .pending: "todo"
        case .inProcess: "in_progress"
        case .review: "in_review"
        case .complete: "done"
        }
    }

    static func priority(_ wire: String?) -> TaskPriority? {
        wire.flatMap(TaskPriority.init(rawValue:))
    }

    /// The same UUID for the same name, every time: the organization's root and agency
    /// projects keep their ids across syncs and reinstalls.
    static func uuid(_ name: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("cue.sensory-os.\(name)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static let rootID = uuid("root")
    static func agencyID(_ agency: String) -> UUID { uuid("agency.\(agency)") }

    /// A board's project: the board's own id where it is a UUID (it always is), so the
    /// same board is the same project.
    static func boardID(_ board: String) -> UUID { UUID(uuidString: board) ?? uuid("board.\(board)") }

    /// A task taken from the website keeps the website's id as its own.
    static func taskID(_ task: String) -> UUID { UUID(uuidString: task) ?? uuid("task.\(task)") }

    /// The values a task has here, as the website names them.
    static func values(of task: TaskItem) -> RemoteValues {
        let title = task.title
        // With no title of its own the title is the text's first line, so the
        // description is what follows it; with one, the whole text is the description.
        let description = task.customTitle == nil ? TaskText.body(of: task.text) : task.text
        return RemoteValues(title: title, description: description, status: task.status, priority: task.priority)
    }

    /// What a task from the website looks like here: its description as the text (its
    /// title when it has none), the title kept as the task's own name.
    static func apply(_ values: RemoteValues, to task: inout TaskItem) {
        let description = values.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = values.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty {
            task.text = title
            task.customTitle = nil
        } else {
            task.text = description
            task.customTitle = title.isEmpty ? nil : title
        }
        task.status = values.status
        task.priority = values.priority ?? .medium
    }

    static func values(of wire: SOSTask) -> RemoteValues {
        RemoteValues(title: wire.title, description: wire.description, status: status(wire.status), priority: priority(wire.priority))
    }

    /// Whether what is here differs from what was agreed (the priority counts only once
    /// it was set here: a task with none on the website shows Medium without changing it).
    static func changes(_ local: RemoteValues, from base: RemoteValues) -> RemoteValues? {
        let priorityChanged = base.priority == nil ? local.priority != .medium : local.priority != base.priority
        let same = local.title == base.title && local.description.trimmingCharacters(in: .whitespacesAndNewlines) == base.description.trimmingCharacters(in: .whitespacesAndNewlines)
            && local.status == base.status && !priorityChanged
        return same ? nil : local
    }
}

extension TaskText {
    /// The text after its title line (the description, when the title is the first line).
    nonisolated static func body(of text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        return lines[(first + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
