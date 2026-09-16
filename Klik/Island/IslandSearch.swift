import Foundation

/// Anything a tab holds, for the All tab and for search results across every tab.
enum IslandItem: Identifiable {
    case capture(CaptureItem)
    case clipboard(ClipboardItem)
    case asset(AssetItem)
    case color(ColorEntry)
    case task(TaskItem)

    var id: UUID {
        switch self {
        case .capture(let item): item.id
        case .clipboard(let item): item.id
        case .asset(let item): item.id
        case .color(let entry): entry.id
        case .task(let task): task.id
        }
    }

    var tab: IslandTab {
        switch self {
        case .capture: .captures
        case .clipboard: .clipboard
        case .asset: .assets
        case .color: .colors
        case .task: .tasks
        }
    }

    var date: Date {
        switch self {
        case .capture(let item): item.createdAt
        case .clipboard(let item): item.createdAt
        case .asset(let item): item.createdAt
        case .color(let entry): entry.createdAt
        case .task(let task): task.createdAt
        }
    }
}

/// Searches every store at once, so the search field finds things whichever tab
/// is open. Each word of the query must appear somewhere in the item — its title,
/// text, file name, color in any format, source app, notes or project — so
/// "invoice pdf" finds the asset "Invoice March.pdf". Results keep the tab order
/// (captures, clipboard, assets, colors, tasks), newest first within a tab.
enum IslandSearch {
    /// Everything, newest first, for the All tab.
    static func everything(library: CaptureLibrary, clipboard: ClipboardHistory, assets: AssetStore,
                           colors: ColorStore, tasks: TaskStore) -> [IslandItem] {
        var items: [IslandItem] = []
        items += library.items.map(IslandItem.capture)
        items += clipboard.items.map(IslandItem.clipboard)
        items += assets.items.map(IslandItem.asset)
        items += colors.items.map(IslandItem.color)
        items += tasks.tasks.filter { $0.status != .complete }.map(IslandItem.task) // done tasks are the Tasks tab's "Complete" filter
        return items.sorted { $0.date > $1.date }
    }

    static func hits(for query: String, library: CaptureLibrary, clipboard: ClipboardHistory, assets: AssetStore,
                     colors: ColorStore, tasks: TaskStore) -> [IslandItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        func matches(_ fields: [String?]) -> Bool {
            terms.allSatisfy { term in fields.contains { $0?.localizedCaseInsensitiveContains(term) ?? false } }
        }
        var hits: [IslandItem] = []
        hits += library.items.filter { matches([$0.title, $0.dimensions]) }.map(IslandItem.capture)
        hits += clipboard.items.filter { matches([$0.text, $0.name, $0.sourceName, $0.kind.rawValue]) }.map(IslandItem.clipboard)
        hits += assets.items.filter { matches([$0.fileName]) }.map(IslandItem.asset)
        hits += colors.items.filter { entry in matches([entry.name] + ColorFormat.allCases.map { $0.string(for: entry.color) }) }.map(IslandItem.color)
        hits += tasks.tasks.filter { matches([$0.title, $0.notes, tasks.project($0.projectID)?.name, $0.status.title, $0.priority.title]) }.map(IslandItem.task)
        return hits
    }

    /// How many hits each tab contributed, in tab order, skipping empty tabs.
    static func counts(_ hits: [IslandItem]) -> [(tab: IslandTab, count: Int)] {
        IslandTab.allCases.filter { $0 != .all }.compactMap { tab in
            let count = hits.count { $0.tab == tab }
            return count > 0 ? (tab, count) : nil
        }
    }
}
