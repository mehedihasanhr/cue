import AppKit
import Foundation
import Observation
import os
import RecordKit

/// What the Recordings window is looking at.
///
/// The window's own state — the takes, the search field, the sort, and the two questions
/// it has to ask before it destroys anything. The operations themselves are
/// `RecordingLibrary` in RecordKit, where they can be tested without a window; this is
/// the part that could only be exercised by clicking.
///
/// Its own object rather than more of `RecorderModel`: that one is shared with the
/// floating bar and answers "what can I record?", which is a different question from
/// "what have I recorded?". `RecorderModel.recents` is left exactly as it was — the bar
/// refreshes it, and quietly changing what it means from underneath would be a change to
/// a working feature nobody asked for.
@MainActor
@Observable
final class LibraryCatalog {
    private(set) var entries: [RecordingEntry] = []
    /// Takes that never finished, shown above the others with a way to recover them.
    /// Never the one being recorded right now, which has a marker for the best of reasons.
    private(set) var interrupted: [InterruptedTake] = []
    /// True until the first listing has come back, so an empty folder and a folder that
    /// has not been read yet do not both draw "No recordings yet".
    private(set) var isLoading = true

    var search = ""
    var order: RecordingOrder = .date {
        // Switching the key resets the direction to what that key ought to mean: newest
        // first for dates, A–Z for names. Carrying a direction across keys gives you
        // oldest-first the moment you sort by name and back again.
        didSet { descending = order.defaultsToDescending }
    }
    var descending = RecordingOrder.date.defaultsToDescending

    /// What is on screen: filtered and sorted in one place, by the same function the tests
    /// exercise.
    var visible: [RecordingEntry] {
        RecordingLibrary.arrange(entries, matching: search, by: order, descending: descending)
    }

    /// A recording the user is renaming, and the name they have typed so far.
    var renaming: RecordingEntry?
    var draftName = ""

    /// A recording the user has asked to delete, held here because nothing is deleted
    /// until they have confirmed it.
    var deleting: RecordingEntry?

    /// Something that went wrong, in the words `RecordingLibraryError` gives.
    var problem: String?

    private var folder: URL
    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "library")

    init(folder: URL) { self.folder = folder }

    /// Watches the library folder for takes appearing, disappearing or being renamed.
    ///
    /// The list used to be read only when the window appeared and when a recording
    /// finished. A take deleted any other way — an unkept draft discarded when its editor
    /// closed, or a folder removed in the Finder — stayed on the list, and opening it
    /// opened an editor that could not find its manifest.
    private var watcher: FolderWatcher?

    /// Starts following the folder, and stops when the window's task is cancelled.
    func follow() async {
        let watcher = FolderWatcher { [weak self] in
            Task { await self?.reload() }
        }
        self.watcher = watcher
        watcher.watch(folder)
        // Held until the window goes away and cancels this task.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        watcher.stop()
        if self.watcher === watcher { self.watcher = nil }
    }

    private var library: RecordingLibrary { RecordingLibrary(folder: folder) }

    /// Follows the library folder if it is changed in Settings while the window is open.
    func look(at folder: URL) async {
        guard folder != self.folder else { return }
        self.folder = folder
        watcher?.watch(folder)
        entries = []
        await reload()
    }

    /// Reads the folder again.
    ///
    /// Off the main actor: it opens a manifest and walks a directory tree per take, which
    /// is a hitch in a window somebody is typing into once a library has thirty of them.
    ///
    /// Detached on purpose, which is unusual enough to be worth saying why: this app is
    /// main-actor by default, and inheriting isolation is the one thing this call must not
    /// do. What it carries across is a `RecordingLibrary`, which is a `Sendable` value over
    /// a folder path, and what comes back is an array of values — so there is nothing here
    /// for the detachment to lose.
    func reload() async {
        let library = library
        let live = StudioAppDelegate.shared?.studio?.session.packageURL.map { Set([$0]) } ?? []
        (entries, interrupted) = await Task.detached(priority: .userInitiated) {
            // A take that finished but kept its marker is an ordinary entry; the launch
            // check tidies the marker away.
            (library.entries(), library.interruptedTakes(excluding: live).filter { !$0.hasFinished })
        }.value
        isLoading = false
    }

    // MARK: - Opening

    /// The one thing a row has always done, and the reason this window exists.
    ///
    /// Through the delegate's static, which reaches the editor windows the app owns. Not
    /// via `NSApp.delegate` — that cast fails here, because `@NSApplicationDelegateAdaptor`
    /// does not install the object there, and it is exactly what made clicking a recording
    /// do nothing at all.
    func open(_ entry: RecordingEntry) {
        // Gone since the list was read: say so and take it off the list, rather than open
        // an editor window whose only content is "couldn't open this recording".
        guard FileManager.default.fileExists(atPath: entry.url.appendingPathComponent("manifest.json")
            .path(percentEncoded: false)) else {
            problem = "“\(entry.name)” is no longer in your recordings folder."
            Task { await reload() }
            return
        }
        StudioAppDelegate.openEditor(entry.url)
    }

    func reveal(_ entry: RecordingEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    // MARK: - Renaming

    func beginRenaming(_ entry: RecordingEntry) {
        guard !refuseWhileOpen(entry, verb: "renamed") else { return }
        draftName = entry.name
        renaming = entry
    }

    /// Commits the rename the sheet was collecting.
    ///
    /// Asked again whether an editor is open, rather than trusting the answer from when
    /// the field appeared: a sheet is somewhere a user can sit for a minute, and an editor
    /// can be opened from the bar in that minute.
    func commitRename() async {
        guard let entry = renaming else { return }
        renaming = nil
        guard !refuseWhileOpen(entry, verb: "renamed") else { return }
        do {
            try library.rename(entry.url, to: draftName)
        } catch {
            report(error)
        }
        await reload()
    }

    // MARK: - Duplicating

    /// Safe with the editor open, and the only one of the three that is: it writes a new
    /// package and touches nothing the editor is holding.
    func duplicate(_ entry: RecordingEntry) async {
        do {
            try library.duplicate(entry.url)
        } catch {
            report(error)
        }
        await reload()
    }

    // MARK: - Deleting

    func askToDelete(_ entry: RecordingEntry) {
        guard !refuseWhileOpen(entry, verb: "deleted") else { return }
        deleting = entry
    }

    /// Moves the confirmed recording to the Trash.
    ///
    /// Only ever reached from the confirmation button. `RecordingLibrary.moveToTrash`
    /// checks the file is one of ours and in this folder before it moves anything, and
    /// moves it to the Trash rather than unlinking it, so even a bug that got this far
    /// with the wrong recording is something the user can put back.
    func confirmDelete() async {
        guard let entry = deleting else { return }
        deleting = nil
        guard !refuseWhileOpen(entry, verb: "deleted") else { return }
        do {
            try library.moveToTrash(entry.url)
            Self.log.notice("Moved a recording to the Trash")
        } catch {
            report(error)
        }
        await reload()
    }

    // MARK: - Recordings with an editor open

    /// Refuses to rename or delete a take that is being edited, and says so.
    ///
    /// `EditorSession.packageURL` is a `let`, and `EditorModel` holds the same URL in the
    /// document it saves through — so moving the folder out from under an open editor
    /// leaves that window writing its timeline, its imported sounds and its exports to a
    /// path that no longer exists. Deleting it is worse: the editor keeps playing from
    /// file handles that are still open and loses everything at the next save.
    ///
    /// The other options were considered and are worse. Telling the editor its new URL
    /// means changing the editor, which is not this window's business and would have to be
    /// right in a dozen places. Closing the window for them can lose work, because the
    /// editor saves when its Save button is pressed and not before. So the honest answer
    /// is the small one: the take being edited is not renamed, and the window says which
    /// window to close.
    private func refuseWhileOpen(_ entry: RecordingEntry, verb: String) -> Bool {
        guard Self.hasOpenEditor(entry.url) else { return false }
        problem = "\u{201C}\(entry.name)\u{201D} is open in the editor. Close that window first \u{2014} a recording can\u{2019}t be \(verb) while it is being edited."
        return true
    }

    /// Whether a recording has an editor window on screen.
    ///
    /// Asked of AppKit's window list rather than of `EditorWindows`, which keeps its map
    /// of open editors private. The window list is the fact that matters here anyway: a
    /// window that is on screen is a window that is holding this package, whatever any
    /// bookkeeping elsewhere believes. Visibility is part of the test because an editor's
    /// window is `isReleasedWhenClosed = false`, so a closed one can linger in the list
    /// for a turn of the run loop after its controller has let it go.
    ///
    /// Resolved before comparing, for the same reason `EditorWindows` resolves its key:
    /// the library's URL and the URL the editor was opened with can be two spellings of
    /// one recording.
    private static func hasOpenEditor(_ url: URL) -> Bool {
        let wanted = url.standardizedFileURL.resolvingSymlinksInPath()
        return NSApp.windows.contains { window in
            guard window.isVisible, let controller = window.delegate as? EditorWindowController else { return false }
            return controller.session.packageURL.standardizedFileURL.resolvingSymlinksInPath() == wanted
        }
    }

    // MARK: - Saying what went wrong

    private func report(_ error: any Error) {
        // `RecordingLibraryError` writes its own sentences — "There's already a recording
        // called X" — so they are shown as they are rather than wrapped in a second one.
        problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Self.log.error("Library operation failed: \(String(describing: error), privacy: .public)")
    }

    // MARK: - Formatting

    /// "4:07" — the same clock the bar and the transport use.
    static func length(_ seconds: Double) -> String {
        RecorderModel.length(seconds)
    }

    static func size(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : ""
    }
}

/// Calls back, a moment after the fact, whenever the entries of one folder change.
///
/// A vnode source on the folder itself: adding, removing or renaming a take inside it is
/// a write to the folder. Bursts — a take being copied in writes many times — are gathered
/// into one call.
@MainActor
final class FolderWatcher {
    private let changed: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?

    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
    }

    func watch(_ folder: URL) {
        stop()
        let descriptor = open(folder.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.schedule() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.changed()
        }
    }
}
