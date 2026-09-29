import SwiftUI
import TimelineKit

/// The two whole numbers a custom shape is made of, and what is wrong with them when
/// something is.
///
/// Typed into text fields rather than steppers, because "16 by 10" is two numbers
/// somebody already knows, and applied when a field is left or Return is pressed —
/// never keystroke by keystroke, or typing "16" would pass through a 1 : 9 frame on the
/// way. A pair that is refused stays in the fields with the reason under them, and the
/// project keeps the shape it had.
struct CustomAspectFields: View {
    let model: EditorModel

    @State private var width = ""
    @State private var height = ""
    @State private var refusal: CustomAspect.Refusal?
    @FocusState private var focused: Side?

    private enum Side { case width, height }

    private static let rule = "Whole numbers from 1 to 100. No wider than 3 : 1, no taller than 1 : 3."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Ratio")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 66, alignment: .leading)
                field("W", text: $width, side: .width)
                Text(":")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                field("H", text: $height, side: .height)
                Spacer(minLength: 0)
            }
            Text(refusal?.message ?? Self.rule)
                .font(.caption)
                .foregroundStyle(refusal == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: model.timeline.style.customAspect, initial: true) { _, shape in
            // The document leads — an undo has to move the numbers — except while one of
            // them is being typed into.
            guard focused == nil else { return }
            width = String(shape.width)
            height = String(shape.height)
            refusal = nil
        }
        .onChange(of: focused) { was, now in
            // Only once both fields have been left: checking on the way from one to the
            // other would call "16" beside last time's "2" too wide before there was a
            // chance to type the 10.
            if was != nil, now == nil { commit() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Custom shape")
    }

    private func field(_ placeholder: String, text: Binding<String>, side: Side) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 12).monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 46)
            .focused($focused, equals: side)
            .onSubmit { commit() }
            .accessibilityLabel(side == .width ? "Width" : "Height")
    }

    private func commit() {
        if let why = CustomAspect.refusal(width: width, height: height) {
            refusal = why
            return
        }
        refusal = nil
        guard let w = Int(width.trimmingCharacters(in: .whitespaces)),
              let h = Int(height.trimmingCharacters(in: .whitespaces)) else { return }
        let typed = CustomAspect(width: w, height: h)
        guard typed != model.timeline.style.customAspect else { return }
        model.apply(Commands.Restyle("Shape") { $0.style.customAspect = typed })
    }
}
