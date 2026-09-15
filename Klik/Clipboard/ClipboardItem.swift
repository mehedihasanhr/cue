import Foundation

/// One thing that was on the pasteboard. Text-like content is stored inline; images
/// are PNG files in the clipboard folder, named by `id`.
nonisolated struct ClipboardItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case text, link, color, image, files
    }

    let id: UUID
    var kind: Kind
    /// The text, URL, colour (as `#RRGGBB`) or file paths (one per line).
    var text: String
    var pixelWidth: Int
    var pixelHeight: Int
    var sourceBundleID: String?
    var sourceName: String?
    var createdAt: Date
    var pinned: Bool
    /// A label given by the user; nil shows the content itself.
    var name: String?

    init(id: UUID = UUID(), kind: Kind, text: String, pixelWidth: Int = 0, pixelHeight: Int = 0,
         sourceBundleID: String? = nil, sourceName: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.text = text
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.createdAt = createdAt
        pinned = false
    }

    var fileName: String { "\(id.uuidString).png" }
    var dimensions: String { "\(pixelWidth) × \(pixelHeight)" }

    /// One-line summary for search and titles.
    var title: String {
        if let name, !name.isEmpty { return name }
        return contentTitle
    }

    /// The summary of the content itself, ignoring any label.
    var contentTitle: String {
        switch kind {
        case .text, .link, .color: text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? text
        case .image: "Image \(dimensions)"
        case .files: filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }

    var filePaths: [String] {
        kind == .files ? text.components(separatedBy: "\n").filter { !$0.isEmpty } : []
    }

    /// `#RRGGBB` for `.color` items (the stored text is already normalised).
    var colorComponents: (red: Double, green: Double, blue: Double)? {
        guard kind == .color, text.count == 7, let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    // MARK: - Classification

    /// Recognises a link (a single URL) or a colour (`#D6688B`, `D6688B`, `rgb(…)`);
    /// everything else is text.
    static func classify(_ text: String) -> (Kind, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hex = hexColor(trimmed) { return (.color, hex) }
        if trimmed.count < 2048, !trimmed.contains(where: \.isWhitespace),
           let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "ftp"].contains(scheme), url.host != nil || scheme == "mailto" {
            return (.link, trimmed)
        }
        return (.text, text)
    }

    private static func hexColor(_ text: String) -> String? {
        var body = text.lowercased()
        if body.hasPrefix("#") { body.removeFirst() }
        if body.count == 3, body.allSatisfy(\.isHexDigit) {
            body = body.map { "\($0)\($0)" }.joined()
        }
        if body.count == 6, body.allSatisfy(\.isHexDigit) { return "#" + body.uppercased() }
        // rgb(214, 104, 139)
        if body.hasPrefix("rgb("), body.hasSuffix(")") {
            let parts = body.dropFirst(4).dropLast().split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) {
                return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
            }
        }
        return nil
    }
}
