import Foundation

/// One take, as the library sees it.
///
/// Everything here is read from disk once and then carried by value, because the list is
/// redrawn on every keystroke of a search field and reading seven manifests per frame is
/// not a list, it is a stutter.
public struct RecordingEntry: Identifiable, Hashable, Sendable {
    public let url: URL
    /// What to call it on screen — the folder's own name. See `RecordingLibrary` on why
    /// the folder wins over the manifest when the two have drifted apart.
    public let name: String
    public let createdAt: Date
    public let duration: Double
    /// What it occupies on disk, everything inside the package counted.
    public let byteCount: Int64
    /// What was recorded, so a take with a voice in it can be told from a silent one
    /// without opening it.
    public let kinds: Set<RecordingManifest.Track.Kind>

    public var id: URL { url }

    public init(url: URL,
                name: String,
                createdAt: Date,
                duration: Double,
                byteCount: Int64,
                kinds: Set<RecordingManifest.Track.Kind>) {
        self.url = url
        self.name = name
        self.createdAt = createdAt
        self.duration = duration
        self.byteCount = byteCount
        self.kinds = kinds
    }
}

/// What the library can refuse to do, and why.
///
/// Spelled out as cases rather than a string, because every one of these is shown to
/// somebody: a rename that quietly does nothing is worse than one that says the name is
/// already taken.
public enum RecordingLibraryError: Error, Equatable, LocalizedError {
    case emptyName
    /// A name with a `/` or a `:` in it is not a name, it is a path — and on this
    /// platform `:` is the separator the Finder shows as `/`, so both are refused.
    case nameContainsPathSeparator
    /// A leading dot hides the recording from the Finder and from this library's own
    /// listing, which is indistinguishable from losing it.
    case nameIsHidden
    case nameTaken(String)
    case notARecording
    /// Everything destructive here is confined to the library folder. A `.cuerec`
    /// somewhere else is somebody else's file.
    case outsideLibrary
    case missing

    public var errorDescription: String? {
        switch self {
        case .emptyName: "A recording needs a name."
        case .nameContainsPathSeparator: "A name can\u{2019}t contain \u{201C}/\u{201D} or \u{201C}:\u{201D}."
        case .nameIsHidden: "A name can\u{2019}t start with a dot."
        case .nameTaken(let name): "There\u{2019}s already a recording called \u{201C}\(name)\u{201D}."
        case .notARecording: "That isn\u{2019}t a Cue Studio recording."
        case .outsideLibrary: "That recording isn\u{2019}t in the library folder."
        case .missing: "That recording is no longer there."
        }
    }
}

/// How the list is ordered.
public enum RecordingOrder: String, CaseIterable, Identifiable, Sendable {
    case date, name, length

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .date: "Date"
        case .name: "Name"
        case .length: "Length"
        }
    }

    /// Which way round this key reads when nobody has said.
    ///
    /// Newest first is what anyone wants of dates and longest first of lengths, whereas
    /// names want A–Z. One flag with a per-key sense beats two flags nobody sets right.
    public var defaultsToDescending: Bool { self != .name }
}

/// The folder recordings live in, and the few things one can do to them.
///
/// A value over a folder rather than a manager with state: the library *is* the folder,
/// and every operation here is a question asked of the file system at the moment it is
/// asked. Nothing is cached in here, so nothing here can be stale.
///
/// **On names.** A recording's name exists twice — as the package folder's own name and
/// as `RecordingManifest.name` — and it has to, because the Finder can rename the folder
/// and this app cannot stop it. The folder is therefore the source of truth: it is what
/// the user sees everywhere else on the system, what the editor's window title is taken
/// from, and the only one of the two that can change behind this app's back. The manifest
/// keeps a copy so the recording still knows what it is called when it is moved to
/// another Mac, and `rename(_:to:)` writes both so they agree. Where they have drifted
/// anyway, `entries()` shows the folder's name and leaves the manifest alone — reading a
/// library must never write to it.
///
/// **On destruction.** Every operation that changes something goes through `check(_:)`,
/// which refuses anything that is not a `.cuerec` sitting directly in this folder. A
/// screen recording can be the only copy of something, so nothing here unlinks a file:
/// deletion is the Finder's Trash, which the user can undo and this code cannot.
public struct RecordingLibrary: Sendable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    // MARK: - Reading

    /// Every readable take in the folder, in no particular order.
    ///
    /// Unreadable packages are dropped rather than reported: one means a recording that
    /// died mid-write, and an error row for it would arrive once per refresh forever.
    /// Blocking — a manifest read and a directory walk per take — so callers keep it off
    /// the main actor.
    public func entries() -> [RecordingEntry] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                    includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { $0.pathExtension == RecordingPackage.fileExtension }
            .compactMap { url in
                guard let manifest = try? RecordingPackage(url: url).readManifest() else { return nil }
                return RecordingEntry(url: url,
                                      name: url.deletingPathExtension().lastPathComponent,
                                      createdAt: manifest.createdAt,
                                      duration: manifest.duration,
                                      byteCount: Self.size(of: url),
                                      kinds: Set(manifest.tracks.map(\.kind)))
            }
    }

    /// What a package occupies, counted the way the Finder counts it.
    ///
    /// Allocated size rather than logical: a recording is mostly one big file, and the
    /// number beside it should be the number Get Info shows.
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url,
                                                          includingPropertiesForKeys: keys,
                                                          options: []) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Searching and sorting

    /// The list as the window shows it: what matches, in the order asked for.
    ///
    /// One function rather than a filter here and a sort there, because the two are one
    /// idea — "what goes in the list" — and splitting them is how a window ends up
    /// sorting a list it then re-filters.
    public static func arrange(_ entries: [RecordingEntry],
                               matching search: String = "",
                               by order: RecordingOrder = .date,
                               descending: Bool? = nil) -> [RecordingEntry] {
        let descending = descending ?? order.defaultsToDescending
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty
            ? entries
            : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }

        // The key decides the order and the direction flips it; the tie-break is then
        // applied on top, unflipped. Folding the tie-break into the flipped comparison —
        // which is the shorter way to write this, and was the first way it was written —
        // reverses the tie-break too, so two takes from the same second swap places
        // depending on which way the dates are pointing. A list that reorders itself
        // under the pointer is unusable, so ties always read A–Z.
        return matches.sorted { first, second in
            switch order {
            case .date where first.createdAt != second.createdAt:
                return descending ? first.createdAt > second.createdAt : first.createdAt < second.createdAt
            case .length where first.duration != second.duration:
                return descending ? first.duration > second.duration : first.duration < second.duration
            case .name where first.name != second.name:
                return descending ? Self.precedes(second.name, first.name) : Self.precedes(first.name, second.name)
            default:
                // Two takes can share a second — a scripted burst of them will — and can
                // share a length. Same name and the path separates them, so the sort is
                // total and the list is identical between two refreshes of the same folder.
                return first.name == second.name
                    ? first.url.path < second.url.path
                    : Self.precedes(first.name, second.name)
            }
        }
    }

    /// The Finder's comparison: case-insensitive, and "Take 2" before "Take 10".
    private static func precedes(_ first: String, _ second: String) -> Bool {
        first.localizedStandardCompare(second) == .orderedAscending
    }

    // MARK: - Renaming

    /// Checks a name somebody typed, and gives back the one to use.
    ///
    /// Trimmed, because a trailing space is invisible and produces a second recording
    /// that looks identical to the first.
    public static func validate(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RecordingLibraryError.emptyName }
        guard !trimmed.contains("/"), !trimmed.contains(":") else {
            throw RecordingLibraryError.nameContainsPathSeparator
        }
        guard !trimmed.hasPrefix(".") else { throw RecordingLibraryError.nameIsHidden }
        return trimmed
    }

    /// Renames a recording, folder and manifest together.
    ///
    /// The checks happen before anything moves, so the one failure that is likely — a
    /// name already taken — costs nothing. The move is next, and the manifest last: it is
    /// the copy, so failing to update it leaves the recording correctly named everywhere
    /// anybody looks, whereas writing it first and then being refused the move would
    /// leave the recording answering to a name it does not have.
    ///
    /// Renaming to the name it already has is allowed and only rewrites the manifest,
    /// rather than reporting the recording's own folder as a collision.
    ///
    /// - Returns: where the recording now is.
    @discardableResult
    public func rename(_ url: URL, to name: String) throws -> URL {
        try check(url)
        let wanted = try Self.validate(name)
        let destination = folder.appendingPathComponent(wanted)
            .appendingPathExtension(RecordingPackage.fileExtension)

        if destination.standardizedFileURL == url.standardizedFileURL {
            try? RecordingPackage(url: url).rewriteName(wanted)
            return url
        }
        // Asked of the file system rather than of the listing: a case-only change on the
        // usual case-insensitive volume ("demo" → "Demo") is a real rename whose
        // destination reports that it already exists, and `moveItem` handles it.
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)),
           destination.standardizedFileURL.path.lowercased() != url.standardizedFileURL.path.lowercased() {
            throw RecordingLibraryError.nameTaken(wanted)
        }

        try FileManager.default.moveItem(at: url, to: destination)
        try? RecordingPackage(url: destination).rewriteName(wanted)
        return destination
    }

    // MARK: - Duplicating

    /// Copies a take, under the next free "name N".
    ///
    /// The same numbering `RecordingPackage.create` uses, so a duplicate sits beside its
    /// re-takes rather than announcing itself as a different kind of thing. The copy
    /// includes `derived/`, which is regenerable but correct — throwing away a waveform
    /// the copy could have had would make duplicating a take slower than recording one.
    @discardableResult
    public func duplicate(_ url: URL) throws -> URL {
        try check(url)
        let base = url.deletingPathExtension().lastPathComponent
        var candidate = url
        var index = 2
        repeat {
            candidate = folder.appendingPathComponent("\(base) \(index)")
                .appendingPathExtension(RecordingPackage.fileExtension)
            index += 1
        } while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false))

        try FileManager.default.copyItem(at: url, to: candidate)
        try? RecordingPackage(url: candidate)
            .rewriteName(candidate.deletingPathExtension().lastPathComponent)
        return candidate
    }

    // MARK: - Removing

    /// Moves a recording to the Trash.
    ///
    /// The Trash and not `removeItem`, deliberately: this may be the only copy of
    /// something that took an hour to perform, and the Trash is the one undo this code
    /// can offer. Asking the user first is the caller's job — not enforceable here, which
    /// is why it is written down here.
    ///
    /// - Returns: where it landed in the Trash, when the system says.
    @discardableResult
    public func moveToTrash(_ url: URL) throws -> URL? {
        try check(url)
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    // MARK: - The guard every destructive operation goes through

    /// Refuses anything that is not one of this library's recordings.
    ///
    /// Three questions, all cheap and all worth asking every time: is it a `.cuerec`, is
    /// it in this folder — this folder itself, not one beneath it — and is it still
    /// there. Two accidental recordings have already been made by this project's own
    /// bugs; a bug that *deletes* one must not be reachable.
    public func check(_ url: URL) throws {
        guard url.pathExtension == RecordingPackage.fileExtension else {
            throw RecordingLibraryError.notARecording
        }
        let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent == folder.standardizedFileURL.resolvingSymlinksInPath() else {
            throw RecordingLibraryError.outsideLibrary
        }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw RecordingLibraryError.missing
        }
    }
}

extension RecordingPackage {
    /// Puts the manifest's copy of the name back in step with the folder's.
    ///
    /// An extension here rather than a change to `RecordingPackage` itself, because this
    /// is the library's business: the package knows how to write a manifest atomically,
    /// and this is one field of one, read and written back through that same
    /// replace-in-one-step path a finished recording uses.
    public func rewriteName(_ name: String) throws {
        var manifest = try readManifest()
        guard manifest.name != name else { return }
        manifest.name = name
        try write(manifest)
    }
}

/// A run of recordings under one heading — Today, Yesterday, Previous 7 Days, a month — as
/// the library shows them.
public struct RecordingSection: Identifiable, Sendable {
    /// `nil` for the one plain run a non-date order makes.
    public let title: String?
    public let entries: [RecordingEntry]
    public var id: String { title ?? "all" }

    /// Grouped by when they were made while the list is in date order — the way anyone
    /// remembers a take, "the one from yesterday" — and one plain run in any other order,
    /// where headings by date would scatter the sort. Consecutive, so the sort's own order
    /// is kept whichever way round it runs.
    public static func group(_ entries: [RecordingEntry], by order: RecordingOrder,
                             now: Date = .now, calendar: Calendar = .current) -> [RecordingSection] {
        guard order == .date else {
            return entries.isEmpty ? [] : [RecordingSection(title: nil, entries: entries)]
        }
        var sections: [RecordingSection] = []
        for entry in entries {
            let title = heading(for: entry.createdAt, now: now, calendar: calendar)
            if let last = sections.last, last.title == title {
                sections[sections.count - 1] = RecordingSection(title: title, entries: last.entries + [entry])
            } else {
                sections.append(RecordingSection(title: title, entries: [entry]))
            }
        }
        return sections
    }

    /// The heading a recording made at `date` goes under.
    public static func heading(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday), date >= weekAgo, date <= now {
            return "Previous 7 Days"
        }
        var style = Date.FormatStyle.dateTime.month(.wide).year()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
