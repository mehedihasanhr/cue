import AppKit
import BackgroundKit
import CoreMedia
import SwiftUI
import TimelineKit

/// What an annotation says, how it looks, how it comes and goes, and when.
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
                if item.kind.hasWords {
                    typeSettings(item)
                }
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
        if case .image(let path) = item.kind {
            picture(path)
        } else {
            shape(item)
        }
    }

    /// A picture has no kind to switch to: turning a logo into a box would throw the
    /// logo away. What it has instead is a way to swap the picture for another.
    private func picture(_: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text("Picture")
            Spacer(minLength: 8)
            Button("Replace…") { model.replacePicture(ofAnnotation: id) }
                .controlSize(.small)
                .help("Choose another picture for this place")
        }
    }

    /// What it is, and what it says or counts.
    ///
    /// The kind is a pop-up rather than a row of icons: eight kinds do not fit a segmented
    /// control in this column (see `InspectorTabs`), and eight icons squeezed into one would
    /// be eight guesses.
    @ViewBuilder
    private func shape(_ item: AnnotationItem) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorField(title: "Kind") {
                InspectorPicker(selection: kind, options: AnnotationItem.KindName.switchable) { $0.title }
            }

            if item.kind.hasWords {
                TextField("Say something", text: text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)

                InspectorSlider(model: model, "Size", systemImage: "textformat.size",
                                value: restyled(\.fontSize, "Annotation Size"), range: 0.02...0.2)
            }

            if case .step = item.kind {
                InspectorField(title: "Number") {
                    HStack(spacing: 6) {
                        TextField("Number", value: stepNumber, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 52)
                        Stepper("Number", value: stepNumber, in: AnnotationItem.stepRange)
                    }
                }
                .help("New steps count on from the highest number on the timeline")
            }
        }
    }

    // MARK: - Type

    /// How the words are set: family, weight, where they sit, what is behind them.
    private func typeSettings(_ item: AnnotationItem) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            FontFamilyPicker(family: restyled(\.style.fontFamily, "Text Font"))
            InspectorField(title: "Weight") {
                InspectorPicker(selection: restyled(\.style.weight, "Text Weight"),
                                options: AnnotationStyle.Weight.allCases) { $0.title }
            }
            InspectorField(title: "Align") {
                InspectorPicker(selection: restyled(\.style.alignment, "Text Alignment"),
                                options: AnnotationStyle.Alignment.allCases) { $0.title }
            }
            InspectorField(title: item.kind.name == .callout ? "Bubble" : "Backdrop") {
                InspectorPicker(selection: restyled(\.style.backdrop, "Text Backdrop"),
                                options: AnnotationStyle.Backdrop.allCases) { backdrop in
                    // A callout with nothing behind its words is still a bubble: an outline.
                    item.kind.name == .callout && backdrop == .none ? "Outline" : backdrop.title
                }
            }
            Toggle("Outline letters", isOn: restyled(\.style.outlinesText, "Outline Letters"))
                .help("A dark or light ring round each letter, so it reads over a busy picture")
        }
    }

    // MARK: - Appearance

    private func appearance(_ item: AnnotationItem) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            // A picture brings its own colours.
            if !item.isPicture {
                InspectorField(title: "Colour") {
                    ColorPicker("Colour", selection: colour, supportsOpacity: true)
                }
            }
            // Only where there is a line to thicken: a callout has one only when it is drawn
            // as an outline.
            if item.kind.hasThickness || (item.kind.name == .callout && item.style.backdrop == .none) {
                InspectorSlider(model: model, "Thickness", value: restyled(\.style.thickness, "Line Thickness"),
                                range: 0.5...6, format: { String(format: "%.1f×", $0) })
            }
            if item.kind.canBeFilled {
                InspectorField(title: "Fill") {
                    InspectorPicker(selection: restyled(\.style.fill, "Fill"),
                                    options: AnnotationStyle.Fill.allCases) { $0.title }
                }
            }
            InspectorSlider(model: model, "Opacity", value: restyled(\.opacity, "Annotation Opacity"),
                            range: 0...1)
            Toggle("Shadow", isOn: restyled(\.style.hasShadow, "Shadow"))
                .help("A soft shadow under it, so it lifts off a busy picture")
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

    /// The kind, as something a picker can hold.
    ///
    /// `AnnotationItem.Kind` carries a payload — the text, the arrow's two ends — so it
    /// cannot be a tag directly. Switching keeps the rectangle and whatever of the payload
    /// still means something: words between a label and a callout, ends between an arrow
    /// and a line. See `Kind.converted(to:)`.
    private var kind: Binding<AnnotationItem.KindName> {
        Binding {
            item?.kind.name ?? .text
        } set: { name in
            model.setKind(ofAnnotation: id, to: name)
        }
    }

    private var text: Binding<String> {
        Binding {
            item?.kind.text ?? ""
        } set: { string in
            model.setText(ofAnnotation: id, to: string)
        }
    }

    private var stepNumber: Binding<Int> {
        Binding {
            guard let item, case .step(let number) = item.kind else { return 1 }
            return number
        } set: { number in
            model.setStepNumber(ofAnnotation: id, to: min(AnnotationItem.stepRange.upperBound,
                                                          max(AnnotationItem.stepRange.lowerBound, number)))
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
