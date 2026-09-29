import AppKit
import BackgroundKit
import CoreMedia
import SwiftUI
import TimelineKit

/// What a label, an arrow or a box says, how it looks, how it comes and goes, and when.
///
/// In the order an annotation is made: what it is, how it looks, how it arrives, when it
/// is on screen. Only what nearly everybody reaches for is out in the open; the exact
/// numbers — turn, placement, the length of each end, the curve — are under Advanced, for
/// the person who already knows they want them. Moving and sizing are on the picture,
/// which is where they belong; the numbers here are the second way in, not the first.
struct AnnotationInspector: View {
    let model: EditorModel
    let id: UUID

    private var item: AnnotationItem? { model.annotation(id) }

    private var isAdvancedOpen: Binding<Bool> {
        Binding { model.isAnnotationAdvancedOpen } set: { model.isAnnotationAdvancedOpen = $0 }
    }

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenGroups) {
                content(item)
                appearance(item)
                animation(item)
                timing(item)
                advanced(item)
            }
            .font(.system(size: 12))
            .inspectorSection("Annotation", systemImage: "character.textbox") {
                HStack(spacing: 2) {
                    headerToggle(on: item.isHidden, symbol: item.isHidden ? "eye.slash" : "eye",
                                 help: item.isHidden ? "Show — it is left out of the preview and the export"
                                                     : "Hide from the preview and the export") {
                        model.toggleHidden(ofAnnotation: id)
                    }
                    headerToggle(on: item.isLocked, symbol: item.isLocked ? "lock.fill" : "lock.open",
                                 help: item.isLocked ? "Unlock so it can be moved"
                                                     : "Lock so it cannot be moved by accident") {
                        model.toggleLock(ofAnnotation: id)
                    }
                    AddAnnotationButton(model: model)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ item: AnnotationItem) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Picker("Kind", selection: kind) {
                Label("Text", systemImage: "textformat").tag(KindTag.text)
                Label("Arrow", systemImage: "arrow.up.right").tag(KindTag.arrow)
                Label("Box", systemImage: "rectangle").tag(KindTag.rectangle)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()

            if case .text = item.kind {
                TextField("Say something", text: text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)

                InspectorSlider(model: model, "Size", systemImage: "textformat.size",
                                value: restyled(\.fontSize, "Annotation Size"), range: 0.02...0.2)
            }
        }
    }

    // MARK: - Appearance

    private func appearance(_ item: AnnotationItem) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorField(title: "Colour") {
                ColorPicker("Colour", selection: colour, supportsOpacity: true)
            }
            InspectorSlider(model: model, "Opacity", value: restyled(\.opacity, "Annotation Opacity"),
                            range: 0...1)
        }
    }

    // MARK: - Animation

    private func animation(_ item: AnnotationItem) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorField(title: "In") {
                InspectorPicker(selection: restyled(\.animation.entrance, "Animate In"),
                                options: AnnotationAnimation.Entrance.allCases) { $0.title }
            }
            InspectorField(title: "Out") {
                InspectorPicker(selection: restyled(\.animation.exit, "Animate Out"),
                                options: AnnotationAnimation.Exit.allCases) { $0.title }
            }
        }
    }

    // MARK: - Timing

    /// Start, length and end, each typed. Changing the end changes the length and keeps the
    /// start, which is what "make it stop at 6 seconds" means.
    private func timing(_ item: AnnotationItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorField(title: "Start") {
                TimeField(seconds: item.start.seconds, format: { Timecode.precise(Self.time($0)) }) { seconds in
                    model.setTiming(ofAnnotation: id, start: Self.time(seconds))
                }
            }
            InspectorField(title: "Duration") {
                TimeField(seconds: item.duration.seconds, format: { String(format: "%.2fs", $0) }) { seconds in
                    model.setTiming(ofAnnotation: id, duration: Self.time(seconds))
                }
            }
            InspectorField(title: "End") {
                TimeField(seconds: item.end.seconds, format: { Timecode.precise(Self.time($0)) }) { seconds in
                    model.setTiming(ofAnnotation: id, duration: Self.time(seconds - item.start.seconds))
                }
            }
        }
        .disabled(item.isLocked)
        .help(item.isLocked ? "Unlock it to change when it is on screen" : "")
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }

    // MARK: - Advanced

    private func advanced(_ item: AnnotationItem) -> some View {
        DisclosureGroup(isExpanded: isAdvancedOpen) {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                InspectorSlider(model: model, "Rotation", value: restyled(\.rotation, "Rotate"),
                                range: -180...180, format: { "\(Int($0.rounded()))°" })
                    .disabled(item.isLocked)

                HStack(spacing: 8) {
                    number("X", \.origin.x, item)
                    number("Y", \.origin.y, item)
                }
                HStack(spacing: 8) {
                    number("W", \.size.width, item)
                    number("H", \.size.height, item)
                }

                InspectorSlider(model: model, "In length", value: restyled(\.animation.entranceDuration, "Animate In"),
                                range: 0...2, format: { String(format: "%.2fs", $0) })
                InspectorSlider(model: model, "Out length", value: restyled(\.animation.exitDuration, "Animate Out"),
                                range: 0...2, format: { String(format: "%.2fs", $0) })
                InspectorField(title: "Easing") {
                    InspectorPicker(selection: restyled(\.animation.easing, "Animation Easing"),
                                    options: Easing.allCases) { $0.rawValue.capitalized }
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Advanced")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    /// One side of the placement, as a percentage of the finished frame — the unit the
    /// model keeps it in, so a number typed here lands exactly where it says.
    private func number(_ title: String, _ path: WritableKeyPath<CGRect, CGFloat>, _ item: AnnotationItem) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            TimeField(seconds: Double(item.rect[keyPath: path]) * 100,
                      format: { String(format: "%.1f%%", $0) }) { percent in
                var rect = item.rect
                rect[keyPath: path] = CGFloat(percent / 100)
                model.setRegionRect(id, rect: rect)
            }
        }
        .disabled(item.isLocked)
    }

    private func headerToggle(on: Bool, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Bindings

    /// Any stored property of the annotation, as a binding that writes one undo step.
    private func restyled<Value: Equatable & Sendable>(_ path: WritableKeyPath<AnnotationItem, Value> & Sendable,
                                                       _ name: String) -> Binding<Value> {
        Binding {
            model.annotation(id)?[keyPath: path] ?? AnnotationItem(start: .zero, duration: .zero, kind: .rectangle,
                                                                    rect: .zero)[keyPath: path]
        } set: { value in
            model.restyleAnnotation(id, name) { $0[keyPath: path] = value }
        }
    }

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
                    item.kind = .arrow(from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0))
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

/// A number you can type, committed on Return or when the field loses focus.
///
/// Not bound live: a time half-typed ("0:0") is not a time, and writing each keystroke to
/// the document would move the annotation to zero and back while somebody types. What is
/// shown is the model's value, formatted, until editing starts; an entry that does not
/// parse puts the old value back.
struct TimeField: View {
    let seconds: Double
    let format: (Double) -> String
    let commit: (Double) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 96)
            .focused($isFocused)
            .onAppear { text = format(seconds) }
            .onChange(of: seconds) { _, value in if !isFocused { text = format(value) } }
            .onChange(of: isFocused) { _, focused in if !focused { submit() } }
            .onSubmit { submit() }
    }

    private func submit() {
        let cleaned = text.replacingOccurrences(of: "%", with: "")
        if let value = Timecode.parse(cleaned) ?? Double(cleaned.trimmingCharacters(in: .whitespaces)),
           value.isFinite, abs(value - seconds) > 0.0005 {
            commit(value)
        }
        text = format(seconds)
    }
}
