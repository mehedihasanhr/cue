import SwiftUI

/// Adding a label, an arrow or a box without having to know you can draw one.
///
/// Drawing on the picture is the better gesture and it stays the primary one — you place
/// and size the thing in a single motion. It is also completely invisible: nothing on the
/// screen says the picture is something you may draw on, so the feature only exists for
/// somebody who has been told about it. A button says it is there, and what lands is the
/// same object, in the middle of the frame, ready to be dragged where it belongs.
struct AddAnnotationButton: View {
    let model: EditorModel
    /// A row of labelled buttons for an empty panel, or one compact `+` for a heading.
    var isCompact = true

    var body: some View {
        if isCompact {
            Menu {
                ForEach(EditorModel.NewAnnotation.allCases) { kind in
                    Button {
                        model.addAnnotation(kind)
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a label, an arrow or a box")
            .accessibilityLabel("Add annotation")
        } else {
            // Spelled out where there is room for it. In an empty panel the question is
            // "what can I even add here?", and a menu that has to be opened to answer it is
            // a worse answer than three buttons that already have.
            HStack(spacing: 8) {
                ForEach(EditorModel.NewAnnotation.allCases) { kind in
                    Button {
                        model.addAnnotation(kind)
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                            .frame(maxWidth: .infinity)
                    }
                    .help("Add \(kind.title.lowercased()) in the middle of the frame")
                }
            }
            .controlSize(.small)
        }
    }
}
