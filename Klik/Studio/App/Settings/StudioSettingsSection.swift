import AppKit
import SwiftUI

// MARK: - Sections

/// Recording and the video editor's settings pages. They are pages of Klik Settings now —
/// see `SettingsSection.studioPage` — and this names them for the panes and for
/// `StudioController.openSettings`.
enum StudioSettingsSection: String, CaseIterable, Identifiable {
    case general, recording, shortcuts
    case editor, captions, audio, export
    case storage

    var id: String { rawValue }

    /// The sidebar shows the app itself first, then what happens to a recording from
    /// the editor on, then the housekeeping.
    static let groups: [[StudioSettingsSection]] = [
        [.general, .recording, .shortcuts],
        [.editor, .captions, .audio, .export],
        [.storage],
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .shortcuts: "Shortcuts"
        case .editor: "Editor"
        case .captions: "Captions"
        case .audio: "Audio"
        case .export: "Export"
        case .storage: "Storage"
        }
    }

    /// What the sidebar search matches besides the title and keywords.
    var subtitle: String {
        switch self {
        case .general: "Where recordings go, and what happens when one stops"
        case .recording: "What a take records, and what is on screen while it does"
        case .shortcuts: "The recorder\u{2019}s keys from any app, and the editor\u{2019}s menu shortcuts"
        case .editor: "Saving, auto-zoom, and how a new recording looks"
        case .captions: "The language listened for, and how new captions look"
        case .audio: "Voice clean-up, click sounds and the preview"
        case .export: "What the export sheet starts with, and what happens after"
        case .storage: "Google Drive, disk space, caches"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .recording: "record.circle.fill"
        case .shortcuts: "command"
        case .editor: "wand.and.stars"
        case .captions: "captions.bubble.fill"
        case .audio: "waveform"
        case .export: "square.and.arrow.up.fill"
        case .storage: "internaldrive.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .recording: .red
        case .shortcuts: .indigo
        case .editor: .purple
        case .captions: .orange
        case .audio: .pink
        case .export: .blue
        case .storage: .teal
        }
    }

    /// What the sidebar search matches besides the title: the settings on the page.
    var keywords: [String] {
        switch self {
        case .general: ["folder", "library", "save", "location", "dock", "menu bar", "icon", "appearance", "theme", "dark", "light", "login", "launch", "startup", "open editor"]
        case .recording: ["countdown", "frame rate", "fps", "quality", "encoder", "hevc", "h.264", "codec", "pointer", "cursor", "clicks", "focus", "keyboard", "keys", "keystrokes", "accessibility", "privacy", "microphone", "mic", "system audio", "camera", "webcam", "desktop icons", "speaker notes", "restart", "confirm"]
        case .shortcuts: ["hotkey", "keyboard", "global", "record", "pause", "restart", "marker", "conflict", "editor", "menu", "key equivalent", "rebind", "undo", "play", "split", "zoom"]
        case .editor: ["autosave", "save", "look", "background", "padding", "corners", "shadow", "blur", "zoom", "auto-zoom", "scale", "pointer", "cursor", "size", "smoothing", "click", "ring", "ripple", "idle", "motion blur"]
        case .captions: ["language", "transcribe", "subtitles", "position", "typeface", "font", "animation", "highlight", "backdrop"]
        case .audio: ["voice", "clean up", "noise", "even out", "loudness", "volume", "click sound", "preview", "voiceover", "count in", "mute"]
        case .export: ["format", "mp4", "mov", "prores", "gif", "quality", "frame rate", "size", "resolution", "1080p", "4k", "codec", "sound", "loop", "folder", "reveal", "finder", "open"]
        case .storage: ["google", "drive", "cloud", "upload", "backup", "disk", "space", "free", "cache", "waveform", "thumbnail", "poster", "clear", "reset", "defaults"]
        }
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return title.lowercased().contains(needle)
            || subtitle.lowercased().contains(needle)
            || keywords.contains { $0.contains(needle) }
    }
}
