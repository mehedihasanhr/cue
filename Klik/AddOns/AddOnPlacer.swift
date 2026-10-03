import AppKit
import AppleArchive
import CoreServices
import Foundation
import System

/// Installs a downloaded add-on into a folder the user lets Klik use — the Applications
/// folder, normally.
///
/// Klik is sandboxed, so it can neither mount a disk image nor run an installer
/// package, and it has no access to /Applications of its own. What it can do is ask:
/// the open panel the user answers is the permission, and the grant is kept as a
/// security-scoped bookmark so an update does not ask again. The release is an Apple
/// Archive, which Klik unpacks itself; the app inside is checked — the right bundle, and
/// signed by the team that signs Klik — before anything is put in the folder.
///
/// What it cannot do is clear the quarantine flag macOS puts on what a sandboxed app
/// writes, so a build that is not notarized still meets Gatekeeper on its first launch.
@MainActor
enum AddOnPlacer {
    private static let bookmarkKey = "addOnInstallFolderBookmark"

    /// The folder to install into: the one granted before, or asked for now. `nil` when
    /// the user declines, which is the answer "don't install".
    static func installFolder(for addOn: AddOn, release: AddOnRelease) -> URL? {
        if let saved = savedFolder() { return saved }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Install"
        let size = ByteCountFormatStyle(style: .file).format(Int64(release.bytes))
        panel.message = "Klik will download \(addOn.name) \(release.version) (\(size)) and install it in this folder. Choose Install to allow it."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        save(url)
        return url
    }

    /// Unpacks `archive`, checks the app inside, and puts it in `folder` — replacing an
    /// older copy, which goes to the Trash. Returns where it was installed.
    static func place(_ archive: URL, addOn: AddOn, in folder: URL) async throws(AddOnError) -> URL {
        let staging = AddOnDownloads.folder.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try await unpack(archive, into: staging)
        } catch {
            throw .installFailed("the download couldn't be unpacked (\(error.localizedDescription))")
        }

        let contents = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw .installFailed("there was no app in the download")
        }
        guard Bundle(url: app)?.bundleIdentifier == addOn.bundleID else {
            throw .installFailed("the download held a different app")
        }
        if let reason = LaunchServicesAddOnLocator.untrustedReason(for: app) {
            throw .untrusted(reason)
        }

        try await quitRunningCopies(of: addOn)

        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let destination = folder.appendingPathComponent(app.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                // The Trash rather than gone: an update that turns out worse can be undone.
                do {
                    try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
                } catch {
                    try FileManager.default.removeItem(at: destination)
                }
            }
            try FileManager.default.moveItem(at: app, to: destination)
        } catch {
            throw .installFailed(error.localizedDescription)
        }
        // So "where is Klik Studio?" has the new answer at once rather than whenever
        // LaunchServices next notices the folder changed.
        LSRegisterURL(destination as CFURL, true)
        try? FileManager.default.removeItem(at: archive)
        return destination
    }

    /// Unpacks an Apple Archive in-process, off the main thread.
    private static func unpack(_ archive: URL, into folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = FilePath(archive.path(percentEncoded: false))
        let destination = FilePath(folder.path(percentEncoded: false))
        try await Task.detached {
            guard let file = ArchiveByteStream.fileStream(path: source, mode: .readOnly, options: [],
                                                          permissions: FilePermissions(rawValue: 0o644)) else {
                throw AddOnError.installFailed("couldn't open the download")
            }
            defer { try? file.close() }
            guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else {
                throw AddOnError.installFailed("the download isn't compressed as expected")
            }
            defer { try? decompressed.close() }
            guard let decoded = ArchiveStream.decodeStream(readingFrom: decompressed) else {
                throw AddOnError.installFailed("the download isn't an archive")
            }
            defer { try? decoded.close() }
            guard let extractor = ArchiveStream.extractStream(extractingTo: destination,
                                                              flags: [.ignoreOperationNotPermitted]) else {
                throw AddOnError.installFailed("couldn't unpack into the staging folder")
            }
            defer { try? extractor.close() }
            _ = try ArchiveStream.process(readingFrom: decoded, writingTo: extractor)
        }.value
    }

    /// An update cannot replace an app that is running. Asked to quit, and given a few
    /// seconds; if it will not, the user is told to quit it themselves.
    private static func quitRunningCopies(of addOn: AddOn) async throws(AddOnError) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: addOn.bundleID)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if running.contains(where: { !$0.isTerminated }) {
            throw .installFailed("\(addOn.name) is still open. Quit it, then try again.")
        }
    }

    // MARK: - The granted folder

    private static func save(_ folder: URL) {
        guard let bookmark = try? folder.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    private static func savedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
        if stale {
            let accessing = url.startAccessingSecurityScopedResource()
            save(url)
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }
}
