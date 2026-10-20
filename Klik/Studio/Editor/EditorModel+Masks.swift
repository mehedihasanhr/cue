import CoreGraphics
import Foundation
import TimelineKit

/// The four kinds of mask, beyond drawing one: adding one from a menu, and changing what
/// a drawn one is.
///
/// Every edit goes through a `TimelineCommand`, so each is one undo step. Nothing here
/// writes to the timeline directly.
extension EditorModel {
    /// The mask the inspector is about, when one is selected.
    var selectedMask: BlurRegion? {
        guard case .blur(let id) = selection else { return nil }
        return timeline.blurs.first { $0.id == id }
    }

    /// Adds a mask of one kind in the middle of the picture, at the playhead, ready to
    /// be dragged onto the thing it is for.
    ///
    /// Drawing one on the picture is the better gesture and stays the primary one. This
    /// is the other way in — from the Mask menu, or the panel's button — for somebody who
    /// has not been told the picture can be drawn on, and for driving the editor by name.
    /// The kind is remembered as the kind the next drag makes, because asking for a
    /// spotlight and then getting a blur from the next drag would be a tool with two minds.
    @discardableResult
    func addMask(_ style: BlurRegion.Style) -> UUID {
        newMaskStyle = style
        // The tool comes with it, as it does for an added annotation: the handles that
        // move and resize the new mask live on the Mask canvas.
        tool = .blur
        return addBlur(rect: Self.newMaskRect(style))
    }

    /// Where an added mask lands. A spotlight is bigger: it is about what is *around*
    /// it, and a small one in the middle dims almost the whole picture.
    private static func newMaskRect(_ style: BlurRegion.Style) -> CGRect {
        style == .spotlight
            ? CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
            : CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.2)
    }

    /// Changes one mask, by id, as one named undo step.
    ///
    /// By id rather than by index: the lane is not sorted today, but an inspector that
    /// counted on that would be the first thing to break when it is.
    func restyleMask(_ id: UUID, _ name: String, _ change: @escaping @Sendable (inout BlurRegion) -> Void) {
        apply(Commands.Restyle(name) { timeline in
            guard let index = timeline.blurs.firstIndex(where: { $0.id == id }) else { return }
            change(&timeline.blurs[index])
        })
    }

    /// Makes the selected mask a different kind. The rectangle and the timing stay; only
    /// what happens inside it changes.
    func setMaskStyle(_ style: BlurRegion.Style) {
        guard let mask = selectedMask, mask.style != style else { return }
        restyleMask(mask.id, "Mask Kind") { $0.style = style }
    }
}
