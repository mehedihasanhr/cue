import Foundation
import TimelineKit

/// A look as the default for new recordings, working *with* the Appearance settings
/// rather than beside them.
///
/// The settings window already keeps the padding, the corners, the shadow, the
/// background blur and three pointer settings for new projects, and `styled(_:)` applies
/// them. A look holds those same fields and more. Kept as two layers that could each say
/// "padding", the window's slider and the look would fight — and whichever won, the
/// other would be a control that does nothing. So a look chosen for new recordings is
/// split: the fields the window has controls for are written *into* those controls,
/// where they can be seen and changed, and only the rest is kept as the look. The
/// window stays the truth for what it shows, and the look supplies what it cannot.
///
/// The background is the one field with a foot in both: the window offers five named
/// presets, and a look can carry any background at all. A look whose background is one
/// of the five sets the preset; any other stays with the look and wins over the preset —
/// until the preset is chosen in the window, which takes it back.
extension StudioSettings {
    func useForNewRecordings(_ look: Look) {
        var kept = look
        if let padding = look.frame.padding { self.padding = padding; kept.frame.padding = nil }
        if let corners = look.frame.cornerRadius { cornerRadius = corners; kept.frame.cornerRadius = nil }
        if let shadow = look.frame.shadowOpacity { shadowOpacity = shadow; kept.frame.shadowOpacity = nil }
        if let softness = look.frame.shadowRadius { shadowRadius = softness; kept.frame.shadowRadius = nil }
        if let blur = look.frame.backgroundBlur { backgroundBlur = blur; kept.frame.backgroundBlur = nil }
        if let scale = look.pointer.scale { cursorScale = scale; kept.pointer.scale = nil }
        if let smoothing = look.pointer.smoothing { cursorSmoothing = smoothing; kept.pointer.smoothing = nil }
        if let effect = look.pointer.clickEffect { clickEffect = effect; kept.pointer.clickEffect = nil }
        if let background = look.frame.background,
           let preset = BackgroundPreset.allCases.first(where: { $0.background == background }) {
            backgroundPreset = preset
            kept.frame.background = nil
        }
        // The pointer and caption fields Settings also has controls for go the same way.
        newRecordingLook = newProjects.absorb(kept)
    }

    func clearNewRecordingLook() {
        newRecordingLook = nil
    }

    /// Whether this is the look new recordings start from — by name, since what is
    /// kept is only part of it.
    func isNewRecordingLook(_ look: Look) -> Bool {
        newRecordingLook?.name == look.name
    }

    /// The default follows a look that was renamed, so the tick stays on the same tile.
    func newRecordingLookWasRenamed(from old: String, to new: String) {
        guard newRecordingLook?.name == old else { return }
        newRecordingLook?.name = new
    }

    /// Whether the look, rather than the preset, decides a new recording's background.
    var newRecordingLookSetsBackground: Bool {
        newRecordingLook?.frame.background != nil
    }

    /// Chosen in the settings window: the preset is the most recent word on the matter.
    func chooseBackgroundPreset(_ preset: BackgroundPreset) {
        backgroundPreset = preset
        newRecordingLook?.frame.background = nil
    }
}
