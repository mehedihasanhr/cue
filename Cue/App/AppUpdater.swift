import Observation
import Sparkle

/// Keeps Cue up to date, through Sparkle.
///
/// Sparkle reads the feed named by `SUFeedURL` in the Info.plist (the public releases
/// repository's `mac-feed` release), checks a day apart, and verifies each update
/// against `SUPublicEDKey` before installing it. Cue is sandboxed, so it cannot replace
/// its own bundle: Sparkle's installer launcher does that, outside the sandbox.
///
/// By default an update is downloaded in the background and installed when Cue quits;
/// with automatic installs off, Sparkle asks first instead. Both choices are Sparkle's
/// own defaults keys, so they survive without anything stored here.
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// False while a check is already under way.
    private(set) var canCheckForUpdates = false

    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return updater.automaticallyChecksForUpdates }
        set { withMutation(keyPath: \.checksAutomatically) { updater.automaticallyChecksForUpdates = newValue } }
    }

    var installsAutomatically: Bool {
        get { access(keyPath: \.installsAutomatically); return updater.automaticallyDownloadsUpdates }
        set { withMutation(keyPath: \.installsAutomatically) { updater.automaticallyDownloadsUpdates = newValue } }
    }

    private var updater: SPUUpdater { controller.updater }

    private init() {
        // Not started yet: `start()` runs once the app has finished launching, so the
        // first check never races the onboarding windows.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        observations.append(updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        })
    }

    func start() {
        #if DEBUG
        // A debug build is never what's published, and replacing it with a release
        // would leave the developer running something other than what they built.
        return
        #else
        controller.startUpdater()
        #endif
    }

    /// The menu's "Check for Updates": shows Sparkle's window, even when up to date.
    func checkForUpdates() {
        #if DEBUG
        controller.startUpdater()
        #endif
        controller.checkForUpdates(nil)
    }

    /// The daily check, now: no window unless there is something to install, and with
    /// automatic installs on, not even then. For `cue://update`, which scripts send.
    func checkInBackground() {
        #if DEBUG
        controller.startUpdater()
        #endif
        updater.checkForUpdatesInBackground()
    }
}
