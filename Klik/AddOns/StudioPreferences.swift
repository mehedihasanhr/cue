import os
import AddOnKit
import AppKit
import Observation
import UniformTypeIdentifiers

/// What Klik asks the recording add-on for, and where it looks for it.
///
/// Kept apart from `AppPreferences` on purpose: these settings only mean anything when
/// an add-on is installed, and an install that is removed should take its settings'
/// relevance with it rather than leaving them scattered through the app's own
/// preferences.
///
/// Folders the user picks are stored as security-scoped bookmarks, the way the rest of
/// Klik stores chosen files: a sandboxed app that keeps a path keeps a string it is not
/// allowed to open.
@MainActor
@Observable
final class StudioPreferences {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let countdown = "studio.countdown"
        static let systemAudio = "studio.systemAudio"
        static let microphone = "studio.microphone"
        static let opensEditor = "studio.opensEditor"
        static let recordingsBookmark = "studio.recordingsBookmark"
        static let localBuildBookmark = "studio.localBuildBookmark"
    }

    /// Seconds between choosing Record and the first frame. Zero means start at once.
    var countdownSeconds: Int {
        didSet { defaults.set(countdownSeconds, forKey: Key.countdown) }
    }

    var recordsSystemAudio: Bool {
        didSet { defaults.set(recordsSystemAudio, forKey: Key.systemAudio) }
    }

    var recordsMicrophone: Bool {
        didSet { defaults.set(recordsMicrophone, forKey: Key.microphone) }
    }

    /// Open the editor as soon as a recording stops.
    var opensEditorAfterRecording: Bool {
        didSet { defaults.set(opensEditorAfterRecording, forKey: Key.opensEditor) }
    }

    /// Where recordings are saved. `nil` leaves the choice to the add-on, which keeps
    /// its own library in Movies.
    private(set) var recordingsFolder: URL?

    /// A build of the add-on somewhere other than Applications.
    ///
    /// For developing the add-on, and for anyone who keeps apps somewhere unusual: with
    /// one set, Klik launches that copy instead of asking LaunchServices. It is still
    /// signature-checked like any other, so this is a convenience, not a way in.
    private(set) var localBuildURL: URL?

    init() {
        countdownSeconds = defaults.object(forKey: Key.countdown) as? Int ?? 3
        recordsSystemAudio = defaults.object(forKey: Key.systemAudio) as? Bool ?? true
        recordsMicrophone = defaults.bool(forKey: Key.microphone)
        opensEditorAfterRecording = defaults.object(forKey: Key.opensEditor) as? Bool ?? true
        recordingsFolder = (defaults.data(forKey: Key.recordingsBookmark)).flatMap(Self.resolve)
        localBuildURL = (defaults.data(forKey: Key.localBuildBookmark)).flatMap(Self.resolve)
    }

    /// The request these settings describe, for a target.
    ///
    /// Pure, so what Klik asks for can be checked without launching anything.
    func request(target: RecordingRequest.Target = .ask) -> RecordingRequest {
        RecordingRequest(target: target,
                         microphone: recordsMicrophone,
                         systemAudio: recordsSystemAudio,
                         countdownSeconds: max(0, min(countdownSeconds, 10)),
                         opensEditorWhenFinished: opensEditorAfterRecording,
                         destination: recordingsFolder)
    }

    // MARK: - Folders

    func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where recordings are saved"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = Self.bookmark(url) else { return }
        defaults.set(bookmark, forKey: Key.recordingsBookmark)
        recordingsFolder = url
    }

    func clearRecordingsFolder() {
        defaults.removeObject(forKey: Key.recordingsBookmark)
        recordingsFolder = nil
    }

    // MARK: - Local build

    func chooseLocalBuild() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Klik Studio build"
        panel.message = "Pick a copy of Klik Studio.app — a build from Xcode, or one kept outside Applications."
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Self.isStudio(url) else {
            Log.addOns.error("\(url.lastPathComponent, privacy: .public) is not Klik Studio")
            NSSound.beep()
            return
        }
        guard let bookmark = Self.bookmark(url) else { return }
        defaults.set(bookmark, forKey: Key.localBuildBookmark)
        localBuildURL = url
    }

    func clearLocalBuild() {
        defaults.removeObject(forKey: Key.localBuildBookmark)
        localBuildURL = nil
    }

    /// Whether a bundle really is the add-on. The signature check still happens later;
    /// this is only so picking the wrong app fails immediately and says so.
    private static func isStudio(_ url: URL) -> Bool {
        Bundle(url: url)?.bundleIdentifier == AddOnBridge.studioBundleID
    }

    // MARK: - Bookmarks

    private static func bookmark(_ url: URL) -> Data? {
        do {
            return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            Log.addOns.error("Could not bookmark \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        // A stale bookmark still resolves; the folder moved, and re-bookmarking it is
        // the user's next action, not something to do silently behind them.
        return url
    }

    /// Runs `body` with access to a bookmarked location.
    ///
    /// Sandboxed access to a user-picked folder has to be opened and closed around each
    /// use; forgetting the close leaks a grant for the life of the process.
    func withAccess<T>(to url: URL?, _ body: () -> T) -> T {
        guard let url else { return body() }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return body()
    }
}
