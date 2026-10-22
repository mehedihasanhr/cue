import AppKit
import Observation
import os

/// A quick note: one Markdown file. Its name on disk is the note's title, so a
/// folder of notes reads as such anywhere — Finder, iCloud Drive, an Obsidian
/// vault. The first line that says anything is the title (`TaskText`).
nonisolated struct Note: Identifiable, Hashable {
    /// The file's name without its `.md`.
    let id: String
    var text: String
    var createdAt: Date
    var updatedAt: Date

    /// The first line, plain — or the file's name when the text is empty.
    var title: String {
        let line = TaskText.title(of: text)
        return line.isEmpty ? id : line
    }

    /// What follows the title line, plain and on one line — for a card's preview.
    var summary: String { TaskText.summary(of: text) }

    /// The title as a file name: nothing Finder or iCloud objects to, at most 80
    /// characters; a dated name when there is no title.
    static func fileName(for text: String) -> String {
        let title = TaskText.title(of: text)
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.newlines).union(.controlCharacters)
        var name = title.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        if name.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm"
            name = "Note " + formatter.string(from: .now)
        }
        return name
    }
}

/// The notes: Markdown files in one folder — the app container, or a folder of the
/// user's choosing (Settings › Notes), which is how they reach iCloud Drive or an
/// Obsidian vault. The folder is watched, so a note written elsewhere shows up.
@Observable
@MainActor
final class NoteStore {
    private static let bookmarkKey = "notes.folderBookmark"
    /// Newest change first.
    private(set) var notes: [Note] = []
    /// Where the notes are now.
    private(set) var folderURL: URL
    /// Whether the folder is the user's, not the container's.
    var folderIsCustom: Bool { folderURL != localFolder }

    private let localFolder: URL
    @ObservationIgnored private var accessing = false
    @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var descriptor: Int32 = -1
    /// A change this app made: the watcher's next reload need not be announced.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        localFolder = support.appendingPathComponent("Cue/Notes", isDirectory: true)
        folderURL = localFolder
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: resolved.path) {
                folderURL = resolved
                accessing = resolved.startAccessingSecurityScopedResource()
            }
        }
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        reload()
        watch()
    }

    // MARK: - Folder

    /// Asks for a folder and moves the notes there: the files are copied in (those
    /// already there are left as they are) and the container's copies removed.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Keep Notes Here"
        panel.message = "Choose a folder for your notes — one in iCloud Drive syncs them; an Obsidian vault shows them there"
        panel.directoryURL = folderIsCustom ? folderURL : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let chosen = panel.url, chosen != folderURL else { return }
        do {
            let bookmark = try chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            move(to: chosen, accessing: chosen.startAccessingSecurityScopedResource())
            Log.app.info("Notes folder set to \(chosen.path, privacy: .public)")
        } catch {
            Log.app.error("Could not bookmark the notes folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Back to the container; the notes come along.
    func useDefaultFolder() {
        guard folderIsCustom else { return }
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        move(to: localFolder, accessing: false)
    }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    private func move(to target: URL, accessing newAccess: Bool) {
        stopWatching()
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let manager = FileManager.default
        for note in notes {
            let from = fileURL(for: note), to = target.appendingPathComponent(note.id + ".md")
            guard !manager.fileExists(atPath: to.path) else { continue }
            if (try? manager.copyItem(at: from, to: to)) != nil { try? manager.removeItem(at: from) }
        }
        let attachments = folderURL.appendingPathComponent(Self.attachmentsFolder, isDirectory: true)
        if manager.fileExists(atPath: attachments.path) {
            let to = target.appendingPathComponent(Self.attachmentsFolder, isDirectory: true)
            try? manager.createDirectory(at: to, withIntermediateDirectories: true)
            for name in (try? manager.contentsOfDirectory(atPath: attachments.path)) ?? [] where !manager.fileExists(atPath: to.appendingPathComponent(name).path) {
                try? manager.copyItem(at: attachments.appendingPathComponent(name), to: to.appendingPathComponent(name))
            }
        }
        if accessing { folderURL.stopAccessingSecurityScopedResource() }
        accessing = newAccess
        folderURL = target
        reload()
        watch()
    }

    // MARK: - Notes

    func fileURL(for note: Note) -> URL {
        folderURL.appendingPathComponent(note.id + ".md")
    }

    /// Reads the folder's top-level `.md` files.
    func reload() {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? manager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        var loaded: [Note] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            loaded.append(Note(id: url.deletingPathExtension().lastPathComponent, text: text,
                               createdAt: values.creationDate ?? .now, updatedAt: values.contentModificationDate ?? .now))
        }
        loaded.sort { $0.updatedAt > $1.updatedAt }
        if loaded != notes { notes = loaded }
    }

    @discardableResult
    func add(text: String) -> Note? {
        let text = text.trimmingCharacters(in: .newlines)
        guard !TaskText.plain(TaskText.titleLine(of: text)).isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let name = uniqueName(Note.fileName(for: text), except: nil)
        let note = Note(id: name, text: text, createdAt: .now, updatedAt: .now)
        guard write(note) else { return nil }
        notes.insert(note, at: 0)
        return note
    }

    /// Saves new text; a changed title renames the file (the note's id with it).
    @discardableResult
    func update(_ note: Note, text: String) -> Note? {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return add(text: text) }
        let text = text.trimmingCharacters(in: .newlines)
        var updated = notes[index]
        updated.text = text
        updated.updatedAt = .now
        let wanted = Note.fileName(for: text)
        if wanted != note.id, TaskText.title(of: note.text) != TaskText.title(of: text) {
            let name = uniqueName(wanted, except: note.id)
            let renamed = Note(id: name, text: text, createdAt: updated.createdAt, updatedAt: updated.updatedAt)
            guard write(renamed) else { return nil }
            try? FileManager.default.removeItem(at: fileURL(for: note))
            updated = renamed
        } else {
            guard write(updated) else { return nil }
        }
        notes.remove(at: index)
        notes.insert(updated, at: 0)
        return updated
    }

    func delete(_ note: Note) {
        try? FileManager.default.removeItem(at: fileURL(for: note))
        notes.removeAll { $0.id == note.id }
    }

    private func write(_ note: Note) -> Bool {
        do {
            try note.text.write(to: fileURL(for: note), atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.app.error("Could not write note \(note.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// `name`, or `name 2`, `name 3`… when another note has it.
    private func uniqueName(_ name: String, except own: String?) -> String {
        var candidate = name
        var counter = 2
        while candidate != own, FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(candidate + ".md").path) {
            candidate = "\(name) \(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: - Attachments

    static let attachmentsFolder = "attachments"

    /// Saves pasted or dropped image data beside the notes and returns the
    /// reference to write into the Markdown (`attachments/<name>.png`).
    func saveImage(_ data: Data) -> String? {
        let folder = folderURL.appendingPathComponent(Self.attachmentsFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "image \(formatter.string(from: .now)).png"
        let url = folder.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return Self.attachmentsFolder + "/" + name
    }

    /// Copies a dropped file beside the notes; returns its reference.
    func saveAttachment(_ source: URL) -> String? {
        let folder = folderURL.appendingPathComponent(Self.attachmentsFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) \(counter).\(source.pathExtension)")
            counter += 1
        }
        guard (try? FileManager.default.copyItem(at: source, to: url)) != nil else { return nil }
        return Self.attachmentsFolder + "/" + url.lastPathComponent
    }

    /// A reference in a note (`attachments/x.png`, or any path relative to the
    /// folder) as a file.
    func url(for reference: String) -> URL? {
        guard !reference.contains("://") else { return URL(string: reference) }
        let url = folderURL.appendingPathComponent(reference.removingPercentEncoding ?? reference)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Watching

    private func watch() {
        descriptor = open(folderURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            // Coalesce bursts (iCloud writes a few times), then read the folder again.
            self?.reloadTask?.cancel()
            self?.reloadTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }
        source.setCancelHandler { [descriptor = self.descriptor] in close(descriptor) }
        source.resume()
        self.source = source
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
        descriptor = -1
    }
}
