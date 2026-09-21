import os
import AppKit
import Observation
import SwiftUI

/// One color picked from the screen.
nonisolated struct ColorEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var color: PickedColor
    var createdAt: Date
    /// A label given by the user ("Brand pink").
    var name: String?
    /// Kept at the top of the list, by "Clear" and by the history limit.
    var pinned = false
    /// The group (folder) it is in, if any.
    var groupID: UUID?

    init(color: PickedColor, createdAt: Date = .now) {
        id = UUID()
        self.color = color
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, color, createdAt, name, pinned, groupID }

    /// Files written before pinning existed have no `pinned` key.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        color = try container.decode(PickedColor.self, forKey: .color)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
    }
}

/// Colors picked with the eyedropper, newest first. Small, so a JSON file in the
/// app container is all it needs.
@Observable
@MainActor
final class ColorStore {
    private(set) var items: [ColorEntry] = []
    /// The file, in the container or the sync folder.
    @ObservationIgnored private let file: SyncedFile

    private static let limit = 500

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = support.appendingPathComponent("Klik", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = SyncedFile(name: "klik-colors.json", local: folder.appendingPathComponent("colors.json"))
        if let data = try? Data(contentsOf: file.url), let decoded = try? JSONDecoder().decode([ColorEntry].self, from: data) {
            items = decoded
        }
        file.changed = { [weak self] data in self?.load(data) }
    }

    /// Keeps the colors in `folder` (nil: the container), taking what is there.
    func useSyncFolder(_ folder: URL?) {
        if let data = file.relocate(to: folder, current: try? JSONEncoder().encode(items)) { load(data) }
    }

    private func load(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode([ColorEntry].self, from: data) else { return }
        items = decoded
    }

    /// Records a picked color, newest first.
    @discardableResult
    func add(_ color: PickedColor) -> ColorEntry {
        let entry = ColorEntry(color: color)
        items.insert(entry, at: 0)
        // Over the limit, the oldest unpinned colors go.
        var excess = items.count - Self.limit
        if excess > 0 {
            for index in items.indices.reversed() where excess > 0 && !items[index].pinned {
                items.remove(at: index)
                excess -= 1
            }
        }
        save()
        return entry
    }

    /// Exact sRGB components, unclamped: a Display P3 color outside sRGB keeps its
    /// true value rather than being flattened to the nearest sRGB color.
    static func picked(from color: NSColor) -> PickedColor? {
        guard let srgb = color.usingColorSpace(.extendedSRGB) else { return nil }
        return PickedColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
    }

    /// Copies the color in the given format, marked so the clipboard history does
    /// not list it twice.
    func copy(_ entry: ColorEntry, as format: ColorFormat) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(format.string(for: entry.color), forType: .string)
        pasteboard.setData(Data(), forType: Clipboard.ownMarker)
    }

    func rename(_ entry: ColorEntry, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == entry.id }) else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].name = cleaned.isEmpty ? nil : cleaned
        save()
    }

    func togglePin(_ entry: ColorEntry) {
        guard let index = items.firstIndex(where: { $0.id == entry.id }) else { return }
        items[index].pinned.toggle()
        save()
    }

    /// Puts the color in a group (nil: out of any).
    func setGroup(_ entry: ColorEntry, _ groupID: UUID?) {
        guard let index = items.firstIndex(where: { $0.id == entry.id }), items[index].groupID != groupID else { return }
        items[index].groupID = groupID
        save()
    }

    /// A deleted group's colors are ungrouped.
    func removeGroup(_ groupID: UUID) {
        guard items.contains(where: { $0.groupID == groupID }) else { return }
        for index in items.indices where items[index].groupID == groupID { items[index].groupID = nil }
        save()
    }

    func delete(_ entry: ColorEntry) {
        items.removeAll { $0.id == entry.id }
        save()
    }

    /// Removes everything except pinned colors.
    /// Removes the recent colors — everything neither pinned nor in a group.
    func clear() {
        items.removeAll { !$0.pinned && $0.groupID == nil }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        file.write(data)
    }
}

extension PickedColor {
    /// For SwiftUI swatches (clamped to sRGB).
    var swiftUIColor: Color {
        let (r, g, b) = clamped
        return Color(red: r, green: g, blue: b, opacity: alpha)
    }

    /// Whether white text reads well on the color.
    var isDark: Bool {
        let (r, g, b) = linear
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.35
    }
}
