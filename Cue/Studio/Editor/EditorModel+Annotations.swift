import CoreMedia
import Foundation
import TimelineKit

/// What can be done to an annotation beyond drawing it: lock it, hide it, restack it,
/// retime it, turn it.
///
/// Every one of these goes through a `TimelineCommand`, so every one is a single undo step
/// and every one passes through the model's guard against numbers that cannot be drawn.
/// Nothing here writes to the timeline directly.
extension EditorModel {
    func annotation(_ id: UUID) -> AnnotationItem? {
        timeline.annotations.first { $0.id == id }
    }

    func toggleLock(ofAnnotation id: UUID) {
        guard let item = annotation(id) else { return }
        let locking = !item.isLocked
        restyleAnnotation(id, locking ? "Lock Annotation" : "Unlock Annotation") { $0.isLocked = locking }
    }

    func toggleHidden(ofAnnotation id: UUID) {
        guard let item = annotation(id) else { return }
        let hiding = !item.isHidden
        restyleAnnotation(id, hiding ? "Hide Annotation" : "Show Annotation") { $0.isHidden = hiding }
    }

    func reorderAnnotation(_ id: UUID, _ move: Commands.ReorderAnnotation.Move) {
        apply(Commands.ReorderAnnotation(id: id, move))
    }

    /// Whether `move` would change anything, for greying out a menu item that would not.
    func canReorderAnnotation(_ id: UUID, _ move: Commands.ReorderAnnotation.Move) -> Bool {
        var probe = timeline
        return Commands.ReorderAnnotation(id: id, move).apply(to: &probe)
    }

    /// Sets when an annotation starts and how long it lasts, through the same command a
    /// drag on the timeline uses — so the clamping to the edit, and the refusal to move a
    /// locked one, are the timeline's rules and not a second copy of them.
    func setTiming(ofAnnotation id: UUID, start: CMTime? = nil, duration: CMTime? = nil) {
        guard let item = annotation(id) else { return }
        apply(Commands.MoveRegion(id: id, start: start ?? item.start, duration: duration ?? item.duration))
    }

    /// Straightens it, and puts it back to full strength.
    func resetTransform(ofAnnotation id: UUID) {
        restyleAnnotation(id, "Reset Transform") {
            $0.rotation = 0
            $0.opacity = 1
        }
    }
}
