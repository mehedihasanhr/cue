import Foundation
import SwiftUI

// MARK: - What the dashboard lists

/// The fixed lists at the top of the dashboard's sidebar.
nonisolated enum TaskDashboardList: String, CaseIterable, Identifiable {
    case all, today, urgent, unassigned, completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All tasks"
        case .today: "Today"
        case .urgent: "Urgent"
        case .unassigned: "No project"
        case .completed: "Completed"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .today: "sun.max"
        case .urgent: "flame"
        case .unassigned: "tray"
        case .completed: "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .all: .blue
        case .today: .orange
        case .urgent: .red
        case .unassigned: .gray
        case .completed: .green
        }
    }
}

/// What the sidebar has chosen: one of the fixed lists, or a project (with the
/// projects nested in it).
nonisolated enum TaskDashboardSelection: Hashable {
    case list(TaskDashboardList)
    case project(UUID)

    /// How it is kept in the defaults: `list:today`, `project:<uuid>`.
    var rawValue: String {
        switch self {
        case .list(let list): "list:\(list.rawValue)"
        case .project(let id): "project:\(id.uuidString)"
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "list": guard let list = TaskDashboardList(rawValue: parts[1]) else { return nil }; self = .list(list)
        case "project": guard let id = UUID(uuidString: parts[1]) else { return nil }; self = .project(id)
        default: return nil
        }
    }
}

/// The dashboard's filtering and ordering, apart from any view so it can be tested.
nonisolated enum TaskDashboardQuery {
    /// The order of the status groups and the board's columns: the way work moves —
    /// to do, in process, review, complete.
    static let statusOrder: [TaskStatus] = [.pending, .inProcess, .review, .complete]

    /// The tasks a fixed list shows.
    static func filter(_ tasks: [TaskItem], list: TaskDashboardList, now: Date = .now, calendar: Calendar = .current) -> [TaskItem] {
        switch list {
        case .all: tasks
        case .today: tasks.filter { calendar.isDate($0.createdAt, inSameDayAs: now) || calendar.isDate($0.updatedAt, inSameDayAs: now) }
        case .urgent: tasks.filter { $0.priority == .urgent && $0.status != .complete }
        case .unassigned: tasks.filter { $0.projectID == nil }
        case .completed: tasks.filter { $0.status == .complete }
        }
    }

    /// The number beside a list in the sidebar: what is still open, except on
    /// Completed, which counts what is done.
    static func count(_ tasks: [TaskItem], list: TaskDashboardList, now: Date = .now, calendar: Calendar = .current) -> Int {
        let shown = filter(tasks, list: list, now: now, calendar: calendar)
        return list == .completed ? shown.count : shown.filter { $0.status != .complete }.count
    }

    /// Whether the task's text holds every word of the search, in any order and case.
    static func matches(_ task: TaskItem, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = ((task.customTitle ?? "") + "\n" + task.text).lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    /// In the order tasks were dragged into (`order`); those never placed come first,
    /// the most pressing first and within a priority the newest.
    static func sorted(_ tasks: [TaskItem], order: [UUID] = []) -> [TaskItem] {
        let rank = Dictionary(uniqueKeysWithValues: TaskPriority.allCases.enumerated().map { ($1, $0) })
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return tasks.sorted { lhs, rhs in
            switch (position[lhs.id], position[rhs.id]) {
            case let (left?, right?): return left < right
            case (nil, .some): return true
            case (.some, nil): return false
            case (nil, nil):
                let left = rank[lhs.priority] ?? 0, right = rank[rhs.priority] ?? 0
                return left != right ? left < right : lhs.createdAt > rhs.createdAt
            }
        }
    }

    /// The order after a task is dropped above or below another: every task in its
    /// shown place, the dragged one moved to the drop.
    static func reordered(_ tasks: [TaskItem], order: [UUID], moving id: UUID, to target: UUID, below: Bool) -> [UUID] {
        var ids = sorted(tasks, order: order).map(\.id).filter { $0 != id }
        guard id != target, let anchor = ids.firstIndex(of: target) else { return order }
        ids.insert(id, at: below ? anchor + 1 : anchor)
        return ids
    }

    struct Group: Identifiable, Equatable {
        let status: TaskStatus
        let tasks: [TaskItem]
        var id: TaskStatus { status }
    }

    /// The tasks by status in `statusOrder`, each sorted; empty statuses are left out.
    static func grouped(_ tasks: [TaskItem], order: [UUID] = []) -> [Group] {
        statusOrder.compactMap { status in
            let own = sorted(tasks.filter { $0.status == status }, order: order)
            return own.isEmpty ? nil : Group(status: status, tasks: own)
        }
    }
}

/// A page's icon, picked from its header the way Notion's is: an SF Symbol or an emoji.
/// Kept as `symbol:<name>` or `emoji:<character>`.
nonisolated enum PageIcon: Hashable {
    case symbol(String)
    case emoji(String)

    var rawValue: String {
        switch self {
        case .symbol(let name): "symbol:\(name)"
        case .emoji(let character): "emoji:\(character)"
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "symbol": self = .symbol(parts[1])
        case "emoji": self = .emoji(parts[1])
        default: return nil
        }
    }

    /// The symbols offered, grouped loosely by what a list might be about.
    static let symbols: [String] = [
        "tray.full", "tray", "checklist", "checkmark.circle", "list.bullet", "square.grid.2x2", "folder", "doc.text",
        "sun.max", "moon", "flame", "bolt", "star", "heart", "flag", "bookmark",
        "tag", "target", "lightbulb", "sparkles", "chart.bar", "chart.line.uptrend.xyaxis", "calendar", "clock",
        "bell", "envelope", "bubble.left", "phone", "person", "person.2", "house", "building.2",
        "briefcase", "hammer", "wrench.and.screwdriver", "paintbrush", "pencil", "book", "graduationcap", "terminal",
        "chevron.left.forwardslash.chevron.right", "ladybug", "shippingbox", "cube", "puzzlepiece", "cart", "creditcard", "dollarsign.circle",
        "airplane", "car", "leaf", "globe", "camera", "music.note", "gamecontroller", "paperplane",
    ]

    static let emoji: [String] = [
        "✅", "📋", "📌", "🔥", "⭐️", "💡", "🚀", "🎯", "📈", "🛠️", "🐞", "🧪", "📝", "📚", "🎨", "💼",
        "🏠", "🛒", "💰", "✈️", "🎵", "🎮", "❤️", "🌱", "⚡️", "📅", "⏰", "🔔", "📦", "🧩", "🧠", "👥",
        "💬", "📣", "🔒", "🌍", "☕️", "🍀", "🏃", "🎉", "🏆", "📷", "🖥️", "📱", "🧾", "🗂️", "📁", "🗓️",
        "⚙️", "🔍", "✏️", "🤝", "💎", "🌙", "☀️", "🌈",
    ]
}
