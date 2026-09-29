import SwiftUI

/// Adding a label, a shape, a step or a callout without having to know you can draw one.
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
                        Label(kind.menuTitle, systemImage: kind.symbol)
                    }
                }
                Divider()
                Button { model.addPicture(asLogo: false) } label: {
                    Label("Picture…", systemImage: "photo")
                }
                Button { model.addPicture(asLogo: true) } label: {
                    Label("Logo…", systemImage: "seal")
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
            .help("Add a label, a shape, a numbered step, a callout, a picture or a logo")
            .accessibilityLabel("Add annotation")
        } else {
            // Spelled out where there is room for it. In an empty panel the question is
            // "what can I even add here?", and a menu that has to be opened to answer it is
            // a worse answer than buttons that already have.
            //
            // Three to a row at most. The panel can be 260 points wide, which leaves about
            // 220 for this: three short words fit, three long ones ("Highlight") do not, and
            // a button that truncates its own name is worse than a menu. So the second row
            // is two buttons and a menu for the rest, which leaves each of the two 85 points.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(EditorModel.NewAnnotation.first) { kind in
                        button(kind)
                    }
                }
                .controlSize(.small)
                HStack(spacing: 8) {
                    ForEach(EditorModel.NewAnnotation.second) { kind in
                        button(kind)
                    }
                    Menu {
                        ForEach(EditorModel.NewAnnotation.more) { kind in
                            Button {
                                model.addAnnotation(kind)
                            } label: {
                                Label(kind.title, systemImage: kind.symbol)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More: an ellipse, a line or a highlight")
                    .accessibilityLabel("More Annotations")
                }
                .controlSize(.small)
                HStack(spacing: 8) {
                    Button { model.addPicture(asLogo: false) } label: {
                        Label("Picture…", systemImage: "photo").frame(maxWidth: .infinity)
                    }
                    .help("Lay a picture over the video, at the playhead")
                    Button { model.addPicture(asLogo: true) } label: {
                        Label("Logo…", systemImage: "seal").frame(maxWidth: .infinity)
                    }
                    .help("Put a logo in the corner for the whole video")
                }
                .controlSize(.small)
            }
        }
    }

    private func button(_ kind: EditorModel.NewAnnotation) -> some View {
        Button {
            model.addAnnotation(kind)
        } label: {
            Label(kind.title, systemImage: kind.symbol)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .help(kind == .step ? "Add the next numbered step in the middle of the frame"
                            : "Add \(kind.title.lowercased()) in the middle of the frame")
    }
}
