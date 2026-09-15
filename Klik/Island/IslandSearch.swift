import Foundation

/// One match from a search across every tab.
enum SearchHit: Identifiable {
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
    static func hits(for query: String, library: CaptureLibrary, clipboard: ClipboardHistory, assets: AssetStore,
                     colors: ColorStore, tasks: TaskStore) -> [SearchHit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        func matches(_ fields: [String?]) -> Bool {
            terms.allSatisfy { term in fields.contains { $0?.localizedCaseInsensitiveContains(term) ?? false } }
        }
        var hits: [SearchHit] = []
        hits += library.items.filter { matches([$0.title, $0.dimensions]) }.map(SearchHit.capture)
        hits += clipboard.items.filter { matches([$0.text, $0.name, $0.sourceName, $0.kind.rawValue]) }.map(SearchHit.clipboard)
        hits += assets.items.filter { matches([$0.fileName]) }.map(SearchHit.asset)
        hits += colors.items.filter { entry in matches([entry.name] + ColorFormat.allCases.map { $0.string(for: entry.color) }) }.map(SearchHit.color)
        hits += tasks.tasks.filter { matches([$0.title, $0.notes, tasks.project($0.projectID)?.name, $0.status.title]) }.map(SearchHit.task)
        return hits
    }

    /// How many hits each tab contributed, in tab order, skipping empty tabs.
    static func counts(_ hits: [SearchHit]) -> [(tab: IslandTab, count: Int)] {
        IslandTab.allCases.compactMap { tab in
            let count = hits.count { $0.tab == tab }
            return count > 0 ? (tab, count) : nil
        }
    }
}
