import Foundation
import Observation
import RecordKit

/// How the recorder behaves around a take: shortcuts, the menu bar icon, speaker notes,
/// the desktop, the camera preview.
///
/// Its own object, reached as `settings.recorder`, rather than more properties on
/// `StudioSettings`: these are one feature's worth of preferences and they change
/// together, and keeping them apart keeps that file about what a recording contains.
@MainActor
@Observable
final class RecorderPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let usesShortcuts = "recorder.globalShortcuts"
        static let shortcuts = "recorder.shortcuts"
        static let menuBarIcon = "recorder.menuBarIcon"
        static let notesShown = "recorder.notesShown"
        static let notes = "recorder.notes"
        static let notesFontSize = "recorder.notesFontSize"
        static let hidesDesktopIcons = "recorder.hidesDesktopIcons"
        static let cameraPreview = "recorder.cameraPreview"
        static let cameraPreviewWhileRecording = "recorder.cameraPreviewWhileRecording"
    }

    /// Whether the recorder's shortcuts work while another app is in front.
    var usesGlobalShortcuts: Bool { didSet { defaults.set(usesGlobalShortcuts, forKey: Key.usesShortcuts) } }
    var shortcuts: RecorderShortcuts {
        didSet { defaults.set(try? JSONEncoder().encode(shortcuts), forKey: Key.shortcuts) }
    }
    /// The recorder's icon in the menu bar. On unless turned off.
    var showsMenuBarIcon: Bool { didSet { defaults.set(showsMenuBarIcon, forKey: Key.menuBarIcon) } }
    /// The speaker notes window. Off until somebody opens it.
    var showsSpeakerNotes: Bool { didSet { defaults.set(showsSpeakerNotes, forKey: Key.notesShown) } }
    /// What the speaker notes say — typed or pasted, plain text, kept between launches.
    var speakerNotes: String { didSet { defaults.set(speakerNotes, forKey: Key.notes) } }
    var notesFontSize: Double { didSet { defaults.set(notesFontSize, forKey: Key.notesFontSize) } }
    /// Leave the desktop's icons out of display and area recordings.
    var hidesDesktopIcons: Bool { didSet { defaults.set(hidesDesktopIcons, forKey: Key.hidesDesktopIcons) } }
    /// Show the camera beside the bar before a take, when a camera is on.
    var showsCameraPreview: Bool { didSet { defaults.set(showsCameraPreview, forKey: Key.cameraPreview) } }
    /// Keep that preview up during the take as well.
    var keepsCameraPreviewWhileRecording: Bool {
        didSet { defaults.set(keepsCameraPreviewWhileRecording, forKey: Key.cameraPreviewWhileRecording) }
    }

    static let notesFontSizes: ClosedRange<Double> = 12...48

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        usesGlobalShortcuts = defaults.object(forKey: Key.usesShortcuts) as? Bool ?? true
        shortcuts = defaults.data(forKey: Key.shortcuts)
            .flatMap { try? JSONDecoder().decode(RecorderShortcuts.self, from: $0) } ?? .defaults
        showsMenuBarIcon = defaults.object(forKey: Key.menuBarIcon) as? Bool ?? true
        showsSpeakerNotes = defaults.bool(forKey: Key.notesShown)
        speakerNotes = defaults.string(forKey: Key.notes) ?? ""
        notesFontSize = defaults.object(forKey: Key.notesFontSize) as? Double ?? 20
        hidesDesktopIcons = defaults.bool(forKey: Key.hidesDesktopIcons)
        showsCameraPreview = defaults.object(forKey: Key.cameraPreview) as? Bool ?? true
        keepsCameraPreviewWhileRecording = defaults.bool(forKey: Key.cameraPreviewWhileRecording)
    }

    /// The shortcut for an action, as a menu or a tooltip writes it: "⌃⌥⌘R". Empty when
    /// the action has none, or the shortcuts are turned off.
    func shortcutText(_ action: RecorderAction) -> String {
        guard usesGlobalShortcuts, let combo = shortcuts[action] else { return "" }
        return combo.displayString
    }

    /// A tooltip with the shortcut after it, when there is one: "Pause (⌃⌥⌘P)".
    func help(_ text: String, _ action: RecorderAction) -> String {
        let shortcut = shortcutText(action)
        return shortcut.isEmpty ? text : "\(text) (\(shortcut))"
    }
}
