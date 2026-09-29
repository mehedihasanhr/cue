import CoreMedia
import Foundation
import RecordKit
import TimelineKit

/// The shortcuts: what the recorder saw, and what is done to it in the editor.
///
/// An extension in its own file, like the annotations, so the model's main file does not
/// grow a chapter for every lane. Everything here goes through `apply`, so it undoes
/// like anything else.
extension EditorModel {
    // MARK: - What the recording has

    /// What the manifest says about the keyboard during this take — see `KeyCapture`.
    /// `nil` is a recording made with the setting off, or before it existed.
    var keyCapture: KeyCapture? { document.manifest.telemetry.keys }

    /// Whether the recorder watched the keys, so "Restore Recorded Shortcuts" has
    /// anything to restore from.
    var hasRecordedKeys: Bool { keyCapture == .recorded }

    // MARK: - Which one

    /// The shortcut on screen at the playhead.
    var keyCueAtPlayhead: KeyCue? {
        timeline.keyCues.last { $0.contains(playhead) }
    }

    /// The shortcut the menu acts on: the one selected, or failing that the one at the
    /// playhead — the one being looked at.
    var activeKeyCue: KeyCue? {
        if case .keyCue(let id) = selection,
           let chosen = timeline.keyCues.first(where: { $0.id == id }) {
            return chosen
        }
        return keyCueAtPlayhead
    }

    // MARK: - Editing

    /// Adds an empty shortcut at the playhead, for typing into.
    ///
    /// - Returns: its id, or `nil` when there was no room at the playhead.
    @discardableResult
    func addKeyCueAtPlayhead() -> UUID? {
        let start = min(playhead, max(.zero, duration - Clip.minimumDuration))
        let length = min(KeyCue.defaultDuration, duration - start)
        guard length >= Clip.minimumDuration else { return nil }
        let cue = KeyCue(start: start, duration: length, key: "")
        let before = timeline.keyCues
        apply(Commands.AddKeyCue(cue))
        guard timeline.keyCues != before else { return nil }
        // A shortcut nobody can see would be a shortcut added to nothing.
        if !timeline.keyStyle.isVisible {
            apply(Commands.Restyle("Keys") { $0.keyStyle.isVisible = true })
        }
        select(.keyCue(cue.id))
        return cue.id
    }

    /// What a shortcut says, from whatever was typed: "⌘⇧K", "cmd shift k", "⌘Z ×3".
    /// Blank clears it.
    func setKeyCueText(_ id: UUID, _ text: String) {
        let parsed = KeyCue.parse(text)
        apply(Commands.RestyleKeyCue(id: id, name: "Shortcut Keys") { cue in
            if let parsed {
                cue.modifiers = parsed.modifiers
                cue.key = parsed.key
                cue.count = parsed.count
            } else {
                cue.modifiers = []
                cue.key = ""
                cue.count = 1
            }
        })
    }

    /// Kept on the lane, drawn nowhere — or back again.
    func toggleKeyCueHidden(_ id: UUID) {
        guard let cue = timeline.keyCues.first(where: { $0.id == id }) else { return }
        let hides = !cue.isHidden
        apply(Commands.RestyleKeyCue(id: id, name: hides ? "Hide Shortcut" : "Show Shortcut") { $0.isHidden = hides })
    }

    /// Moves one end of a shortcut by a step, keeping the other end where it is.
    func moveKeyCueEdge(_ id: UUID, isHead: Bool, by step: CMTime) {
        guard let cue = timeline.keyCues.first(where: { $0.id == id }) else { return }
        if isHead {
            let start = max(.zero, min(cue.start + step, cue.end - Clip.minimumDuration))
            apply(Commands.MoveRegion(id: cue.id, start: start, duration: cue.end - start, trimsHead: true))
        } else {
            let end = max(cue.start + Clip.minimumDuration, min(cue.end + step, duration))
            apply(Commands.MoveRegion(id: cue.id, start: cue.start, duration: end - cue.start))
        }
    }

    /// The keys on or off in the picture, without losing them.
    func toggleKeysOverlay() {
        let shows = !timeline.keyStyle.isVisible
        apply(Commands.Restyle(shows ? "Show Keys in the Video" : "Hide Keys in the Video") { $0.keyStyle.isVisible = shows })
    }

    /// Puts the lane back to what the recorder saw, replacing whatever is there.
    ///
    /// - Returns: whether anything changed, so the caller can say when the recording had
    ///   nothing to give back.
    @discardableResult
    func restoreRecordedKeys() -> Bool {
        let recorded = document.recordedKeyCues()
        guard !recorded.isEmpty else { return false }
        let before = timeline.keyCues
        apply(Commands.SetKeyCues(recorded, name: "Restore Recorded Shortcuts"))
        return timeline.keyCues != before
    }

    /// Takes every shortcut off the lane. Undo brings them all back at once.
    func removeAllKeyCues() {
        guard !timeline.keyCues.isEmpty else { return }
        apply(Commands.SetKeyCues([], name: "Remove All Shortcuts"))
        // A selection pointing at something that has gone is an inspector open on nothing.
        if selected.contains(where: { if case .keyCue = $0 { true } else { false } }) {
            clearSelection()
        }
    }
}
