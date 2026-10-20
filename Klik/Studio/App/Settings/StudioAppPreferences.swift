import AppKit
import Foundation
import Observation
import RecordKit

/// How the app itself behaves: its appearance, whether it is in the Dock, how careful a
/// restart is, and what happens when an export lands.
///
/// Its own object, reached as `settings.app`, for the reason `RecorderPreferences` is one:
/// none of this changes what a recording contains, and keeping it apart keeps
/// `StudioSettings` about exactly that.
@MainActor
@Observable
final class StudioAppPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    enum Key {
        static let appearance = "app.appearance"
        static let showsInDock = "app.showsInDock"
        static let restartConfirmation = "recorder.restartConfirmation"
        static let afterExport = "export.afterExport"
        /// Read by `ExportModel`, which keeps its own keys beside it.
        static let remembersExportFolder = "export.remembersFolder"
    }

    /// Light, dark, or whatever the Mac is set to.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        /// `nil` is "follow the Mac", which is what `NSApp.appearance` means by it too.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    /// What a finished export does, besides saying so in the editor's toolbar.
    enum AfterExport: String, CaseIterable, Identifiable {
        /// The pill in the toolbar, and the file shown in the Finder only when no editor
        /// is left to show the pill in. What every export did before there was a choice.
        case announce
        /// The Finder, with the file selected, every time.
        case reveal
        /// The file itself, in whatever plays it.
        case open

        var id: String { rawValue }

        var title: String {
            switch self {
            case .announce: "Show in the editor"
            case .reveal: "Show in Finder"
            case .open: "Open the file"
            }
        }
    }

    /// The choices offered for the restart question, in seconds. `nil` is never.
    static let restartThresholds: [Int?] = [0, 10, 30, 60, 300, nil]

    var appearance: Appearance = .system { didSet { store(appearance.rawValue, Key.appearance) } }

    /// Whether the app has a Dock icon while no recording is open for editing.
    ///
    /// Only then: an editor has a menu bar full of commands, and an app without a Dock
    /// icon has no menu bar at all, so the icon comes back for as long as one is open.
    var showsInDock = true { didSet { store(showsInDock, Key.showsInDock) } }

    /// How long a take has to be before Restart asks first. `nil` never asks.
    ///
    /// Stored as seconds, with -1 for "never", so a defaults dump reads as what it means.
    var restartConfirmationSeconds: Int? = Int(TakeRestart.confirmationThreshold) {
        didSet { store(restartConfirmationSeconds ?? -1, Key.restartConfirmation) }
    }

    var afterExport: AfterExport = .announce { didSet { store(afterExport.rawValue, Key.afterExport) } }

    /// Whether the save panel opens where the last export went, or always in the folder
    /// chosen in Settings.
    var remembersExportFolder = true { didSet { store(remembersExportFolder, Key.remembersExportFolder) } }

    /// Set while `load()` runs, so reading a value does not write it straight back — which
    /// would pin today's default into the file, and a later build could never change it.
    @ObservationIgnored private var isLoading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func store(_ value: Any, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    /// Reads every value again — at launch, and after Reset All Settings has taken the
    /// stored ones away.
    ///
    /// Lenient throughout: a key of the wrong type, or a word no build has ever written,
    /// is read as the default rather than as a reason to fail.
    func load() {
        isLoading = true
        defer { isLoading = false }
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system
        showsInDock = defaults.object(forKey: Key.showsInDock) as? Bool ?? true
        if let seconds = defaults.object(forKey: Key.restartConfirmation) as? Int {
            restartConfirmationSeconds = seconds < 0 ? nil : seconds
        } else {
            restartConfirmationSeconds = Int(TakeRestart.confirmationThreshold)
        }
        afterExport = defaults.string(forKey: Key.afterExport).flatMap(AfterExport.init) ?? .announce
        remembersExportFolder = defaults.object(forKey: Key.remembersExportFolder) as? Bool ?? true
    }

    /// Whether Restart should ask before throwing away a take this long.
    func restartNeedsConfirmation(recordedSeconds: Double) -> Bool {
        TakeRestart.needsConfirmation(recordedSeconds: recordedSeconds,
                                      threshold: restartConfirmationSeconds.map(Double.init))
    }
}
