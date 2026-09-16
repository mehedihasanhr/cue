import AppKit
import Observation

/// A text expander entry: type its keyword (`;welcome`) anywhere and the keyword is
/// replaced by the template, with `{{Name}}`-style blanks filled in first. A snippet
/// can also carry an asset (an image or a file), pasted in place of the keyword.
nonisolated struct Snippet: Identifiable, Codable, Hashable {
    let id: UUID
    /// What is typed to expand it, including any leading trigger character.
    var keyword: String
    /// A label for the list; the keyword when empty.
    var name: String
    /// The template, with `{{placeholders}}`.
    var text: String
    /// An asset pasted instead of text.
    var assetID: UUID?
    var createdAt: Date
    var uses: Int

    init(keyword: String, name: String = "", text: String, assetID: UUID? = nil) {
        id = UUID()
        self.keyword = keyword
        self.name = name
        self.text = text
        self.assetID = assetID
        createdAt = .now
        uses = 0
    }

    var title: String { name.isEmpty ? keyword : name }

    /// The blanks the user fills before pasting, in order of appearance; the
    /// built-in ones (`date`, `time`, `clipboard`) fill themselves.
    var placeholders: [String] { SnippetTemplate.placeholders(in: text).filter { !SnippetTemplate.isBuiltIn($0) } }

    private enum CodingKeys: String, CodingKey { case id, keyword, name, text, assetID, createdAt, uses }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        keyword = try container.decode(String.self, forKey: .keyword)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        assetID = try container.decodeIfPresent(UUID.self, forKey: .assetID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        uses = try container.decodeIfPresent(Int.self, forKey: .uses) ?? 0
    }
}

/// `{{Name}}` blanks in a template.
nonisolated enum SnippetTemplate {
    static let builtIns = ["date", "time", "datetime", "clipboard"]

    static func isBuiltIn(_ name: String) -> Bool { builtIns.contains(name.lowercased()) }

    /// Every distinct placeholder name, in order of first appearance.
    static func placeholders(in text: String) -> [String] {
        var names: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
            rest = rest[close.upperBound...]
        }
        return names
    }

    /// The template with every blank filled: `values` by name (case-insensitive),
    /// the built-ins from the moment, anything else left empty.
    static func expand(_ text: String, values: [String: String], now: Date = .now, clipboard: String? = nil) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            result += rest[..<open.lowerBound]
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            result += value(for: name, values: values, now: now, clipboard: clipboard)
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    private static func value(for name: String, values: [String: String], now: Date, clipboard: String?) -> String {
        if let given = values.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value { return given }
        switch name.lowercased() {
        case "date": return now.formatted(date: .long, time: .omitted)
        case "time": return now.formatted(date: .omitted, time: .shortened)
        case "datetime": return now.formatted(date: .abbreviated, time: .shortened)
        case "clipboard": return clipboard ?? ""
        default: return ""
        }
    }
}

/// The snippets, newest first, as one JSON file in the app container.
@Observable
final class SnippetStore {
    private(set) var items: [Snippet] = []
    private let fileURL: URL
    @ObservationIgnored private let storage = DispatchQueue(label: "com.stackrover.klik.snippets", qos: .utility)

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = support.appendingPathComponent("Klik", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("snippets.json")
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            items = decoded
        }
    }

    /// Keywords are trimmed and unique (a new one replaces an old snippet's keyword).
    static func cleanKeyword(_ keyword: String) -> String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isWhitespace }
    }

    @discardableResult
    func add(keyword: String, name: String = "", text: String, assetID: UUID? = nil) -> Snippet? {
        let keyword = Self.cleanKeyword(keyword)
        guard !keyword.isEmpty, !text.isEmpty || assetID != nil else { return nil }
        let snippet = Snippet(keyword: keyword, name: name.trimmingCharacters(in: .whitespacesAndNewlines), text: text, assetID: assetID)
        items.removeAll { $0.keyword == keyword }
        items.insert(snippet, at: 0)
        save()
        return snippet
    }

    func update(_ snippet: Snippet, keyword: String, name: String, text: String) {
        let keyword = Self.cleanKeyword(keyword)
        guard !keyword.isEmpty else { return }
        items.removeAll { $0.keyword == keyword && $0.id != snippet.id }
        guard let index = items.firstIndex(where: { $0.id == snippet.id }) else { return }
        items[index].keyword = keyword
        items[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].text = text
        save()
    }

    func delete(_ snippet: Snippet) {
        items.removeAll { $0.id == snippet.id }
        save()
    }

    func recordUse(_ snippet: Snippet) {
        guard let index = items.firstIndex(where: { $0.id == snippet.id }) else { return }
        items[index].uses += 1
        save()
    }

    /// The snippet whose keyword the typed text ends with, longest keyword first.
    func match(endOf typed: String) -> Snippet? {
        items.filter { typed.hasSuffix($0.keyword) }.max { $0.keyword.count < $1.keyword.count }
    }

    /// The longest keyword, so the typing buffer never needs to be longer.
    var longestKeyword: Int { items.map(\.keyword.count).max() ?? 0 }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let url = fileURL
        storage.async { try? data.write(to: url, options: .atomic) }
    }
}
