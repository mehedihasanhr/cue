import AddOnKit
import AppKit
import SwiftUI

/// The Add-ons page: what Klik can do that it does not carry.
///
/// One row per add-on, saying plainly what it is, what it costs to download and what state
/// it is in. Nothing else: an add-on's own settings belong on its own page — the recorder's
/// live under Studio — or this page becomes the settings of whatever happens to be
/// installed rather than a list of what can be.
struct AddOnSettingsView: View {
    @Environment(AddOnRegistry.self) private var registry
    @Environment(SettingsNavigation.self) private var navigation

    var body: some View {
        SettingsPane(.addOns) {
            SettingsGroup("Available", footer: footer) {
                ForEach(AddOnCatalog.all) { addOn in
                    AddOnRow(addOn: addOn)
                }
            }

            // The list says what each add-on *is*; its own page is where it is set up. Only
            // the recorder has one so far, and only worth offering once it can be used.
            if registry.availability(of: AddOnCatalog.studio).isUsable {
                SettingsGroup {
                    SettingsRow("Klik Studio settings",
                                subtitle: "Recording, where takes are saved, and the build Klik uses",
                                symbol: AddOnCatalog.studio.symbol, tint: .red) {
                        Button("Open Studio") { navigation.go(.studio) }
                    }
                }
            }
        }
        .task { await registry.refresh() }
    }

    private var footer: String {
        if let error = registry.feedError {
            return "Klik couldn't check for add-ons: \(error)"
        }
        return "Add-ons are separate apps. Klik stays small because they aren't part of it, and removing one is removing an app."
    }
}

/// One add-on, with the actions its current state allows.
struct AddOnRow: View {
    let addOn: AddOn
    @Environment(AddOnRegistry.self) private var registry

    var body: some View {
        SettingsRow(addOn.name, subtitle: subtitle, symbol: addOn.symbol, tint: .red) {
            action
        }
    }

    private var state: AddOnRegistry.State { registry.state(of: addOn) }

    private var subtitle: String {
        switch state {
        case .unknown:
            addOn.summary
        case .downloading(let progress):
            "Downloading… \(Int(progress * 100))%"
        case .readyToInstall:
            "Downloaded. Finish installing it, then come back."
        case .failed(let message):
            message
        case .resolved(let availability):
            Self.describe(availability, addOn: addOn)
        }
    }

    private static func describe(_ availability: AddOnAvailability, addOn: AddOn) -> String {
        switch availability {
        case .ready(let installed):
            "Installed — version \(installed)"
        case .updatable(let installed, let release):
            "Version \(installed) installed, \(release.version) available"
        case .tooOld(let installed, let required, _):
            "Version \(installed) installed. Klik needs \(required) or later."
        case .untrusted(let reason):
            "Found, but not signed by Klik's developer (\(reason)). Klik won't use it."
        case .notInstalled(let release):
            if let release {
                "\(addOn.summary) · \(Self.size(release.bytes))"
            } else {
                "\(addOn.summary) — not published yet"
            }
        }
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatStyle(style: .file).format(Int64(bytes))
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .downloading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button("Cancel") { registry.cancelInstall(addOn) }
            }
        case .readyToInstall:
            Button("Open Installer") { registry.openDownload(addOn) }
        case .failed:
            Button("Try Again") { registry.install(addOn) }
        case .unknown:
            EmptyView()
        case .resolved(let availability):
            resolvedAction(availability)
        }
    }

    @ViewBuilder
    private func resolvedAction(_ availability: AddOnAvailability) -> some View {
        switch availability {
        case .ready:
            HStack(spacing: 8) {
                Button("Show in Finder") { registry.revealInstalled(addOn) }
                Button("Open") { registry.launch(addOn) }
            }
        case .updatable:
            HStack(spacing: 8) {
                Button("Open") { registry.launch(addOn) }
                Button("Update") { registry.install(addOn) }
            }
        case .tooOld(_, _, let release):
            Button("Update") { registry.install(addOn) }
                .disabled(release == nil)
        case .untrusted:
            Button("Show in Finder") { registry.revealInstalled(addOn) }
        case .notInstalled(let release):
            Button("Install") { registry.install(addOn) }
                .disabled(release == nil)
                .help(release == nil ? "This add-on hasn't been published yet — point Klik at a build under Advanced." : "Download and install \(addOn.name)")
        }
    }
}
