import AppKit
import Observation
import os

/// A quick note: one Markdown file. Its name on disk is the note's title, so a
/// folder of notes reads as such anywhere — Finder, iCloud Drive, an Obsidian
/// vault. The first line that says anything is the title (`TaskText`).
nonisolated struct Note: Identifiable, Hashable {
    /// The folder it sits in, relative to the notes folder: "" at the top, else
    /// "Work" or "Work/Ideas".
    var folder: String
    /// The file's name without its `.md`.
    var name: String
    var text: String
    var createdAt: Date
    var updatedAt: Date

    /// Where it is, as one string: the path from the notes folder without the `.md`.
    /// Two notes may share a name in different folders, so the path is what is
    /// unique, and it is what the dashboard holds on to.
    var id: String { folder.isEmpty ? name : folder + "/" + name }

    /// The first line, plain — or the file's name when the text is empty.
    var title: String {
        let line = TaskText.title(of: text)
        return line.isEmpty ? name : line
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
    /// Every folder under the notes folder, as paths relative to it ("Work",
    /// "Work/Ideas"), in order. Empty ones are here too — a folder made and not yet
    /// written in is still a folder.
    private(set) var folders: [String] = []
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
            // A note in a sub-folder needs that folder made on the other side first.
            try? manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? manager.copyItem(at: from, to: to)) != nil { try? manager.removeItem(at: from) }
        }
        // Folders with nothing in them yet would be lost by the loop above.
        for folder in folders {
            try? manager.createDirectory(at: target.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
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

    /// Reads every `.md` file under the notes folder, sub-folders and all. The
    /// attachments folder is skipped: what is in it belongs to the notes, and is not
    /// one.
    func reload() {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        var loaded: [Note] = []
        var found: Set<String> = []
        let root = folderURL.standardizedFileURL.path
        let walker = manager.enumerator(at: folderURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = walker?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let relative = Self.relativePath(of: url, under: root)
            if values.isDirectory == true {
                // Nothing inside the attachments folder is a note.
                if relative == Self.attachmentsFolder { walker?.skipDescendants(); continue }
                found.insert(relative)
                continue
            }
            guard values.isRegularFile == true, url.pathExtension.lowercased() == "md",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let folder = (relative as NSString).deletingLastPathComponent
            loaded.append(Note(folder: folder, name: url.deletingPathExtension().lastPathComponent, text: text,
                               createdAt: values.creationDate ?? .now, updatedAt: values.contentModificationDate ?? .now))
        }
        loaded.sort { $0.updatedAt > $1.updatedAt }
        let sortedFolders = found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if loaded != notes { notes = loaded }
        if sortedFolders != folders { folders = sortedFolders }
    }

    /// A file's path relative to the notes folder, with no leading slash.
    private static func relativePath(of url: URL, under root: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return url.lastPathComponent }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Folders of notes

    /// The notes directly in `folder` ("" is the top), newest change first.
    func notes(in folder: String) -> [Note] {
        notes.filter { $0.folder == folder }
    }

    /// The folders directly inside `folder` ("" is the top), by name.
    func subfolders(of folder: String) -> [String] {
        folders.filter { ($0 as NSString).deletingLastPathComponent == folder }
    }

    /// Whether `folder` holds anything at all — what decides if it gets a twisty.
    func isEmpty(_ folder: String) -> Bool {
        subfolders(of: folder).isEmpty && notes(in: folder).isEmpty
    }

    /// Makes a folder inside `parent` and returns its path; a name already taken gets
    /// a number, as a note's does.
    @discardableResult
    func createFolder(named name: String, in parent: String = "") -> String? {
        let wanted = Self.safeName(name, fallback: "Folder")
        var candidate = wanted
        var counter = 2
        while folders.contains(parent.isEmpty ? candidate : parent + "/" + candidate) {
            candidate = "\(wanted) \(counter)"
            counter += 1
        }
        let path = parent.isEmpty ? candidate : parent + "/" + candidate
        do {
            try FileManager.default.createDirectory(at: folderURL.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true)
        } catch {
            Log.app.error("Could not make the notes folder \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        reload()
        return path
    }

    /// Renames a folder in place; its notes and sub-folders come along.
    @discardableResult
    func renameFolder(_ folder: String, to name: String) -> String? {
        let parent = (folder as NSString).deletingLastPathComponent
        let wanted = Self.safeName(name, fallback: (folder as NSString).lastPathComponent)
        let path = parent.isEmpty ? wanted : parent + "/" + wanted
        guard path != folder else { return folder }
        guard !folders.contains(path) else { return nil }
        do {
            try FileManager.default.moveItem(at: folderURL.appendingPathComponent(folder, isDirectory: true),
                                             to: folderURL.appendingPathComponent(path, isDirectory: true))
        } catch {
            Log.app.error("Could not rename the notes folder \(folder, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        reload()
        return path
    }

    /// Removes a folder and everything in it.
    func deleteFolder(_ folder: String) {
        guard !folder.isEmpty else { return }
        try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(folder, isDirectory: true))
        reload()
    }

    /// How many notes a folder holds, its sub-folders included.
    func noteCount(in folder: String) -> Int {
        guard !folder.isEmpty else { return notes.count }
        return notes.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }.count
    }

    /// Moves a note into `folder`; its name is kept unless something there has it.
    @discardableResult
    func move(_ note: Note, to folder: String) -> Note? {
        guard note.folder != folder else { return note }
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return nil }
        let name = uniqueName(note.name, in: folder, except: nil)
        var moved = notes[index]
        moved.folder = folder
        moved.name = name
        guard write(moved) else { return nil }
        try? FileManager.default.removeItem(at: fileURL(for: note))
        notes[index] = moved
        return moved
    }

    /// Nothing Finder or iCloud objects to, at most 80 characters.
    private static func safeName(_ name: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.newlines).union(.controlCharacters)
        var clean = name.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if clean.count > 80 { clean = String(clean.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return clean.isEmpty ? fallback : clean
    }

    // MARK: - Notes

    /// A new note, in `folder` ("" is the top).
    @discardableResult
    func add(text: String, in folder: String = "") -> Note? {
        let text = text.trimmingCharacters(in: .newlines)
        guard !TaskText.plain(TaskText.titleLine(of: text)).isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let name = uniqueName(Note.fileName(for: text), in: folder, except: nil)
        let note = Note(folder: folder, name: name, text: text, createdAt: .now, updatedAt: .now)
        guard write(note) else { return nil }
        notes.insert(note, at: 0)
        if !folder.isEmpty, !folders.contains(folder) { reload() }
        return note
    }

    /// Saves new text; a changed title renames the file (the note's id with it). The
    /// note stays in its folder.
    @discardableResult
    func update(_ note: Note, text: String) -> Note? {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return add(text: text, in: note.folder) }
        let text = text.trimmingCharacters(in: .newlines)
        var updated = notes[index]
        updated.text = text
        updated.updatedAt = .now
        let wanted = Note.fileName(for: text)
        if wanted != note.name, TaskText.title(of: note.text) != TaskText.title(of: text) {
            let name = uniqueName(wanted, in: note.folder, except: note.name)
            var renamed = updated
            renamed.name = name
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
            let url = fileURL(for: note)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try note.text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.app.error("Could not write note \(note.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// `name`, or `name 2`, `name 3`… when another note in the same folder has it.
    private func uniqueName(_ name: String, in folder: String, except own: String?) -> String {
        let directory = folder.isEmpty ? folderURL : folderURL.appendingPathComponent(folder, isDirectory: true)
        var candidate = name
        var counter = 2
        while candidate != own, FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate + ".md").path) {
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
        // The Markdown that shows it (the editor inserts it as a line of its own), the
        // name's spaces escaped so the link stays one piece in any Markdown reader.
        return "![image](\(Self.reference(name)))"
    }

    /// `attachments/<name>`, escaped for a Markdown link; `url(for:)` reads it back.
    private static func reference(_ name: String) -> String {
        attachmentsFolder + "/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
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
        let name = url.lastPathComponent
        return "[\(name.replacingOccurrences(of: "]", with: ")"))](\(Self.reference(name)))"
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
