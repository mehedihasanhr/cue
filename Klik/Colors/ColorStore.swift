import os
import AppKit
import Observation
import SwiftUI

/// One colour picked from the screen.
nonisolated struct ColorEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var color: PickedColor
    var createdAt: Date
    /// A label given by the user ("Brand pink").
    var name: String?

    init(color: PickedColor, createdAt: Date = .now) {
        id = UUID()
        self.color = color
        self.createdAt = createdAt
    }
}

/// Colours picked with the eyedropper, newest first. Small, so a JSON file in the
/// app container is all it needs.
@Observable
final class ColorStore {
    private(set) var items: [ColorEntry] = []
    private let fileURL: URL
    @ObservationIgnored private let storage = DispatchQueue(label: "com.stackrover.klik.colors", qos: .utility)

    private static let limit = 500

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = support.appendingPathComponent("Klik", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("colors.json")
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([ColorEntry].self, from: data) {
            items = decoded
        }
    }

    /// Records a picked colour, newest first.
    @discardableResult
    func add(_ color: PickedColor) -> ColorEntry {
        let entry = ColorEntry(color: color)
        items.insert(entry, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
        return entry
    }

    /// Exact sRGB components, unclamped: a Display P3 colour outside sRGB keeps its
    /// true value rather than being flattened to the nearest sRGB colour.
    static func picked(from color: NSColor) -> PickedColor? {
        guard let srgb = color.usingColorSpace(.extendedSRGB) else { return nil }
        return PickedColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
    }

    /// Copies the colour in the given format, marked so the clipboard history does
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

    func delete(_ entry: ColorEntry) {
        items.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let url = fileURL
        storage.async { try? data.write(to: url, options: .atomic) }
    }
}

extension PickedColor {
    /// For SwiftUI swatches (clamped to sRGB).
    var swiftUIColor: Color {
        let (r, g, b) = clamped
        return Color(red: r, green: g, blue: b, opacity: alpha)
    }

    /// Whether white text reads well on the colour.
    var isDark: Bool {
        let (r, g, b) = linear
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.35
    }
}
