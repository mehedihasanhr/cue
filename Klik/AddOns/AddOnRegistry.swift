import os
import AppKit
import Foundation
import Observation

/// Where the published release list comes from.
@MainActor
protocol AddOnFeedLoading {
    /// The feed, or `nil` while nothing has been published yet.
    func load() async throws(AddOnError) -> AddOnFeed?
}

/// Reads `AddOnCatalog.feedURL`, or answers "nothing published" when there is none.
@MainActor
struct RemoteAddOnFeedLoader: AddOnFeedLoading {
    func load() async throws(AddOnError) -> AddOnFeed? {
        guard let url = AddOnCatalog.feedURL else { return nil }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw .http(URLError.Code.badServerResponse.rawValue)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw .http(http.statusCode)
        }
        return try AddOnFeed.decode(data)
    }
}

/// What Klik shows and does about each add-on.
///
/// Deliberately shaped like `LanguagePackStore`: `@Observable` so Settings redraws
/// itself, one in-flight task per add-on so two clicks share one download, and the
/// filesystem (here, LaunchServices) as the durable truth rather than remembered state.
@MainActor
@Observable
final class AddOnRegistry {
    enum State: Equatable {
        case unknown
        /// Resolved against what is installed and what is published.
        case resolved(AddOnAvailability)
        case downloading(progress: Double)
        /// Downloaded and verified, and being put in place by Klik — see `AddOnPlacer`.
        case installing
        /// Downloaded and verified, as an image or package: macOS does the installing
        /// from here — Klik opens it and the user finishes it.
        case readyToInstall(URL)
        case failed(String)

        var availability: AddOnAvailability? {
            if case .resolved(let availability) = self { return availability }
            return nil
        }
    }

    private(set) var states: [String: State] = [:]
    /// The last feed read, kept so a failed refresh does not hide a known release.
    private(set) var feed: AddOnFeed?
    private(set) var feedError: String?

    private var locator: any AddOnLocating
    private let downloader: any AddOnDownloading
    private let feedLoader: any AddOnFeedLoading
    private var inFlight: [String: Task<URL, any Error>] = [:]

    init(locator: (any AddOnLocating)? = nil,
         downloader: any AddOnDownloading = URLSessionAddOnDownloader(),
         feedLoader: any AddOnFeedLoading = RemoteAddOnFeedLoader(),
         preferences: StudioPreferences? = nil) {
        self.preferences = preferences
        self.locator = locator ?? LaunchServicesAddOnLocator(localBuild: preferences?.localBuildURL)
        self.downloader = downloader
        self.feedLoader = feedLoader
        AddOnDownloads.sweepPartials()
        resolveInstalled()
    }

    /// The settings that say where to look and what to ask for. Held weakly-ish by
    /// reference so the pane and the registry always agree about the local build.
    private let preferences: StudioPreferences?

    /// Re-reads the local build setting and looks again.
    ///
    /// Called after the user picks or clears one, because "where is the add-on?" is a
    /// question with a different answer afterwards.
    func localBuildChanged() {
        locator = LaunchServicesAddOnLocator(localBuild: preferences?.localBuildURL)
        resolveInstalled()
    }

    func state(of addOn: AddOn) -> State { states[addOn.id] ?? .unknown }

    func availability(of addOn: AddOn) -> AddOnAvailability {
        state(of: addOn).availability
            ?? AddOnResolver.availability(for: addOn,
                                          installed: locator.locate(addOn),
                                          release: feed?.latest(for: addOn))
    }

    /// Re-reads what is installed. Cheap, and correct after the user installs or
    /// removes an add-on behind Klik's back — which is the normal way it happens.
    func resolveInstalled() {
        for addOn in AddOnCatalog.all where inFlight[addOn.id] == nil {
            let availability = AddOnResolver.availability(for: addOn,
                                                          installed: locator.locate(addOn),
                                                          release: feed?.latest(for: addOn))
            states[addOn.id] = .resolved(availability)
            if case .untrusted(let reason) = availability {
                Log.addOns.error("\(addOn.bundleID, privacy: .public) is not trusted: \(reason, privacy: .public)")
            }
        }
    }

    /// Re-reads the feed, then what is installed.
    func refresh() async {
        do {
            if let feed = try await feedLoader.load() { self.feed = feed }
            feedError = nil
        } catch {
            feedError = error.localizedDescription
            Log.addOns.error("Add-on feed failed: \(error.localizedDescription, privacy: .public)")
        }
        resolveInstalled()
    }

    /// Downloads the offered release and installs it.
    ///
    /// An archive is installed by Klik into the folder the user grants it — asked first,
    /// before anything is downloaded, so declining costs nothing. An image or package is
    /// opened for macOS to install.
    func install(_ addOn: AddOn) {
        guard inFlight[addOn.id] == nil else { return }
        guard let release = availability(of: addOn).offeredRelease else {
            states[addOn.id] = .failed(AddOnError.notPublished.localizedDescription)
            return
        }
        var folder: URL?
        if release.installer == .archive {
            guard let granted = AddOnPlacer.installFolder(for: addOn, release: release) else { return }
            folder = granted
        }

        states[addOn.id] = .downloading(progress: 0)
        let task = Task { [downloader] () throws -> URL in
            try await downloader.download(release) { [weak self] progress in
                guard let self, case .downloading = self.states[addOn.id] else { return }
                self.states[addOn.id] = .downloading(progress: progress)
            }
        }
        inFlight[addOn.id] = task

        Task {
            defer { inFlight[addOn.id] = nil }
            do {
                let url = try await task.value
                Log.addOns.notice("Downloaded \(addOn.id, privacy: .public) \(release.version.description, privacy: .public)")
                if let folder {
                    states[addOn.id] = .installing
                    let placed = try await AddOnPlacer.place(url, addOn: addOn, in: folder)
                    Log.addOns.notice("Installed \(addOn.id, privacy: .public) at \(placed.path, privacy: .public)")
                    // Done before looking again: `resolveInstalled` leaves alone an add-on
                    // still in flight, so it sat on "Installing…" with the app in place.
                    inFlight[addOn.id] = nil
                    LaunchServicesAddOnLocator.placedCopies[addOn.bundleID] = placed
                    resolveInstalled()
                } else {
                    states[addOn.id] = .readyToInstall(url)
                    NSWorkspace.shared.open(url)
                }
            } catch is CancellationError {
                resolveInstalled()
            } catch {
                states[addOn.id] = .failed(error.localizedDescription)
                Log.addOns.error("\(addOn.id, privacy: .public) install failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancelInstall(_ addOn: AddOn) {
        inFlight[addOn.id]?.cancel()
        inFlight[addOn.id] = nil
        resolveInstalled()
    }

    /// Opens the downloaded installer again, for when the user dismissed it.
    func openDownload(_ addOn: AddOn) {
        guard case .readyToInstall(let url) = state(of: addOn) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Shows the installed add-on in Finder. Klik never deletes an app it did not put
    /// there, so "Remove" points at it rather than doing it.
    func revealInstalled(_ addOn: AddOn) {
        guard let installed = locator.locate(addOn) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([installed.url])
    }

    /// Where the add-on is, when it is anywhere.
    func installedURL(_ addOn: AddOn) -> URL? {
        locator.locate(addOn)?.url
    }

    /// Opens the add-on with nothing to do — the "it is installed, show me" button.
    func launch(_ addOn: AddOn) {
        guard let installed = locator.locate(addOn), installed.untrustedReason == nil else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: installed.url, configuration: configuration) { _, error in
            guard let error else { return }
            Log.addOns.error("Couldn't launch \(addOn.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            Task { @MainActor in Self.explainRefusedLaunch(of: addOn) }
        }
    }

    /// Says why macOS would not open the add-on, and where to let it.
    ///
    /// The usual reason is Gatekeeper: a build that is not notarized, installed by a
    /// sandboxed app that cannot clear the quarantine flag, is refused until the user
    /// allows it once in Privacy & Security. Without this, Open simply did nothing.
    static func explainRefusedLaunch(of addOn: AddOn) {
        let alert = NSAlert()
        alert.messageText = "macOS didn\u{2019}t open \(addOn.name)."
        alert.informativeText = "\(addOn.name) isn\u{2019}t notarized yet, so macOS asks before opening it the first time. In System Settings \u{203A} Privacy & Security, choose Open Anyway next to \(addOn.name), then open it again."
        alert.addButton(withTitle: "Open Privacy & Security")
        alert.addButton(withTitle: "Not Now")
        // A menu-bar app's alert opens behind the front app unless Klik comes forward.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let pane = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") else { return }
        NSWorkspace.shared.open(pane)
    }
}
