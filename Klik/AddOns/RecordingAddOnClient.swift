import os
import AddOnKit
import AppKit
import Foundation
import Observation

/// Klik's half of the conversation with the recording add-on.
///
/// The host keeps no recording state of its own: it asks whether the add-on is there,
/// asks it to record, and takes the finished project. Everything heavy — capture,
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

    /// A menu title that tells the truth in every state.
    var commandTitle: String {
        switch availability {
        case .ready, .updatable: "Record Screen…"
        case .notInstalled: "Install Klik Studio…"
        case .tooOld: "Update Klik Studio…"
        case .untrusted: "Klik Studio can't be verified"
        }
    }

    /// Starts a recording, or explains why it cannot.
    ///
    /// The handoff is a request file plus a launch: the add-on is an ordinary app, so
    /// opening it with a URL is something both sides can do today, before either has an
    /// App Group or a Mach service. `AddOnKit` replaces the transport later without
    /// changing `RecordingRequest`, which is the part that matters.
    /// Records what the user's settings describe: their countdown, audio choices, and
    /// where recordings go.
    func record(target: RecordingRequest.Target = .ask) async throws(AddOnError) {
        try await record(preferences.request(target: target))
    }

    /// Brings the add-on up without asking it to record — the "open it" command.
    func launch() throws(AddOnError) {
        switch availability {
        case .notInstalled: throw .notInstalled
        case .tooOld(let installed, let required, _): throw .tooOld(installed: installed, required: required)
        case .untrusted(let reason): throw .untrusted(reason)
        case .ready, .updatable: registry.launch(addOn)
        }
    }

    func record(_ request: RecordingRequest) async throws(AddOnError) {
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

        let file = try write(request)
        guard let launchURL = RequestFile.launchURL(for: file) else { throw .launchFailed("bad request URL") }

        do {
            try await NSWorkspace.shared.open(launchURL, configuration: NSWorkspace.OpenConfiguration())
            Log.addOns.notice("Handed recording \(request.correlationID.uuidString, privacy: .public) to \(self.addOn.bundleID, privacy: .public)")
        } catch {
            throw .launchFailed(error.localizedDescription)
        }
    }

    /// Where requests are dropped for the add-on to read.
    ///
    /// Both processes are sandboxed, so this moves into the shared App Group container
    /// the moment the add-on target exists. Until then it is a path the user's own two
    /// apps can both reach, and the file carries nothing secret.
    private func write(_ request: RecordingRequest) throws(AddOnError) -> URL {
        do {
            return try RequestFile.write(request, in: AddOnDownloads.folder.appendingPathComponent("requests", isDirectory: true))
        } catch {
            throw .launchFailed(error.localizedDescription)
        }
    }
}
