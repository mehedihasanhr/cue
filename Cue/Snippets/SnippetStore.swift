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
    /// The built-ins offered as chips; `date:FORMAT`, `time:FORMAT` and `shell:CMD`
    /// take an argument after the colon.
    static let builtIns = ["date", "time", "datetime", "clipboard", "uuid", "cursor"]

    /// Where the caret goes after the paste, as a marker that never appears in text.
    static let cursorMarker = "\u{FFFF}"

    static func isBuiltIn(_ name: String) -> Bool {
        let lower = name.lowercased()
        return builtIns.contains(lower) || lower.hasPrefix("date:") || lower.hasPrefix("time:") || lower.hasPrefix("shell:")
    }

    /// The expansion and how many characters the caret must go back to sit where
    /// `{{cursor}}` was (nil: no cursor marker).
    static func expansion(_ text: String, values: [String: String], now: Date = .now, clipboard: String? = nil) -> (text: String, caretBack: Int?) {
        let raw = expand(text, values: values, now: now, clipboard: clipboard)
        guard let marker = raw.range(of: cursorMarker) else { return (raw, nil) }
        let after = raw[marker.upperBound...].replacingOccurrences(of: cursorMarker, with: "")
        return (raw[..<marker.lowerBound] + after, after.count)
    }

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
        let lower = name.lowercased()
        switch lower {
        case "date": return now.formatted(date: .long, time: .omitted)
        case "time": return now.formatted(date: .omitted, time: .shortened)
        case "datetime": return now.formatted(date: .abbreviated, time: .shortened)
        case "clipboard": return clipboard ?? ""
        case "uuid": return UUID().uuidString
        case "cursor": return cursorMarker
        default: break
        }
        // "date:yyyy-MM-dd", "time:HH:mm" — a Unicode date format after the colon.
        if lower.hasPrefix("date:") || lower.hasPrefix("time:") {
            let formatter = DateFormatter()
            formatter.dateFormat = String(name.dropFirst(5))
            return formatter.string(from: now)
        }
        // "shell:date +%s" — what the command prints (trimmed), given two seconds.
        if lower.hasPrefix("shell:") {
            return shell(String(name.dropFirst(6)))
        }
        return ""
    }

    /// Runs a command through /bin/sh in the user's home and returns its output,
    /// or "" when it fails or takes longer than two seconds. Runs inside Cue's
    /// sandbox, so it sees what Cue may see.
    static func shell(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// The snippets, newest first, as one JSON file in the app container.
@Observable
@MainActor
final class SnippetStore {
    private(set) var items: [Snippet] = [] {
        didSet { reindex() }
    }
    /// The file, in the container or the sync folder.
    @ObservationIgnored private let file: SyncedFile
    /// Keywords longest first, and the longest length, for the key monitor's fast path
    /// (it runs on every keystroke in the system).
    @ObservationIgnored private var keywordsByLength: [(keyword: String, index: Int)] = []
    @ObservationIgnored private(set) var longestKeyword = 0
    @ObservationIgnored private let storage = DispatchQueue(label: "com.stackrover.cue.snippets", qos: .utility)

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = support.appendingPathComponent("Cue", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = SyncedFile(name: "cue-snippets.json", local: folder.appendingPathComponent("snippets.json"))
        if let data = try? Data(contentsOf: file.url), let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            items = decoded
        }
        reindex()
        file.changed = { [weak self] data in self?.load(data) }
    }

    /// Keeps the snippets in `folder` (nil: the container), taking what is there.
    func useSyncFolder(_ folder: URL?) {
        if let data = file.relocate(to: folder, current: try? JSONEncoder().encode(items)) { load(data) }
    }

    private func load(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode([Snippet].self, from: data) else { return }
        items = decoded
    }

    private func reindex() {
        keywordsByLength = items.enumerated().map { ($1.keyword, $0) }.sorted { $0.0.count > $1.0.count }
        longestKeyword = keywordsByLength.first?.keyword.count ?? 0
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
        guard !typed.isEmpty else { return nil }
        for entry in keywordsByLength where typed.hasSuffix(entry.keyword) {
            return items[entry.index]
        }
        return nil
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        file.write(data)
    }
}
