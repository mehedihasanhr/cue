import os
import AddOnKit
import AppKit
import Foundation
import Observation

/// Klik's half of the conversation with the recording add-on.
///
/// The host keeps no recording state of its own: it asks whether the add-on is there,
/// asks it to bring up its recorder, and takes the finished project. Everything heavy — capture,
/// encoding, the editor — lives in the add-on's process and exits with it.
@MainActor
@Observable
final class RecordingAddOnClient {
    private let registry: AddOnRegistry
    let preferences: StudioPreferences

    init(registry: AddOnRegistry, preferences: StudioPreferences) {
        self.registry = registry
        self.preferences = preferences
    }

    var addOn: AddOn { AddOnCatalog.studio }
    var availability: AddOnAvailability { registry.availability(of: addOn) }

    /// Whether the record commands should act or offer to install.
    var canRecord: Bool { availability.isUsable }

    /// Brings up the add-on's recorder bar, where the user chooses what to record — or
    /// explains why it cannot.
    func showRecorder() async throws(AddOnError) {
        try await open(AddOnBridge.showRecorderURL)
    }

    /// Opens the add-on's Recordings window, the gallery of what was recorded.
    func showLibrary() async throws(AddOnError) {
        try await open(AddOnBridge.showLibraryURL)
    }

    /// A URL rather than a plain launch: activating an app that is already running only
    /// shows its bar when nothing else of it is open, and never opens Recordings.
    private func open(_ url: URL) async throws(AddOnError) {
        switch availability {
        case .notInstalled:
            throw .notInstalled
        case .tooOld(let installed, let required, _):
            throw .tooOld(installed: installed, required: required)
        case .untrusted(let reason):
            throw .untrusted(reason)
        case .ready, .updatable:
            break
        }

        // Sent to the copy Klik found rather than whichever one LaunchServices likes for the
        // scheme — an older build elsewhere on disk would only come forward.
        guard let app = registry.installedURL(addOn) else { throw .notInstalled }
        do {
            try await NSWorkspace.shared.open([url], withApplicationAt: app,
                                              configuration: NSWorkspace.OpenConfiguration())
        } catch {
            // Almost always Gatekeeper, which says only "a miscellaneous error occurred";
            // the same explanation as Open gives, rather than that.
            Log.addOns.error("Couldn't open \(self.addOn.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            AddOnRegistry.explainRefusedLaunch(of: addOn)
            throw .blocked
        }
    }
}
