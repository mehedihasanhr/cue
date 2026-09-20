import AppKit
import os

/// A folder of the user's choosing (in iCloud Drive, Dropbox, a repo…) where the
/// snippets, colors and tasks live as JSON instead of the app container, so another
/// Mac running Klik sees the same. Each store gets a `SyncedFile`: where to read and
/// write, and a watcher that reloads when the file changes underneath it.
@Observable
@MainActor
final class SyncFolder {
    private static let bookmarkKey = "sync.folderBookmark"
    private(set) var url: URL?
    @ObservationIgnored private var accessing = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: resolved.path) {
                url = resolved
                accessing = resolved.startAccessingSecurityScopedResource()
            }
        }
    }

    var isOn: Bool { url != nil }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Sync Here"
        panel.message = "Choose a folder to keep snippets, colors and tasks in — one in iCloud Drive or Dropbox syncs them between Macs"
        panel.directoryURL = url ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        do {
            let bookmark = try chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            stopAccessing()
            url = chosen
            accessing = chosen.startAccessingSecurityScopedResource()
            Log.app.info("Sync folder set to \(chosen.path, privacy: .public)")
        } catch {
            Log.app.error("Could not bookmark the sync folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    func turnOff() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        stopAccessing()
        url = nil
    }

    private func stopAccessing() {
        if accessing { url?.stopAccessingSecurityScopedResource() }
        accessing = false
    }
}

/// One store's file: in the sync folder when there is one, else in the app
/// container. Watches the sync copy and calls `changed` when something other
/// than this app wrote it.
// Not tied to the main actor so the stores (which the tests build nonisolated)
// can own one; the watcher's callback hops to the main actor itself.
nonisolated final class SyncedFile: @unchecked Sendable {
    let name: String
    private let local: URL
    private(set) var url: URL
    private var source: (any DispatchSourceFileSystemObject)?
    private var descriptor: Int32 = -1
    /// The bytes this app last wrote, so its own saves are not taken for changes.
    private var lastWritten: Data?
    var changed: @MainActor (Data) -> Void = { _ in }

    init(name: String, local: URL) {
        self.name = name
        self.local = local
        url = local
    }

    /// Points the file at `folder` (nil: back to the container). Returns the data to
    /// load, if the file there differs from what the store has; a folder without
    /// the file gets the store's current data written to it.
    func relocate(to folder: URL?, current: Data?) -> Data? {
        stopWatching()
        let target = folder?.appendingPathComponent(name) ?? local
        url = target
        defer { if folder != nil { watch() } }
        if FileManager.default.fileExists(atPath: target.path) {
            guard let data = try? Data(contentsOf: target), data != current else { return nil }
            lastWritten = data
            return data
        }
        if let current { try? current.write(to: target, options: .atomic); lastWritten = current }
        return nil
    }

    func write(_ data: Data) {
        lastWritten = data
        try? data.write(to: url, options: .atomic)
    }

    // The file is replaced atomically on every save, so the folder is what to watch.
    private func watch() {
        let folder = url.deletingLastPathComponent()
        descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            // Coalesce bursts (iCloud writes a few times), then compare with what we wrote.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, let data = try? Data(contentsOf: self.url), data != self.lastWritten else { return }
                self.lastWritten = data
                self.changed(data)
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
