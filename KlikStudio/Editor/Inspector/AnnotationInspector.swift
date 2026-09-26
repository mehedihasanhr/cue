import AppKit
import BackgroundKit
import SwiftUI
import TimelineKit

/// What a label, an arrow or a box says and how it looks.
struct AnnotationInspector: View {
    let model: EditorModel
    let id: UUID

    private var item: AnnotationItem? {
        model.timeline.annotations.first { $0.id == id }
    }

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Kind", selection: kind) {
                    Label("Text", systemImage: "textformat").tag(KindTag.text)
                    Label("Arrow", systemImage: "arrow.up.right").tag(KindTag.arrow)
                    Label("Box", systemImage: "rectangle").tag(KindTag.rectangle)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)

                if case .text = item.kind {
                    TextField("Say something", text: text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)

                    InspectorSlider(model: model, "Size", systemImage: "textformat.size",
                                    value: fontSize, range: 0.02...0.2)
                }

                ColorPicker("Colour", selection: colour, supportsOpacity: true)

                InspectorRow(title: "Starts", value: Timecode.short(item.start))
                InspectorRow(title: "Lasts", value: Timecode.length(item.duration))
            }
            .font(.system(size: 12))
            .inspectorSection("Annotation", systemImage: "character.textbox") {
                AddAnnotationButton(model: model)
            }
        }
    }

    // MARK: - Bindings

    /// The kind, as something a segmented picker can hold.
    ///
    /// `AnnotationItem.Kind` carries a payload — the text, the arrow's two ends — so it
    /// cannot be a tag directly. Switching kind keeps the rectangle and throws the
    /// payload away, which is what "make this an arrow instead" means.
    private enum KindTag: Hashable { case text, arrow, rectangle }

    private var kind: Binding<KindTag> {
        Binding {
            guard let item else { return .text }
            return switch item.kind {
            case .text: .text
            case .arrow: .arrow
            case .rectangle, .image: .rectangle
            }
        } set: { tag in
            model.restyleAnnotation(id, "Annotation Kind") { item in
                switch tag {
                case .text:
                    item.kind = .text("")
                case .arrow:
                    // Corner to corner of its own rectangle, so a freshly switched arrow
                    // points somewhere rather than being a zero-length dot.
                    item.kind = .arrow(from: CGPoint(x: item.rect.minX, y: item.rect.maxY),
                                       to: CGPoint(x: item.rect.maxX, y: item.rect.minY))
                case .rectangle:
                    item.kind = .rectangle
                }
            }
        }
    }

    private var text: Binding<String> {
        Binding {
            guard let item, case .text(let string) = item.kind else { return "" }
            return string
        } set: { string in
            model.restyleAnnotation(id, "Annotation Text") { $0.kind = .text(string) }
        }
    }

    private var fontSize: Binding<Double> {
        Binding {
            item?.fontSize ?? 0.06
        } set: { size in
            model.restyleAnnotation(id, "Annotation Size") { $0.fontSize = size }
        }
    }

    private var colour: Binding<Color> {
        Binding {
            guard let item else { return .red }
            return Color(item.color.rgba.nsColor)
        } set: { colour in
            let value = RGBA(NSColor(colour)).colorValue
            model.restyleAnnotation(id, "Annotation Colour") { $0.color = value }
        }
    }
}
