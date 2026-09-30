import Carbon.HIToolbox
import Foundation

// The editor's rebindable shortcuts, as data.
//
// In RecordKit, beside `KeyCombo`, rather than in the app, for two reasons. The app target
// has no tests, and a table of seventy defaults with a rule about which keys may be taken
// is exactly the kind of thing that goes quietly wrong without them. And the editor's keys
// and the recorder's global keys are one keyboard: the conflict rules have to see both
// tables, which is only possible where both live. Nothing here knows about menus or
// SwiftUI — the app turns a `KeyCombo` into a menu item's key equivalent.

/// A menu command in the editor that can be given a shortcut.
///
/// The raw values are what Settings stores, so they are names rather than positions and
/// never change: renaming a case would forget every shortcut somebody set for it.
public enum EditorCommand: String, CaseIterable, Codable, Sendable, Identifiable {
    // File
    case save, export, exportSelection, saveFrame
    // Edit
    case undo, redo, cutSelection, copySelection, copyFrame, paste, duplicate, deleteSelection
    case selectAll, markStart, markEnd, splitAtPlayhead, splitAtMarkers, freezeFrame
    case moveClipEarlier, moveClipLater, speedUpWaiting
    // Zoom
    case addZoom, autoZoom, removeAllZooms, splitZoom, mergeZoom, extendZoom
    case toggleZoom, lockZoom, instantZoom, frameZoom, previewZoom, resetZoom
    // Audio
    case addSound, voiceover, muteRecording, detachAudio
    // Captions
    case generateCaptions, addCaption, splitCaption, joinCaption, removeFillers, toggleCaptions
    // Keyboard
    case addKeyCue, toggleKeysOverlay
    // Playback
    case playPause, playBackward, stopShuttle, playForward
    case previousFrame, nextFrame, backSecond, forwardSecond, previousCut, nextCut
    case previousMarker, nextMarker, goToStart, goToEnd
    // View
    case toolFrame, toolCrop, toolMask, toolAnnotate, toolPointer, toolWebcam, toolCaptions, toolAudio, toolKeyboard
    case zoomTimelineIn, zoomTimelineOut, fitTimeline

    public var id: String { rawValue }

    /// The menus the commands live in, in menu bar order — how Settings groups them.
    public enum Menu: String, CaseIterable, Sendable, Identifiable {
        case file, edit, view, zoom, audio, captions, keyboard, playback

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .file: "File"
            case .edit: "Edit"
            case .view: "View"
            case .zoom: "Zoom"
            case .audio: "Audio"
            case .captions: "Captions"
            case .keyboard: "Keyboard"
            case .playback: "Playback"
            }
        }

        public var commands: [EditorCommand] { EditorCommand.allCases.filter { $0.menu == self } }
    }

    public var menu: Menu {
        switch self {
        case .save, .export, .exportSelection, .saveFrame: .file
        case .undo, .redo, .cutSelection, .copySelection, .copyFrame, .paste, .duplicate, .deleteSelection,
             .selectAll, .markStart, .markEnd, .splitAtPlayhead, .splitAtMarkers, .freezeFrame,
             .moveClipEarlier, .moveClipLater, .speedUpWaiting: .edit
        case .addZoom, .autoZoom, .removeAllZooms, .splitZoom, .mergeZoom, .extendZoom,
             .toggleZoom, .lockZoom, .instantZoom, .frameZoom, .previewZoom, .resetZoom: .zoom
        case .addSound, .voiceover, .muteRecording, .detachAudio: .audio
        case .generateCaptions, .addCaption, .splitCaption, .joinCaption, .removeFillers, .toggleCaptions: .captions
        case .addKeyCue, .toggleKeysOverlay: .keyboard
        case .playPause, .playBackward, .stopShuttle, .playForward, .previousFrame, .nextFrame,
             .backSecond, .forwardSecond, .previousCut, .nextCut, .previousMarker, .nextMarker,
             .goToStart, .goToEnd: .playback
        case .toolFrame, .toolCrop, .toolMask, .toolAnnotate, .toolPointer, .toolWebcam, .toolCaptions,
             .toolAudio, .toolKeyboard, .zoomTimelineIn, .zoomTimelineOut, .fitTimeline: .view
        }
    }

    /// What Settings calls it. The menu's own words where the item has one name, and both
    /// of its names where it flips — "Turn Zoom On or Off" — so the row is findable
    /// whichever state the menu happens to be in.
    public var title: String {
        switch self {
        case .save: "Save"
        case .export: "Export…"
        case .exportSelection: "Export Selection…"
        case .saveFrame: "Save Frame As…"
        case .undo: "Undo"
        case .redo: "Redo"
        case .cutSelection: "Cut Selection"
        case .copySelection: "Copy Selection"
        case .copyFrame: "Copy Frame"
        case .paste: "Paste at Playhead"
        case .duplicate: "Duplicate"
        case .deleteSelection: "Delete Selection"
        case .selectAll: "Select Whole Timeline"
        case .markStart: "Mark Selection Start"
        case .markEnd: "Mark Selection End"
        case .splitAtPlayhead: "Split at Playhead"
        case .splitAtMarkers: "Split at Markers"
        case .freezeFrame: "Freeze Frame at Playhead"
        case .moveClipEarlier: "Move Clip Earlier"
        case .moveClipLater: "Move Clip Later"
        case .speedUpWaiting: "Speed Up Waiting…"
        case .addZoom: "Add Zoom at Playhead"
        case .autoZoom: "Auto-Zoom from Clicks and Focus"
        case .removeAllZooms: "Remove All Zooms"
        case .splitZoom: "Split Zoom at Playhead"
        case .mergeZoom: "Merge Zoom with Next"
        case .extendZoom: "Extend to Next Zoom"
        case .toggleZoom: "Turn Zoom On or Off"
        case .lockZoom: "Lock or Unlock Zoom"
        case .instantZoom: "Make Zoom Instant or Smooth"
        case .frameZoom: "Frame Zoom on the Picture"
        case .previewZoom: "Preview Zoom Result"
        case .resetZoom: "Reset Zoom"
        case .addSound: "Add Sound…"
        case .voiceover: "Record Voiceover"
        case .muteRecording: "Mute or Unmute the Recording"
        case .detachAudio: "Detach or Re-attach Audio"
        case .generateCaptions: "Generate Captions"
        case .addCaption: "Add Caption at Playhead"
        case .splitCaption: "Split Caption at Playhead"
        case .joinCaption: "Join Caption to Next"
        case .removeFillers: "Remove Filler Words"
        case .toggleCaptions: "Show or Hide Captions"
        case .addKeyCue: "Add Shortcut at Playhead"
        case .toggleKeysOverlay: "Show or Hide Keys in the Video"
        case .playPause: "Play or Pause"
        case .playBackward: "Play Backward"
        case .stopShuttle: "Stop"
        case .playForward: "Play Forward"
        case .previousFrame: "Previous Frame"
        case .nextFrame: "Next Frame"
        case .backSecond: "Back a Second"
        case .forwardSecond: "Forward a Second"
        case .previousCut: "Previous Cut"
        case .nextCut: "Next Cut"
        case .previousMarker: "Previous Marker"
        case .nextMarker: "Next Marker"
        case .goToStart: "Go to Start"
        case .goToEnd: "Go to End"
        case .toolFrame: "Frame"
        case .toolCrop: "Crop"
        case .toolMask: "Mask"
        case .toolAnnotate: "Annotate"
        case .toolPointer: "Pointer"
        case .toolWebcam: "Webcam"
        case .toolCaptions: "Captions"
        case .toolAudio: "Audio"
        case .toolKeyboard: "Keyboard"
        case .zoomTimelineIn: "Zoom Timeline In"
        case .zoomTimelineOut: "Zoom Timeline Out"
        case .fitTimeline: "Fit Timeline"
        }
    }

    /// The shortcut the menu had before shortcuts could be changed, and what Reset puts
    /// back. `nil` for a command that ships without one — it can still be given one.
    ///
    /// Copied from the menus as they were, key for key: somebody who never opens Settings
    /// must find every shortcut where it always was. The reasons each key was chosen are
    /// written beside the menu items in `EditorCommands`.
    public var defaultShortcut: KeyCombo? {
        let command = cmdKey, shift = shiftKey, option = optionKey, control = controlKey
        func key(_ code: Int, _ modifiers: Int = 0) -> KeyCombo {
            KeyCombo(keyCode: UInt32(code), modifiers: UInt32(modifiers))
        }
        return switch self {
        case .save: key(kVK_ANSI_S, command)
        case .export: key(kVK_ANSI_E, command)
        case .undo: key(kVK_ANSI_Z, command)
        case .redo: key(kVK_ANSI_Z, command | shift)
        case .cutSelection: key(kVK_ANSI_X, command)
        case .copySelection: key(kVK_ANSI_C, command)
        case .copyFrame: key(kVK_ANSI_C, command | shift)
        case .paste: key(kVK_ANSI_V, command)
        case .duplicate: key(kVK_ANSI_D, command)
        case .deleteSelection: key(kVK_Delete)
        case .selectAll: key(kVK_ANSI_A, command)
        case .markStart: key(kVK_ANSI_I)
        case .markEnd: key(kVK_ANSI_O)
        case .splitAtPlayhead: key(kVK_ANSI_B, command)
        case .freezeFrame: key(kVK_ANSI_F, command | option)
        case .moveClipEarlier: key(kVK_LeftArrow, command | option)
        case .moveClipLater: key(kVK_RightArrow, command | option)
        case .addZoom: key(kVK_ANSI_K, command)
        case .splitZoom: key(kVK_ANSI_B, command | option)
        case .toggleZoom: key(kVK_ANSI_E, command | shift)
        case .previewZoom: key(kVK_ANSI_R, command | shift)
        case .addSound: key(kVK_ANSI_A, command | shift)
        case .voiceover: key(kVK_ANSI_V, command | shift)
        case .addCaption: key(kVK_ANSI_C, command | option)
        case .addKeyCue: key(kVK_ANSI_K, command | option)
        case .playPause: key(kVK_Space)
        case .playBackward: key(kVK_ANSI_J)
        case .stopShuttle: key(kVK_ANSI_K)
        case .playForward: key(kVK_ANSI_L)
        case .previousFrame: key(kVK_LeftArrow)
        case .nextFrame: key(kVK_RightArrow)
        case .backSecond: key(kVK_LeftArrow, shift)
        case .forwardSecond: key(kVK_RightArrow, shift)
        case .previousCut: key(kVK_LeftArrow, option)
        case .nextCut: key(kVK_RightArrow, option)
        case .previousMarker: key(kVK_ANSI_Semicolon, control)
        case .nextMarker: key(kVK_ANSI_Quote, control)
        case .goToStart: key(kVK_Home)
        case .goToEnd: key(kVK_End)
        case .toolFrame: key(kVK_ANSI_1, command)
        case .toolCrop: key(kVK_ANSI_2, command)
        case .toolMask: key(kVK_ANSI_3, command)
        case .toolAnnotate: key(kVK_ANSI_4, command)
        case .toolPointer: key(kVK_ANSI_5, command)
        case .toolWebcam: key(kVK_ANSI_6, command)
        case .toolCaptions: key(kVK_ANSI_7, command)
        case .toolAudio: key(kVK_ANSI_8, command)
        case .toolKeyboard: key(kVK_ANSI_9, command)
        case .zoomTimelineIn: key(kVK_ANSI_Equal, command)
        case .zoomTimelineOut: key(kVK_ANSI_Minus, command)
        case .fitTimeline: key(kVK_ANSI_0, command)
        case .exportSelection, .saveFrame, .splitAtMarkers, .speedUpWaiting, .autoZoom, .removeAllZooms,
             .mergeZoom, .extendZoom, .lockZoom, .instantZoom, .frameZoom, .resetZoom, .muteRecording,
             .detachAudio, .generateCaptions, .splitCaption, .joinCaption, .removeFillers, .toggleCaptions,
             .toggleKeysOverlay: nil
        }
    }
}

/// Why an editor shortcut cannot be used, in words Settings shows beside it.
public enum EditorShortcutProblem: Equatable, Sendable {
    /// macOS answers it before any app does.
    case system(String)
    /// This app's own menus have it and it cannot be changed: Quit, Settings, the Command
    /// Menu.
    case app(String)
    /// One of the recorder's global shortcuts, which takes the key before any menu sees it.
    case recorder(RecorderAction)
    /// Another editor command.
    case usedBy(EditorCommand)
    /// ⌥ with a letter or a digit types a character.
    case typesCharacter

    public var message: String {
        switch self {
        case .system(let name): "macOS uses this for \(name)."
        case .app(let name): "Klik Studio uses this for \(name)."
        case .recorder(let action): "The recorder uses this from any app for \u{201C}\(action.title)\u{201D}."
        case .usedBy(let command): "Already used for \u{201C}\(command.title)\u{201D}."
        case .typesCharacter: "⌥ with a key types a character. Add ⌘ or ⌃."
        }
    }
}

/// The editor's shortcuts: the defaults, and whatever somebody changed.
///
/// Only the changes are kept. A command nobody touched has no entry, so it follows its
/// default — including a default a later build changes or a command a later build adds —
/// rather than being frozen at whatever the default was on the day Settings was opened.
public struct EditorShortcuts: Codable, Equatable, Sendable {
    /// The commands whose shortcut differs from the default. `.some(nil)` is a shortcut
    /// taken away, which is a change like any other.
    public private(set) var overrides: [EditorCommand: KeyCombo?]

    public init(overrides: [EditorCommand: KeyCombo?] = [:]) {
        self.overrides = [:]
        for (command, combo) in overrides { self[command] = combo }
    }

    /// Every command at its default.
    public static let defaults = EditorShortcuts()

    /// The shortcut a command has now: its own if it was changed, its default if not.
    /// Setting it back to the default removes the change rather than storing a copy of it.
    public subscript(command: EditorCommand) -> KeyCombo? {
        get {
            if let changed = overrides[command] { return changed }
            return command.defaultShortcut
        }
        set {
            if newValue == command.defaultShortcut {
                overrides[command] = nil
            } else {
                overrides[command] = .some(newValue)
            }
        }
    }

    public func isCustomised(_ command: EditorCommand) -> Bool { overrides[command] != nil }

    public var isDefault: Bool { overrides.isEmpty }

    public mutating func reset(_ command: EditorCommand) { overrides[command] = nil }

    /// The command that has this shortcut now, if any.
    public func command(using combo: KeyCombo, except excluded: EditorCommand? = nil) -> EditorCommand? {
        EditorCommand.allCases.first { $0 != excluded && self[$0] == combo }
    }

    /// What is wrong with giving `combo` to `command`, or `nil` when nothing is.
    ///
    /// - Parameter recorder: the recorder's global shortcuts while they are turned on —
    ///   `nil` when they are off, because a shortcut that is not registered takes nothing.
    ///
    /// Unlike the recorder's, a plain key is allowed here, and so is ⌘ alone: these are
    /// menu shortcuts, answered only while the editor is in front, and Space, J, K and L
    /// have always been the editor's. What is refused is a key somebody else already
    /// answers — macOS, this app's fixed menus, a global shortcut — a key another command
    /// has, and ⌥ with a character, which would stop that character being typed.
    public func problem(with combo: KeyCombo, for command: EditorCommand,
                        recorder: RecorderShortcuts? = nil) -> EditorShortcutProblem? {
        if let name = RecorderShortcuts.system[combo] { return .system(name) }
        if let name = Self.reserved[combo] { return .app(name) }
        if let recorder, let action = RecorderAction.allCases.first(where: { recorder[$0] == combo }) {
            return .recorder(action)
        }
        if let other = self.command(using: combo, except: command) { return .usedBy(other) }
        if combo.hasOption, !combo.hasCommand, !combo.hasControl, combo.typesText { return .typesCharacter }
        return nil
    }

    /// Every command whose shortcut has a problem as things stand — what Settings flags on
    /// opening. Settings refuses to make a clash, so one found here was stored by an older
    /// build or made by turning the recorder's shortcuts on afterwards.
    public func problems(recorder: RecorderShortcuts? = nil) -> [EditorCommand: EditorShortcutProblem] {
        var found: [EditorCommand: EditorShortcutProblem] = [:]
        for command in EditorCommand.allCases {
            if let combo = self[command], let problem = problem(with: combo, for: command, recorder: recorder) {
                found[command] = problem
            }
        }
        return found
    }

    // MARK: - Stored

    /// Read entry by entry, so a command this build does not know — stored by a newer one,
    /// or renamed away — is skipped rather than costing every other change.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stored = try container.decode([String: KeyCombo?].self)
        var overrides: [EditorCommand: KeyCombo?] = [:]
        for (key, combo) in stored {
            guard let command = EditorCommand(rawValue: key) else { continue }
            overrides[command] = .some(combo)
        }
        self.init(overrides: overrides)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let stored = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        try container.encode(stored)
    }

    // MARK: - Taken

    /// The shortcuts this app's own menus keep for themselves and does not let be changed:
    /// the application's, the window's, and the few text-editing keys a field needs.
    static let reserved: [KeyCombo: String] = {
        func combo(_ key: Int, _ modifiers: Int = 0) -> KeyCombo {
            KeyCombo(keyCode: UInt32(key), modifiers: UInt32(modifiers))
        }
        return [
            combo(kVK_ANSI_Q, cmdKey): "quitting",
            combo(kVK_ANSI_W, cmdKey): "closing the window",
            combo(kVK_ANSI_H, cmdKey): "hiding the app",
            combo(kVK_ANSI_H, optionKey | cmdKey): "hiding other apps",
            combo(kVK_ANSI_M, cmdKey): "minimising the window",
            combo(kVK_ANSI_Comma, cmdKey): "Settings",
            combo(kVK_ANSI_L, cmdKey): "Recordings",
            combo(kVK_ANSI_0, shiftKey | cmdKey): "the recorder bar",
            combo(kVK_ANSI_P, shiftKey | cmdKey): "the Command Menu",
            combo(kVK_Escape): "cancelling",
            combo(kVK_Tab): "moving between fields",
            combo(kVK_Tab, shiftKey): "moving between fields",
            combo(kVK_Return): "confirming",
        ]
    }()
}

public extension KeyCombo {
    /// Whether the key types text when pressed with ⌥ or on its own: a letter, a digit or
    /// punctuation — not an arrow, a function key or Space.
    var typesText: Bool { Self.textKeys.contains(Int(keyCode)) }

    private static let textKeys: Set<Int> = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
        kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
        kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
        kVK_ANSI_Y, kVK_ANSI_Z,
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
        kVK_ANSI_8, kVK_ANSI_9,
        kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Semicolon,
        kVK_ANSI_Quote, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash, kVK_ANSI_Backslash, kVK_ANSI_Grave,
    ]
}
