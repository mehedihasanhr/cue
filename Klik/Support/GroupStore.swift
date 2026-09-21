import Foundation

/// What a group holds.
nonisolated enum GroupKind: String, Codable, CaseIterable {
    case captures, clipboard, colors, assets
}

/// A folder of the user's making, for captures, clipboard entries or colors.
nonisolated struct ItemGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: GroupKind
    var name: String
    var createdAt: Date

    init(kind: GroupKind, name: String) {
        id = UUID()
        self.kind = kind
        self.name = name
        createdAt = .now
    }
}

/// An item to put in a group as soon as the group exists.
nonisolated enum GroupAssignment: Hashable {
    case capture(UUID), clipboard(UUID), color(UUID), asset(UUID)

    var kind: GroupKind {
        switch self {
        case .capture: .captures
        case .clipboard: .clipboard
        case .color: .colors
        case .asset: .assets
        }
    }
}

/// The groups, newest last, in a JSON file (the sync folder's when there is one).
/// Membership lives on the items themselves (`groupID`).
@Observable
@MainActor
final class GroupStore {
    private(set) var groups: [ItemGroup] = []
    @ObservationIgnored private let file: SyncedFile
    /// Told when a group is deleted, so the stores can drop their items' membership.
    var onDeleted: (ItemGroup) -> Void = { _ in }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = support.appendingPathComponent("Klik", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = SyncedFile(name: "klik-groups.json", local: folder.appendingPathComponent("groups.json"))
        if let data = try? Data(contentsOf: file.url), let decoded = try? JSONDecoder().decode([ItemGroup].self, from: data) {
            groups = decoded
        }
        file.changed = { [weak self] data in self?.load(data) }
    }

    /// Keeps the groups in `folder` (nil: the container), taking what is there.
    func useSyncFolder(_ folder: URL?) {
        if let data = file.relocate(to: folder, current: try? JSONEncoder().encode(groups)) { load(data) }
    }

    private func load(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode([ItemGroup].self, from: data) else { return }
        groups = decoded
    }

    func groups(for kind: GroupKind) -> [ItemGroup] {
        groups.filter { $0.kind == kind }
    }

    func group(_ id: UUID?) -> ItemGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// A new group, unless one of that name already holds this kind (then that one).
    @discardableResult
    func add(name: String, kind: GroupKind) -> ItemGroup? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if let existing = groups.first(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            return existing
        }
        let group = ItemGroup(kind: kind, name: cleaned)
        groups.append(group)
        save()
        return group
    }

    func rename(_ group: ItemGroup, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].name = cleaned
        save()
    }

    /// Removes the group; its items stay, ungrouped.
    func delete(_ group: ItemGroup) {
        groups.removeAll { $0.id == group.id }
        save()
        onDeleted(group)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        file.write(data)
    }
}
