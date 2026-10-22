import AppKit
import Observation
import os
import RecordKit

/// Google Drive as a place recordings are backed up to.
///
/// One per app — the library, Settings, the recorder and the editor all ask the same
/// object — so it is a shared instance rather than something threaded through four
/// window controllers.
///
/// A recording goes up as a folder, `Cue Studio/<name>/`, mirroring the package: the
/// manifest, the media and the telemetry, so a recording restored from Drive opens like
/// any other. `derived/` stays behind; it is caches, and remade on open. The copy on this
/// Mac is never touched — Drive is the backup, not the library.
@Observable
final class DriveStorage {
    static let shared = DriveStorage()

    /// Where one recording is, as far as Drive goes.
    enum Status: Equatable {
        case none
        case queued
        case uploading(Double)
        case uploaded(link: URL?)
        case failed(String)
    }

    private enum Key {
        static let email = "drive.email"
        static let autoUpload = "drive.autoUpload"
        static let rootFolder = "drive.rootFolder"
        static let pending = "drive.pending"
        static let refreshToken = "google.drive.refreshToken"
    }

    private let defaults = UserDefaults.standard
    let oauth = GoogleOAuth.configured
    var isConfigured: Bool { oauth != nil }

    /// The Google account connected, by address; nil when none is.
    private(set) var email: String?
    var isConnected: Bool { email != nil }
    private(set) var isConnecting = false
    /// Why the last attempt to connect failed — shown under the Connect button.
    private(set) var connectError: String?

    /// Every recording kept goes up by itself. On by default: connecting Drive at all is
    /// the user saying they want their recordings there.
    var uploadsAutomatically: Bool {
        didSet { defaults.set(uploadsAutomatically, forKey: Key.autoUpload) }
    }

    /// Recordings waiting or going up, keyed by `key(_:)`, in order.
    private(set) var queue: [URL] = []
    private var phases: [String: Status] = [:]
    /// The last thing that went wrong, for Settings.
    private(set) var lastFailure: (name: String, message: String)?

    /// Bumped when a recording's Drive record changes on disk, so views reading
    /// `status(for:)` look again. The records themselves are a cache nobody observes.
    private var revision = 0
    @ObservationIgnored private var records: [String: DriveRecord?] = [:]

    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var current: URL?
    @ObservationIgnored private var accessToken: (value: String, expires: Date)?
    @ObservationIgnored private let drive = GoogleDrive { force in
        try await DriveStorage.shared.validAccessToken(forceRefresh: force)
    }

    private init() {
        email = defaults.string(forKey: Key.email)
        uploadsAutomatically = defaults.object(forKey: Key.autoUpload) as? Bool ?? true
    }

    // MARK: - Connecting

    func connect() {
        guard let oauth, !isConnecting else { return }
        isConnecting = true
        connectError = nil
        Task {
            defer { isConnecting = false }
            do {
                let tokens = try await oauth.signIn()
                guard let refresh = tokens.refreshToken else {
                    throw DriveError.http(0, "Google sent no lasting sign-in. Try connecting again.")
                }
                StudioKeychain.set(refresh, for: Key.refreshToken)
                accessToken = (tokens.accessToken, tokens.expiresAt)
                let address = tokens.email ?? "your Google account"
                if address != email { defaults.removeObject(forKey: Key.rootFolder) }
                email = address
                defaults.set(address, forKey: Key.email)
                startWorker()
            } catch is CancellationError {
                // Closed the sign-in window: not an error worth a sentence.
            } catch {
                connectError = error.localizedDescription
            }
        }
    }

    /// Forgets the account here and asks Google to revoke the grant. Recordings already
    /// in Drive stay there; nothing on this Mac is touched.
    func disconnect() {
        worker?.cancel()
        worker = nil
        let refresh = StudioKeychain.get(Key.refreshToken)
        StudioKeychain.set(nil, for: Key.refreshToken)
        if let refresh, let oauth { Task { await oauth.revoke(refresh) } }
        accessToken = nil
        email = nil
        defaults.removeObject(forKey: Key.email)
        defaults.removeObject(forKey: Key.rootFolder)
        for url in queue { phases[key(url)] = nil }
        queue = []
        current = nil
        lastFailure = nil
        savePending()
    }

    /// An access token good for at least another minute, refreshed when it is not.
    func validAccessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let accessToken, accessToken.expires.timeIntervalSinceNow > 60 {
            return accessToken.value
        }
        guard let oauth else { throw DriveError.notConfigured }
        guard isConnected, let refresh = StudioKeychain.get(Key.refreshToken) else { throw DriveError.signedOut }
        do {
            let tokens = try await oauth.refresh(refresh)
            accessToken = (tokens.accessToken, tokens.expiresAt)
            return tokens.accessToken
        } catch DriveError.signedOut {
            // Revoked from the Google account page. Say so, rather than failing every
            // upload with a 401 from here on.
            disconnect()
            connectError = DriveError.signedOut.localizedDescription
            throw DriveError.signedOut
        }
    }

    // MARK: - What the rest of the app tells it

    /// Picks up uploads the app quit in the middle of.
    func resumeAtLaunch() {
        let paths = defaults.stringArray(forKey: Key.pending) ?? []
        guard isConnected, !paths.isEmpty else { return }
        for path in paths {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: path) { enqueue(url) }
        }
    }

    /// A take has just been written. Up it goes, if that is what the user asked for and
    /// the take is one they are keeping — a draft waits for `recordingKept`, since one
    /// nobody saves is deleted.
    func recordingFinished(_ package: URL) {
        guard isConnected, uploadsAutomatically, !RecordingKeep.isUnsaved(package) else { return }
        enqueue(package)
    }

    /// A draft has been saved.
    func recordingKept(_ package: URL) {
        guard isConnected, uploadsAutomatically else { return }
        enqueue(package)
    }

    /// A draft has been thrown away: it must not go up, and must stop if it is going.
    func recordingDiscarded(_ package: URL) {
        cancel(package)
    }

    // MARK: - What the user asks for

    /// Upload to Google Drive, from Recordings. Not connected, it takes them to where
    /// they can connect.
    func upload(_ package: URL) {
        guard isConnected else {
            StudioController.openSettings(.storage)
            return
        }
        enqueue(package)
    }

    func cancel(_ package: URL) {
        let id = key(package)
        queue.removeAll { key($0) == id }
        phases[id] = nil
        if let current, key(current) == id {
            worker?.cancel()
            worker = nil
            self.current = nil
            startWorker()
        }
        savePending()
    }

    func status(for package: URL) -> Status {
        _ = revision
        let id = key(package)
        if let phase = phases[id] { return phase }
        guard let record = record(for: package), record.isComplete else { return .none }
        return .uploaded(link: record.folderLink.flatMap(URL.init(string:)))
    }

    func copyLink(for package: URL) {
        guard case let .uploaded(link?) = status(for: package) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    func openInDrive(_ package: URL) {
        guard case let .uploaded(link?) = status(for: package) else { return }
        NSWorkspace.shared.open(link)
    }

    /// The Cue Studio folder in Drive, once there is one.
    var rootFolderLink: URL? {
        defaults.string(forKey: Key.rootFolder).flatMap { URL(string: "https://drive.google.com/drive/folders/\($0)") }
    }

    /// The one going up now, and how far along.
    var activeUpload: (name: String, progress: Double)? {
        guard let first = queue.first, case let .uploading(progress) = phases[key(first)] else { return nil }
        return (first.deletingPathExtension().lastPathComponent, progress)
    }

    // MARK: - The queue

    private func enqueue(_ package: URL) {
        let id = key(package)
        guard !queue.contains(where: { key($0) == id }) else { return }
        queue.append(package)
        phases[id] = .queued
        savePending()
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, isConnected, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    /// One at a time, in order: a Mac uploading four recordings at once finishes none of
    /// them sooner and makes every one of them a failure when the network drops.
    private func drain() async {
        while let next = queue.first, !Task.isCancelled {
            current = next
            let id = key(next)
            phases[id] = .uploading(0)
            do {
                try await upload(package: next)
                phases[id] = nil
                lastFailure = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                phases[id] = .failed(error.localizedDescription)
                lastFailure = (next.deletingPathExtension().lastPathComponent, error.localizedDescription)
                StudioLog.app.error("Drive upload failed: \(error.localizedDescription, privacy: .public)")
            }
            queue.removeAll { key($0) == id }
            current = nil
            savePending()
        }
        // A cancelled worker has already been replaced, or deliberately stopped.
        if !Task.isCancelled { worker = nil }
    }

    private func upload(package: URL) async throws {
        guard let email else { throw DriveError.signedOut }
        let files = DriveRecord.files(in: package)
        let total = max(files.reduce(0) { $0 + $1.size }, 1)
        let name = package.deletingPathExtension().lastPathComponent

        // A record from another account points at folders this one cannot see.
        var record = record(for: package).flatMap { $0.account == email ? $0 : nil }
            ?? DriveRecord(account: email)
        record.uploadedAt = nil

        let root = try await rootFolder()
        if let id = record.folderID, let folder = try await drive.folder(id) {
            if record.name != name { try await drive.rename(id, to: name) }
            record.folderLink = folder.webViewLink
        } else {
            let folder = try await drive.createFolder(named: name, in: root)
            record.folderID = folder.id
            record.folderLink = folder.webViewLink
            record.folders = [:]
            record.files = [:]
        }
        record.name = name
        try save(record, in: package)

        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            if record.files[file.path]?.matches(file) == true {
                done += file.size
                continue
            }
            let parent = try await folder(for: file.directory, in: &record)
            let base = done
            let id = try await drive.upload(package.appendingPathComponent(file.path),
                                            named: file.name, in: parent,
                                            replacing: record.files[file.path]?.id) { sent in
                Task { @MainActor in
                    DriveStorage.shared.report(Double(base + sent) / Double(total), for: package)
                }
            }
            done += file.size
            record.files[file.path] = .init(id: id, size: file.size, modified: file.modified)
            // Written after every file, so an upload the app quits in the middle of
            // carries on from the file it was on.
            try save(record, in: package)
        }
        // Files gone from the package since the last upload stay in Drive: a backup
        // that deletes is one a mistake here can empty.
        record.uploadedAt = .now
        try save(record, in: package)
    }

    private func report(_ progress: Double, for package: URL) {
        let id = key(package)
        guard case .uploading = phases[id] else { return }
        phases[id] = .uploading(min(progress, 1))
    }

    /// The Cue Studio folder at the top of the user's Drive, made the first time.
    private func rootFolder() async throws -> String {
        if let id = defaults.string(forKey: Key.rootFolder), try await drive.folder(id) != nil { return id }
        let folder = try await drive.findFolder(named: "Cue Studio", in: "root")
        let id: String
        if let folder {
            id = folder.id
        } else {
            id = try await drive.createFolder(named: "Cue Studio", in: "root").id
        }
        defaults.set(id, forKey: Key.rootFolder)
        return id
    }

    /// The Drive folder for a directory inside the package — `media`, `telemetry` —
    /// made the first time it is needed.
    private func folder(for directory: String, in record: inout DriveRecord) async throws -> String {
        guard let packageFolder = record.folderID else { throw DriveError.http(0, "The recording's Drive folder is missing.") }
        guard !directory.isEmpty else { return packageFolder }
        if let id = record.folders[directory] { return id }
        var parent = packageFolder
        var path = ""
        for part in directory.split(separator: "/").map(String.init) {
            path = path.isEmpty ? part : "\(path)/\(part)"
            if let id = record.folders[path] {
                parent = id
            } else {
                parent = try await drive.createFolder(named: part, in: parent).id
                record.folders[path] = parent
            }
        }
        return parent
    }

    // MARK: - Records

    private func record(for package: URL) -> DriveRecord? {
        let id = key(package)
        if let cached = records[id] { return cached }
        let record = DriveRecord.read(from: package)
        records[id] = record
        return record
    }

    private func save(_ record: DriveRecord, in package: URL) throws {
        try record.write(to: package)
        records[key(package)] = record
        revision += 1
    }

    private func savePending() {
        defaults.set(queue.map { $0.path(percentEncoded: false) }, forKey: Key.pending)
    }

    /// One spelling per package, whatever the URL came with — a trailing slash, `..`.
    private func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// What has gone up from one recording, kept inside its package as `.drive.json`.
///
/// Inside rather than in defaults so it travels with the recording through a rename or
/// a move, the way the `unsaved` marker does. A duplicate has it taken out — see
/// `LibraryCatalog.duplicate` — or uploading the copy would overwrite the original.
nonisolated struct DriveRecord: Codable, Equatable, Sendable {
    static let fileName = ".drive.json"

    var account: String
    var name: String?
    var folderID: String?
    var folderLink: String?
    /// Set when every file is up; nil while an upload is under way or was cut short.
    var uploadedAt: Date?
    /// Drive folder IDs for the package's subfolders, by path.
    var folders: [String: String] = [:]
    var files: [String: File] = [:]

    var isComplete: Bool { uploadedAt != nil && folderID != nil }

    struct File: Codable, Equatable, Sendable {
        var id: String
        var size: Int64
        var modified: Date

        func matches(_ local: LocalFile) -> Bool {
            size == local.size && abs(modified.timeIntervalSince(local.modified)) < 1
        }
    }

    struct LocalFile: Equatable, Sendable {
        var path: String
        var size: Int64
        var modified: Date
        var name: String { (path as NSString).lastPathComponent }
        var directory: String { (path as NSString).deletingLastPathComponent }
    }

    init(account: String) { self.account = account }

    static func read(from package: URL) -> DriveRecord? {
        guard let data = try? Data(contentsOf: package.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DriveRecord.self, from: data)
    }

    func write(to package: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: package.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static func remove(from package: URL) {
        try? FileManager.default.removeItem(at: package.appendingPathComponent(fileName))
    }

    /// The files in a package worth backing up: everything but the caches, the app's own
    /// markers and empty files.
    static func files(in package: URL) -> [LocalFile] {
        let base = package.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: package, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [LocalFile] = []
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            if relative == "derived" || relative.hasPrefix("derived/") {
                walker.skipDescendants()
                continue
            }
            guard relative != "unsaved",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0 else { continue }
            files.append(LocalFile(path: relative, size: Int64(size), modified: values.contentModificationDate ?? .distantPast))
        }
        // The manifest last: a folder in Drive with a manifest is one whose media is all there.
        return files.sorted { lhs, rhs in
            if (lhs.path == "manifest.json") != (rhs.path == "manifest.json") { return rhs.path == "manifest.json" }
            return lhs.path < rhs.path
        }
    }
}
