import Foundation
import SwiftUI

// MARK: - What the dashboard lists

/// The fixed lists at the top of the notes dashboard's sidebar.
///
/// Notes have no status, priority or project to sort by — only when they were
/// written and what is in them — so the lists are spans of time, and one for the
/// notes that carry pictures or files.
nonisolated enum NoteDashboardList: String, CaseIterable, Identifiable {
    case all, today, week, attachments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All notes"
        case .today: "Today"
        case .week: "This week"
        case .attachments: "With files"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .today: "sun.max"
        case .week: "calendar"
        case .attachments: "paperclip"
        }
    }

    var tint: Color {
        switch self {
        case .all: .blue
        case .today: .orange
        case .week: .purple
        case .attachments: .gray
        }
    }
}

/// What the sidebar has chosen. Only the fixed lists for now — notes live in one
/// flat folder — but shaped like `TaskDashboardSelection` so the two dashboards
/// stay recognisably the same thing.
nonisolated enum NoteDashboardSelection: Hashable {
    case list(NoteDashboardList)

    /// How it is kept in the defaults: `list:today`.
    var rawValue: String {
        switch self {
        case .list(let list): "list:\(list.rawValue)"
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "list", let list = NoteDashboardList(rawValue: parts[1]) else { return nil }
        self = .list(list)
    }
}

/// When a note was last written, as the table groups them. The task dashboard groups
/// by status because that is what moves; a note only ever gets older, so these are
/// the groups — and they are in that order, newest first.
nonisolated enum NoteAge: String, CaseIterable, Identifiable, Hashable {
    case today, yesterday, week, month, older

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .week: "Earlier this week"
        case .month: "Earlier this month"
        case .older: "Older"
        }
    }

    /// The same colours the task statuses use, so a group header reads the same way.
    var tint: NotionColor {
        switch self {
        case .today: .blue
        case .yesterday: .orange
        case .week: .purple
        case .month: .green
        case .older: .gray
        }
    }

    /// Which group a date falls in.
    static func of(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> NoteAge {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        if let week = calendar.date(byAdding: .day, value: -7, to: now), date >= week { return .week }
        if let month = calendar.date(byAdding: .day, value: -31, to: now), date >= month { return .month }
        return .older
    }
}

/// The notes dashboard's filtering, counting and grouping, apart from any view so it
/// can be tested.
nonisolated enum NoteDashboardQuery {
    /// The notes a fixed list shows, newest change first.
    static func filter(_ notes: [Note], list: NoteDashboardList, now: Date = .now, calendar: Calendar = .current) -> [Note] {
        switch list {
        case .all:
            return notes
        case .today:
            return notes.filter { calendar.isDate($0.updatedAt, inSameDayAs: now) }
        case .week:
            guard let week = calendar.date(byAdding: .day, value: -7, to: now) else { return notes }
            return notes.filter { $0.updatedAt >= week }
        case .attachments:
            return notes.filter { carriesFiles($0) }
        }
    }

    static func count(_ notes: [Note], list: NoteDashboardList, now: Date = .now, calendar: Calendar = .current) -> Int {
        filter(notes, list: list, now: now, calendar: calendar).count
    }

    /// Whether a note holds a picture or a file of its own (`cue://`, `cue-file://`),
    /// rather than only words.
    static func carriesFiles(_ note: Note) -> Bool {
        note.text.contains("cue://") || note.text.contains("cue-file://")
    }

    /// Whether a note matches what was typed in the search field: its title or
    /// anything in it, ignoring case.
    static func matches(_ note: Note, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return note.title.localizedCaseInsensitiveContains(needle) || note.text.localizedCaseInsensitiveContains(needle)
    }

    /// Newest change first, which is the order the store keeps and the only order a
    /// flat folder of notes has to offer.
    static func sorted(_ notes: [Note]) -> [Note] {
        notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The groups a set of notes falls into, newest first, leaving out the empty ones.
    static func groups(_ notes: [Note], now: Date = .now, calendar: Calendar = .current) -> [NoteAge] {
        let present = Set(notes.map { NoteAge.of($0.updatedAt, now: now, calendar: calendar) })
        return NoteAge.allCases.filter { present.contains($0) }
    }

    /// The notes in one group, newest first.
    static func notes(_ notes: [Note], in age: NoteAge, now: Date = .now, calendar: Calendar = .current) -> [Note] {
        sorted(notes.filter { NoteAge.of($0.updatedAt, now: now, calendar: calendar) == age })
    }

    /// How many words a note holds, for the table's own column: something to sort a
    /// glance by, where a task would show its status.
    static func words(in note: Note) -> Int {
        TaskText.plain(TaskText.oneLine(note.text))
            .split(whereSeparator: { $0.isWhitespace })
            .count
    }
}
