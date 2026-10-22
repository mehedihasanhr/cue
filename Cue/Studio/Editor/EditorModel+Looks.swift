import Foundation
import TimelineKit

/// Dressing the project in a look, and taking a look off it.
extension EditorModel {
    /// One undo step, named "Apply Look" — see `Commands.ApplyLook`.
    func applyLook(_ look: Look) {
        apply(Commands.ApplyLook(look))
    }

    /// Whether the project is already wearing this look, for the ring on its tile.
    func isWearing(_ look: Look) -> Bool {
        look.matches(timeline)
    }

    /// The project's dressing, under a name, ready to be saved.
    func look(named name: String) -> Look {
        Look(name: name, capturing: timeline)
    }

    /// Whether the background is a picture inside this recording — the one thing a look
    /// cannot carry, and worth saying at the moment somebody saves one.
    var backgroundIsAPicture: Bool {
        if case .image = timeline.style.background { return true }
        return false
    }
}
