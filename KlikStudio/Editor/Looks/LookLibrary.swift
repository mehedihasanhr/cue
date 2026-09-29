import AppKit
import Foundation
import Observation
import TimelineKit
import UniformTypeIdentifiers

/// The saved looks, as the editor sees them: the store's folder, read once and again
/// whenever something changes.
///
/// One for the app rather than one per window, because the folder is one folder: a look
/// saved in one editor is in the picker of the next, and a file the person renames in
/// the Finder while the app is open shows up when the app comes back to the front.
///
/// Also where the Looks section is *asked* to do things — by its own buttons and by the
/// menu bar — because the section is a SwiftUI view and its private state is reachable
/// from nowhere else. There is one editor window at a time, so one request is enough.
@MainActor
@Observable
final class LookLibrary {
    static let shared = LookLibrary(store: LookStore(folder: LookStore.standardFolder))

    let store: LookStore
    private(set) var saved: [SavedLook] = []

    /// What the Looks section has been asked to put a name to.
    enum Request: Equatable {
        case save
        case rename(SavedLook)
    }

    var request: Request?

    init(store: LookStore) {
        self.store = store
        reload()
        // The Finder is the other editor of this folder, and coming back to the app is
        // the moment its changes are worth showing.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var builtIn: [Look] { Look.builtIn }

    func reload() {
        saved = store.list()
    }

    @discardableResult
    func save(_ look: Look) throws -> SavedLook {
        defer { reload() }
        return try store.save(look)
    }

    @discardableResult
    func rename(_ saved: SavedLook, to name: String) throws -> SavedLook {
        defer { reload() }
        return try store.rename(saved, to: name)
    }

    /// To the Trash, where a person can change their mind.
    func delete(_ saved: SavedLook) throws {
        defer { reload() }
        try store.delete(saved, trashing: true)
    }

    @discardableResult
    func importLook(from url: URL) throws -> SavedLook {
        defer { reload() }
        return try store.importLook(from: url)
    }

    /// Asks for look files and brings them in. The ones that were not looks are
    /// reported together, once, rather than one alert per file.
    func importLooks() throws {
        let panel = NSOpenPanel()
        panel.title = "Import a look"
        panel.prompt = "Import"
        panel.allowedContentTypes = [UTType(filenameExtension: Look.fileExtension) ?? .json, .json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        var refused: [String] = []
        for url in panel.urls {
            do {
                try importLook(from: url)
            } catch {
                refused.append(url.lastPathComponent)
            }
        }
        if !refused.isEmpty {
            throw LookLibrary.ImportFailure(names: refused)
        }
    }

    struct ImportFailure: Error, LocalizedError {
        let names: [String]
        var errorDescription: String? {
            names.count == 1
                ? "“\(names[0])” isn't a look."
                : "These aren't looks: \(names.joined(separator: ", "))."
        }
    }

    func reveal(_ saved: SavedLook) {
        NSWorkspace.shared.activateFileViewerSelecting([saved.url])
    }
}
