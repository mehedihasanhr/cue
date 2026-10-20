import AppKit

/// The question Klik asks when a video command needs Klik Studio and it is not there to
/// answer: install it, update it, or say plainly why it cannot be opened.
///
/// Asked where the command was given — the menu bar — rather than by sending the user to
/// Settings to work out what the Studio page is for. Settings is still where the download
/// shows its progress, so "Install" starts it and opens the page.
@MainActor
enum StudioInstallPrompt {
    enum Choice {
        /// The download has started (or the update), and the caller should watch for it.
        case install
        /// The user wants the Studio page in Settings.
        case settings
        case dismissed
    }

    static func ask(_ availability: AddOnAvailability, feedError: String?) -> Choice {
        let addOn = AddOnCatalog.studio
        let alert = NSAlert()
        let install: Bool
        switch availability {
        case .notInstalled(let release?):
            alert.messageText = "Install \(addOn.name) to record and edit videos"
            alert.informativeText = "\(addOn.name) adds screen recording, timeline editing, auto-zoom and video export. It installs as its own app (\(size(of: release))), so Klik stays light."
            alert.addButton(withTitle: "Install")
            install = true
        case .notInstalled(nil):
            alert.messageText = "\(addOn.name) isn\u{2019}t available to download"
            alert.informativeText = feedError.map { "Klik couldn\u{2019}t check for it: \($0)" }
                ?? "No release has been published yet. If you have a copy, choose it on the Studio page in Settings."
            alert.addButton(withTitle: "Open Settings")
            install = false
        case .tooOld(let installed, let required, let release):
            alert.messageText = "Update \(addOn.name) to record and edit videos"
            alert.informativeText = "This copy is version \(installed); Klik needs \(required) or newer."
                + (release.map { " The update is \(size(of: $0))." } ?? "")
            alert.addButton(withTitle: release == nil ? "Open Settings" : "Update")
            install = release != nil
        case .untrusted(let reason):
            alert.messageText = "\(addOn.name) can\u{2019}t be verified"
            alert.informativeText = "\(reason) Klik only opens a copy signed by the same developer as Klik."
            alert.addButton(withTitle: "Open Settings")
            install = false
        case .ready, .updatable:
            return .dismissed
        }
        alert.addButton(withTitle: "Not Now")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        if let symbol = NSImage(systemSymbolName: addOn.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .regular).applying(.init(hierarchicalColor: .controlAccentColor))) {
            alert.icon = symbol
        }
        // A menu-bar app's alert opens behind the front app unless Klik comes forward.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return .dismissed }
        return install ? .install : .settings
    }

    private static func size(of release: AddOnRelease) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(release.bytes), countStyle: .file)
    }
}
