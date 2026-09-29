import Foundation

/// A look on disk: where it is, and what it says.
public struct SavedLook: Identifiable, Equatable, Sendable {
    public let url: URL
    public let look: Look

    public var id: URL { url }
    public var name: String { look.name }

    public init(url: URL, look: Look) {
        self.url = url
        self.look = look
    }
}

/// The folder of `.klikstyle` files: listing, saving, renaming, deleting, importing.
///
/// A folder of ordinary files rather than a database, deliberately: a look is something
/// people keep, copy to another Mac and send to each other, and a file in a folder is
/// the one form of that everybody already knows how to handle. The folder is a parameter
/// so a test can point this at a temporary one and never touch the real library.
///
/// **Names.** A look's name is its file name, which is what somebody renaming it in the
/// Finder expects. The JSON carries a `name` too, for the characters a file name cannot
/// hold — "16:9 / Dark" is stored in a file called "16-9 - Dark" — and it wins only
/// while it still agrees with the file; once the file has been renamed by hand, the
/// file's name is the truth.
public struct LookStore: Sendable {
    public let folder: URL
    /// Names a saved look may not take: the built-in ones, so the picker never shows
    /// two tiles with one name.
    public let reservedNames: [String]

    public init(folder: URL, reservedNames: [String] = Look.builtInNames) {
        self.folder = folder
        self.reservedNames = reservedNames
    }

    /// `~/Library/Application Support/Klik Studio/Looks`, inside the sandbox where there
    /// is one.
    public static var standardFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Klik Studio", isDirectory: true)
            .appendingPathComponent("Looks", isDirectory: true)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case emptyName
        case nameTaken(String)
        case reservedName(String)
        case notALook
        case missing

        public var errorDescription: String? {
            switch self {
            case .emptyName: "Give the look a name."
            case .nameTaken(let name): "There is already a look called “\(name)”."
            case .reservedName(let name): "“\(name)” is a built-in look. Choose another name."
            case .notALook: "That file isn't a look."
            case .missing: "That look is no longer in the folder."
            }
        }
    }

    // MARK: - Reading

    /// Every look in the folder, by name. A file that is not a look is skipped rather
    /// than refusing the whole list — one stray file must not empty the picker.
    public func list() -> [SavedLook] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == Look.fileExtension }
            // Rebuilt on `folder` rather than taken as listed: the listing resolves
            // symlinks (`/private/var` for `/var`), and a URL that names the same file a
            // different way is a URL `==` says is a different file.
            .map { folder.appendingPathComponent($0.lastPathComponent) }
            .compactMap { url in Self.read(url).map { SavedLook(url: url, look: $0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether two URLs name one file, however they spell it — including in a different
    /// case, since the disk this runs on almost certainly does not tell "Mine" from
    /// "mine", and renaming a look to fix its capitals must not be refused as taken.
    private static func same(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        let left = a.standardizedFileURL.resolvingSymlinksInPath()
        let right = b.standardizedFileURL.resolvingSymlinksInPath()
        return left.deletingLastPathComponent() == right.deletingLastPathComponent()
            && left.lastPathComponent.caseInsensitiveCompare(right.lastPathComponent) == .orderedSame
    }

    /// One file as a look, named by the rule in the type's note. `nil` for a file that
    /// is not a look at all.
    public static func read(_ url: URL) -> Look? {
        guard let data = try? Data(contentsOf: url), var look = Look.decoded(from: data) else { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        if look.name.isEmpty || Self.fileName(for: look.name) != fileName {
            look.name = fileName
        }
        return look
    }

    // MARK: - Writing

    /// Writes a look under its own name, as a new file.
    @discardableResult
    public func save(_ look: Look) throws -> SavedLook {
        let name = try validated(look.name, excluding: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var named = look
        named.name = name
        let url = self.url(for: name)
        try named.encoded().write(to: url, options: .atomic)
        return SavedLook(url: url, look: named)
    }

    /// Gives a saved look a new name: the file moves, and the name inside it follows.
    ///
    /// The file is patched rather than re-encoded, so fields this build does not know —
    /// a newer build's — survive the rename.
    @discardableResult
    public func rename(_ saved: SavedLook, to newName: String) throws -> SavedLook {
        let name = try validated(newName, excluding: saved.url)
        guard FileManager.default.fileExists(atPath: saved.url.path(percentEncoded: false)) else {
            throw Failure.missing
        }
        let destination = url(for: name)
        if destination != saved.url {
            // Through a spare name when only the case differs: a disk that does not tell
            // the two apart may refuse to move a file onto itself.
            if Self.same(destination, saved.url) {
                let spare = folder.appendingPathComponent("\(UUID().uuidString).\(Look.fileExtension)")
                try FileManager.default.moveItem(at: saved.url, to: spare)
                try FileManager.default.moveItem(at: spare, to: destination)
            } else {
                try FileManager.default.moveItem(at: saved.url, to: destination)
            }
        }
        try Self.patchName(name, in: destination)
        var look = saved.look
        look.name = name
        return SavedLook(url: destination, look: look)
    }

    /// Removes a saved look — to the Trash when asked, where a person can change their
    /// mind, or outright, which is what a test wants of a temporary folder.
    public func delete(_ saved: SavedLook, trashing: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: saved.url.path(percentEncoded: false)) else {
            throw Failure.missing
        }
        if trashing, (try? FileManager.default.trashItem(at: saved.url, resultingItemURL: nil)) != nil {
            return
        }
        try FileManager.default.removeItem(at: saved.url)
    }

    /// Copies a look file into the folder.
    ///
    /// Copied byte for byte rather than re-encoded, for the reason `rename` patches: a
    /// look from a newer build keeps everything it says for the day this build can read
    /// it. Its name is made unique rather than refused — "Sunset 2" — because the person
    /// did not type it and has nothing to correct.
    @discardableResult
    public func importLook(from source: URL) throws -> SavedLook {
        guard let look = Self.read(source), !look.isEmpty else { throw Failure.notALook }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = uniqueName(from: look.name.isEmpty ? "Look" : look.name)
        let destination = url(for: name)
        try FileManager.default.copyItem(at: source, to: destination)
        try Self.patchName(name, in: destination)
        var named = look
        named.name = name
        return SavedLook(url: destination, look: named)
    }

    // MARK: - Names

    /// The file a name is kept in.
    public func url(for name: String) -> URL {
        folder.appendingPathComponent(Self.fileName(for: name)).appendingPathExtension(Look.fileExtension)
    }

    /// A name as a file name: the two characters a path cannot hold become dashes, and a
    /// name that was nothing but those is "Look".
    public static func fileName(for name: String) -> String {
        let cleaned = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { $0 == "/" || $0 == ":" ? "-" : $0 }
        let joined = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty, joined != "." , joined != ".." else { return "Look" }
        return String(joined.prefix(120))
    }

    /// Whether a name is one that already exists here, or is kept for a built-in.
    public func isTaken(_ name: String, excluding own: URL? = nil) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if reservedNames.contains(where: { $0.lowercased() == key }) { return true }
        return list().contains { !Self.same($0.url, own) && $0.name.lowercased() == key }
    }

    private func validated(_ name: String, excluding own: URL?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        if reservedNames.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            throw Failure.reservedName(trimmed)
        }
        if isTaken(trimmed, excluding: own) { throw Failure.nameTaken(trimmed) }
        // Two names may sanitise to one file: "A/B" and "A:B". The file is what has to
        // be unique.
        let file = url(for: trimmed)
        if !Self.same(file, own), FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            throw Failure.nameTaken(trimmed)
        }
        return trimmed
    }

    private func uniqueName(from wanted: String) -> String {
        let base = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = base
        var counter = 2
        while isTaken(candidate) || FileManager.default.fileExists(atPath: url(for: candidate).path(percentEncoded: false)) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    /// Rewrites the `name` inside a look file and nothing else.
    private static func patchName(_ name: String, in url: URL) throws {
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.notALook
        }
        object["name"] = name
        let patched = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try patched.write(to: url, options: .atomic)
    }
}
