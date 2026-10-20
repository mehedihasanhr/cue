import AppKit

/// The apps system audio can be narrowed to, as the recorder's menu lists them.
///
/// Read from `NSWorkspace` rather than from ScreenCaptureKit: the menu opens often and
/// needs names and nothing else, and asking ScreenCaptureKit for shareable content is a
/// round trip to the window server that can also raise a permission prompt. The take
/// itself asks ScreenCaptureKit, at the moment it starts — see `SystemAudioRoute`.
enum SystemAudioApps {
    struct Entry: Identifiable, Equatable {
        let bundleID: String
        let name: String
        /// Chosen once and not running now: listed so it can be unticked, and marked so
        /// nobody expects to hear it.
        let isRunning: Bool

        var id: String { bundleID }
    }

    /// This app and its host, which are never listened to.
    static let ownBundleIDs: Set<String> = ["com.stackrover.klik", "com.stackrover.klik.studio"]

    /// Every app with a Dock icon that is running, by name, then any chosen app that is not
    /// running, in the order it was chosen.
    ///
    /// Regular apps only. Background agents and menu bar helpers do make sound now and
    /// then, but a menu of forty daemons with reverse-DNS names is not a choice anybody
    /// can make, and "every app" still hears them.
    @MainActor
    static func entries(chosen: [String]) -> [Entry] {
        var seen: Set<String> = []
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> Entry? in
                guard let id = app.bundleIdentifier, !ownBundleIDs.contains(id), seen.insert(id).inserted else { return nil }
                return Entry(bundleID: id, name: app.localizedName ?? id, isRunning: true)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let missing = chosen.filter { !seen.contains($0) }.map { id in
            Entry(bundleID: id, name: name(of: id), isRunning: false)
        }
        return running + missing
    }

    /// An app's name from its bundle identifier, whether or not it is running — for the
    /// bar's label and for a chosen app that has been quit.
    @MainActor
    static func name(of bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    /// What the bar says about system audio in a word or two.
    @MainActor
    static func label(isOn: Bool, chosen: [String]) -> String {
        guard isOn else { return "No system audio" }
        switch chosen.count {
        case 0: return "System audio"
        case 1: return "\(name(of: chosen[0])) audio"
        default: return "\(chosen.count) apps\u{2019} audio"
        }
    }
}
