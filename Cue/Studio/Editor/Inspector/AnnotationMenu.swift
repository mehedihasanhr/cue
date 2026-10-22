import SwiftUI
import TimelineKit

/// The right-click menu for one annotation, the same on the picture and on the timeline.
///
/// One view in two places, so the two menus cannot drift: a verb added here is on both.
/// These are the things you do *to* an annotation rather than settings of it, which is why
/// they live in a menu rather than taking up room in the inspector.
struct AnnotationMenu: View {
    let model: EditorModel
    let item: AnnotationItem
    /// Starts typing into a text annotation. `nil` where there is nothing to type into —
    /// on the timeline, the label is not on screen to be typed on.
    var edit: (() -> Void)?

    var body: some View {
        if let edit, item.kind.hasWords {
            Button("Edit Text") { edit() }
            Divider()
        }
        Button("Duplicate") { model.duplicateRegion(.annotation(item.id)) }
        Button("Copy") { model.copyRegion(.annotation(item.id)) }
        Button("Paste") { model.pasteAtPlayhead() }
            .disabled(!model.canPasteRegion)
        Divider()
        ForEach(Commands.ReorderAnnotation.Move.allCases, id: \.self) { move in
            Button(move.title) { model.reorderAnnotation(item.id, move) }
                .disabled(!model.canReorderAnnotation(item.id, move))
        }
        Divider()
        Button(item.isLocked ? "Unlock" : "Lock") { model.toggleLock(ofAnnotation: item.id) }
        Button(item.isHidden ? "Show" : "Hide") { model.toggleHidden(ofAnnotation: item.id) }
        Button("Reset Transform") { model.resetTransform(ofAnnotation: item.id) }
            .disabled(item.rotation == 0 && item.opacity == 1)
        Divider()
        Button("Delete", role: .destructive) { model.deleteSelection(item.id) }
    }
}
