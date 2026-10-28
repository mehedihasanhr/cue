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
            // Groups told apart by space rather than by headings of their own: what it is,
            // its type, how it looks, how it comes and goes, when. Five headings in one
            // selection would be a second panel's worth of chrome.
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
            // Named for what it is: the panel's own heading already says Annotation.
            .inspectorSection(item.kind.name.title, systemImage: item.kind.name.symbol) {
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
        InspectorRow("Picture") {
            StudioButton("Replace", size: .small) { model.replacePicture(ofAnnotation: id) }
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
            InspectorRow("Kind") {
                InspectorPicker(selection: kind, options: AnnotationItem.KindName.switchable) { $0.title }
            }

            if item.kind.hasWords {
                // Return is a new line here too, as it is on the picture. See `StudioTextArea`.
                StudioTextArea(text: text,
                               font: .systemFont(ofSize: 12.5),
                               colour: .white.withAlphaComponent(0.92),
                               placeholder: "Say something",
                               maxLines: 6)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(StudioTheme.Surface.field,
                                in: RoundedRectangle(cornerRadius: InspectorMetrics.fieldRadius, style: .continuous))
                    .accessibilityLabel("Annotation text")

                textSize(item)
            }

            if case .step = item.kind {
                // The kit's stepper with its readout as a field of its own, so a step can
                // be counted to by the buttons or jumped to by typing.
                InspectorRow("Number") {
                    HStack(spacing: StudioTheme.Spacing.tight) {
                        StudioIconButton(systemImage: "minus", help: "One lower", variant: .secondary, size: .small) {
                            stepNumber.wrappedValue -= 1
                        }
                        .disabled(stepNumber.wrappedValue <= AnnotationItem.stepRange.lowerBound)
                        TimeField(seconds: Double(stepNumber.wrappedValue),
                                  format: { String(Int($0)) },
                                  width: 44,
                                  alignment: .center) { value in
                            stepNumber.wrappedValue = Int(value.rounded())
                        }
                        .accessibilityLabel("Number")
                        StudioIconButton(systemImage: "plus", help: "One higher", variant: .secondary, size: .small) {
                            stepNumber.wrappedValue += 1
                        }
                        .disabled(stepNumber.wrappedValue >= AnnotationItem.stepRange.upperBound)
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
            InspectorRow("Weight") {
                InspectorPicker(selection: restyled(\.style.weight, "Text Weight"),
                                options: AnnotationStyle.Weight.allCases) { $0.title }
            }
            InspectorRow("Align") {
                InspectorPicker(selection: restyled(\.style.alignment, "Text Alignment"),
                                options: AnnotationStyle.Alignment.allCases) { $0.title }
            }
            InspectorRow(item.kind.name == .callout ? "Bubble" : "Backdrop") {
                InspectorPicker(selection: restyled(\.style.backdrop, "Text Backdrop"),
                                options: AnnotationStyle.Backdrop.allCases) { backdrop in
                    // A callout with nothing behind its words is still a bubble: an outline.
                    item.kind.name == .callout && backdrop == .none ? "Outline" : backdrop.title
                }
            }
            InspectorSwitch("Outline letters", isOn: restyled(\.style.outlinesText, "Outline Letters"))
                .help("A dark or light ring round each letter, so it reads over a busy picture")
        }
    }

    // MARK: - Appearance

    private func appearance(_ item: AnnotationItem) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            // A picture brings its own colours.
            if !item.isPicture {
                InspectorRow("Colour") {
                    InspectorColorWell(title: "Annotation colour", selection: colour, supportsOpacity: true)
                }
            }
            // Only where there is a line to thicken: a callout has one only when it is drawn
            // as an outline.
            if item.kind.hasThickness || (item.kind.name == .callout && item.style.backdrop == .none) {
                InspectorSlider(model: model, "Thickness", value: restyled(\.style.thickness, "Line Thickness"),
                                range: 0.5...6, format: { String(format: "%.1f×", $0) })
            }
            if item.kind.canBeFilled {
                InspectorRow("Fill") {
                    InspectorPicker(selection: restyled(\.style.fill, "Fill"),
                                    options: AnnotationStyle.Fill.allCases) { $0.title }
                }
            }
            InspectorSlider(model: model, "Opacity", value: restyled(\.opacity, "Annotation Opacity"),
                            range: 0...1)
            InspectorSwitch("Shadow", isOn: restyled(\.style.hasShadow, "Shadow"))
                .help("A soft shadow under it, so it lifts off a busy picture")
        }
    }

    // MARK: - Animation

    ///
    /// Each change plays once on the paused picture — the way in when In changes, the way out
    /// when Out does — so what was chosen is seen without playing the video to find it. The
    /// play button runs the whole chain: in, a moment held, out.
    private func animation(_ item: AnnotationItem) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorRow("In") {
                InspectorPicker(selection: previewing(restyled(\.animation.entrance, "Animate In"), .entrance),
                                options: AnnotationAnimation.Entrance.allCases) { $0.title }
            }
            InspectorRow("Out") {
                InspectorPicker(selection: previewing(restyled(\.animation.exit, "Animate Out"), .exit),
                                options: AnnotationAnimation.Exit.allCases) { $0.title }
            }
            HStack {
                Spacer(minLength: 0)
                SectionButton(title: "▶  Play animation") {
                    model.previewAnimation(ofAnnotation: id, .chain)
                }
                .disabled(item.animation.entrance == .none && item.animation.exit == .none)
                .help("Play this annotation's way in and way out once, without playing the video")
            }
        }
    }

    /// A binding that plays `part` of the animation once its value changes. Sliders wait for
    /// the drag to settle, so one drag is one preview rather than forty restarts.
    private func previewing<Value: Equatable>(_ binding: Binding<Value>,
                                              _ part: AnnotationAnimationPreview.Part,
                                              settle: Duration = .zero) -> Binding<Value> {
        Binding {
            binding.wrappedValue
        } set: { value in
            guard value != binding.wrappedValue else { return }
            binding.wrappedValue = value
            model.previewAnimation(ofAnnotation: id, part, after: settle)
        }
    }

    // MARK: - Timing

    /// Start, length and end, each typed. Changing the end changes the length and keeps the
    /// start, which is what "make it stop at 6 seconds" means.
    private func timing(_ item: AnnotationItem) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorRow("Start") {
                TimeField(seconds: item.start.seconds, format: { Timecode.precise(Self.time($0)) }) { seconds in
                    model.setTiming(ofAnnotation: id, start: Self.time(seconds))
                }
            }
            InspectorRow("Duration") {
                TimeField(seconds: item.duration.seconds, format: { String(format: "%.2fs", $0) }) { seconds in
                    model.setTiming(ofAnnotation: id, duration: Self.time(seconds))
                }
            }
            InspectorRow("End") {
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
        InspectorDisclosure("Advanced", isExpanded: isAdvancedOpen) {
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

            InspectorSlider(model: model, "In length",
                            value: previewing(restyled(\.animation.entranceDuration, "Animate In"), .entrance,
                                              settle: .milliseconds(350)),
                            range: 0...2, format: { String(format: "%.2fs", $0) })
            InspectorSlider(model: model, "Out length",
                            value: previewing(restyled(\.animation.exitDuration, "Animate Out"), .exit,
                                              settle: .milliseconds(350)),
                            range: 0...2, format: { String(format: "%.2fs", $0) })
            InspectorRow("Easing") {
                InspectorPicker(selection: previewing(restyled(\.animation.easing, "Animation Easing"), .chain),
                                options: Easing.allCases) { $0.rawValue.capitalized }
            }
        }
    }

    /// One side of the placement, as a percentage of the finished frame — the unit the
    /// model keeps it in, so a number typed here lands exactly where it says.
    private func number(_ title: String, _ path: WritableKeyPath<CGRect, CGFloat>, _ item: AnnotationItem) -> some View {
        HStack(spacing: 6) {
            InspectorLabel(title)
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

    /// The words' size on its own, in pixels of the finished video: a step either way, or a
    /// number typed in. Pulling the box on the picture sizes the box; this sizes the type —
    /// so a callout's bubble and its words can each be made the size they need to be.
    ///
    /// It was a slider over a share of a range, which read "1%" for type that was plainly
    /// not one per cent of anything, and began above the smallest size a box could give.
    private func textSize(_ item: AnnotationItem) -> some View {
        let height = max(1, model.outputSize.height)
        let pixels = item.fontSize * height
        let step = max(1, (height / 270).rounded())
        func set(_ value: Double) {
            let share = min(0.3, max(0.012, value / height))
            model.restyleAnnotation(id, "Text Size") { $0.fontSize = share }
        }
        return InspectorRow("Text size") {
            HStack(spacing: 4) {
                StudioIconButton(systemImage: "textformat.size.smaller", help: "Smaller text", size: .small) {
                    set(pixels - step)
                }
                // A number of pixels, read as one: as a time, "30" was thirty seconds' worth of
                // something and the type went to the largest it can be.
                TimeField(seconds: pixels.rounded(), format: { String(format: "%.0f px", $0) }, width: 64,
                          parse: { Double($0.lowercased().replacingOccurrences(of: "px", with: "")
                                        .trimmingCharacters(in: .whitespaces)) }) { value in
                    set(value)
                }
                .accessibilityLabel("Text size in pixels")
                StudioIconButton(systemImage: "textformat.size.larger", help: "Bigger text", size: .small) {
                    set(pixels + step)
                }
            }
        }
        .disabled(item.isLocked)
    }

    /// A ghost glyph on the heading, lit in the accent while what it switches is on.
    private func headerToggle(on: Bool, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        StudioIconButton(systemImage: symbol, help: help, size: .small, isActive: on, action: action)
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
///
/// Drawn in the kit's field chrome rather than the system's sunken rounded border, with
/// the focus kept here so the reformat-on-leave above still has something to watch.
struct TimeField: View {
    let seconds: Double
    let format: (Double) -> String
    var width: CGFloat = 96
    var alignment: TextAlignment = .trailing
    /// How what was typed is read, when it is not a time or a percentage — a size in pixels.
    var parse: ((String) -> Double?)?
    let commit: (Double) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .font(.system(size: 11, design: .monospaced))
            .multilineTextAlignment(alignment)
            .focused($isFocused)
            .studioField(isFocused: isFocused)
            .frame(maxWidth: width)
            .onAppear { text = format(seconds) }
            .onChange(of: seconds) { _, value in if !isFocused { text = format(value) } }
            .onChange(of: isFocused) { _, focused in if !focused { submit() } }
            .onSubmit { submit() }
    }

    private func submit() {
        if let parse {
            if let value = parse(text) { commit(value) }
            text = format(seconds)
            return
        }
        let cleaned = text.replacingOccurrences(of: "%", with: "")
        if let value = Timecode.parse(cleaned) ?? Double(cleaned.trimmingCharacters(in: .whitespaces)),
           value.isFinite, abs(value - seconds) > 0.0005 {
            commit(value)
        }
        text = format(seconds)
    }
}
