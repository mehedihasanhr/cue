import SwiftUI
import TimelineKit

/// The one grid the left of the window is built on.
///
/// The rail, the settings panel and the transport under it are three views that have to
/// read as one column, and three views that each measured themselves is exactly how the
/// headings ended up two points off the cards beneath them. One set of numbers, used by
/// all of them.
enum SidebarMetrics {
    /// The tool rail's width.
    static let railWidth: CGFloat = 52
    /// The band across the top of the sidebar: the panel's heading, and the blank beside
    /// it over the rail, so the line underneath runs the whole width of the column.
    static let headerHeight: CGFloat = 38
    /// How far in anything on the sidebar starts — a heading, a card, the timecode.
    static let contentInset: CGFloat = 14
}

/// The four gaps the settings column is built from, and nothing in between.
///
/// With the cards gone, space is the only thing left doing the grouping, so the steps
/// have to be far enough apart to be read as steps. Each one is roughly half again the
/// last: a name and its own track are nearly touching, two controls are clearly two, a
/// picker and the stack of sliders under it are clearly two *kinds* of thing, and two
/// sections are clearly two sections.
enum SidebarSpacing {
    /// A label and the track it belongs to.
    static let withinControl: CGFloat = 5
    /// Two controls that do the same sort of thing — four sliders in a row.
    static let betweenControls: CGFloat = 14
    /// Two kinds of thing inside one section — the Shape picker and the sliders.
    static let betweenGroups: CGFloat = 26
    /// Above and below the rule that closes a section off. The same number on both
    /// sides, so the rule sits in the middle of the space rather than under the block
    /// above it.
    static let sectionPadding: CGFloat = 16
    /// Sections are separated by their own rule and its padding, so the stack that holds
    /// them adds nothing of its own.
    static let betweenSections: CGFloat = 0
}

extension View {
    /// The chrome's surface: the system bar material, darkened.
    ///
    /// `.bar` on its own is a light grey in dark mode, and three columns of it put more
    /// light down the side of the window than the picture in the middle of it. Tinted
    /// down, the chrome recedes and the frame is the brightest thing on screen — which
    /// is the whole arrangement this editor is built around. The same tint the title bar
    /// uses, from one number, so the four surfaces are one surface.
    ///
    /// Dark mode only. Under a light appearance the same third of black turned every panel,
    /// the title bar and the stage a flat mid-grey — the whole window looked disabled, and
    /// the light frame on the stage no longer stood out from anything. Light chrome is
    /// already quieter than a picture, so it is left as the system draws it.
    func studioSurface() -> some View {
        modifier(StudioSurface())
    }
}

private struct StudioSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                Rectangle().fill(.bar)
                if colorScheme == .dark {
                    Rectangle().fill(.black.opacity(StudioChromeTint.amount))
                }
            }
        }
    }
}

enum StudioChromeTint {
    static let amount: Double = 0.34
    /// Every hairline in the editor: the lines between the columns, under the title bar,
    /// and around a card.
    ///
    /// `Divider()` draws the system's separator colour, which is tuned for a window made
    /// of light grey panels. Against chrome this dark it is a bright line, and there are
    /// enough of them in this layout to read as a wireframe drawn over the work. A
    /// separator only has to be *findable*, not visible.
    static let hairline = Color.primary.opacity(0.04)
    /// The rule between two sections. Twice the structural hairline: this one is not
    /// chrome, it is the thing telling you where Background ends, and at four percent it
    /// was invisible — leaving a gap that read as a mistake rather than as a boundary.
    static let sectionRule = Color.primary.opacity(0.09)
}

/// The editor's own separator, at `StudioChromeTint.hairline`.
struct StudioDivider: View {
    enum Axis { case horizontal, vertical }

    var axis: Axis = .horizontal
    /// Set only where the line is a short one between two controls.
    var length: CGFloat?
    /// The section rule, rather than a structural hairline.
    var isSection = false

    var body: some View {
        Rectangle()
            .fill(isSection ? StudioChromeTint.sectionRule : StudioChromeTint.hairline)
            .frame(width: axis == .vertical ? 1 : nil,
                   height: axis == .vertical ? length : 1)
            .accessibilityHidden(true)
    }
}

/// The pieces every inspector section is built from.
///
/// One place for the undo pattern, so it is decided once rather than at forty call
/// sites: a discrete control is one command, and a continuous one is a command per
/// change bracketed by an interaction, which collapses the whole drag into a single
/// entry named for the thing being dragged.
@MainActor
struct StyleBinding {
    let model: EditorModel

    /// A tap: one entry on the undo stack, named for what it changed.
    func set<Value: Sendable & Equatable>(_ path: WritableKeyPath<Timeline, Value> & Sendable,
                                          to value: Value,
                                          _ name: String) {
        model.apply(Commands.Restyle(name) { $0[keyPath: path] = value })
    }

    /// A slider or a toggle. The coalescing comes from the interaction around the drag,
    /// which `slider(_:)` below wires up.
    func binding<Value: Sendable & Equatable>(_ path: WritableKeyPath<Timeline, Value> & Sendable,
                                              _ name: String) -> Binding<Value> {
        Binding {
            model.timeline[keyPath: path]
        } set: { value in
            model.apply(Commands.Restyle(name) { $0[keyPath: path] = value })
        }
    }
}

// MARK: - The row system

/// The few measurements every row in the panel shares.
///
/// One number for the height of a row, so a switch, a pop-up, a colour well and a fact sit
/// on the same rhythm down the column. Before this each control brought its own height —
/// a checkbox was 16 points, a hand-styled pop-up 30 — and the column read as a stack of
/// unrelated parts rather than one list.
enum InspectorMetrics {
    /// The least a one-line row is tall: a small switch or a small pop-up, with no slack.
    static let rowHeight: CGFloat = 22
    /// How far a row's name stays from its control, at the narrowest.
    static let labelGap: CGFloat = 10
}

/// The heading of a section.
///
/// Semibold and primary, the one place in the panel with any weight: the names of the
/// controls under it are regular and secondary, so the heading is told apart by weight
/// and ink together rather than by size, and every section — whichever panel it is on —
/// is headed in exactly the same type.
struct InspectorHeading: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A heading inside a section: the group of sources, the camera's motion under a zoom.
///
/// Quieter than a section heading — it names a part of the section, not a new subject —
/// and louder than a control's name, so the controls under it read as belonging to it.
struct InspectorSubheading: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A section: a heading row, its controls, and a rule closing it off.
///
/// The rule is at the end of the section rather than under its title, where it does the
/// job a rule is for: saying where one thing stops and the next starts. The same air
/// above and below it, so the line is a boundary between two blocks rather than a lid on
/// the one above — which means the stack holding the sections must add nothing itself.
///
/// What sits at the end of the heading is as often a control as a word — the shape's
/// pop-up, a Reset — so the row is centred rather than baseline-aligned, and given a
/// row's height whether or not anything is there, so a heading with a pop-up and one
/// without start their controls at the same depth.
struct InspectorSection<Content: View, Trailing: View>: View {
    let title: String
    let content: Content
    let trailing: Trailing

    init(_ title: String,
         @ViewBuilder content: () -> Content,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                HStack(alignment: .center, spacing: 8) {
                    InspectorHeading(title)
                    Spacer(minLength: 8)
                    trailing
                        .lineLimit(1)
                }
                .frame(minHeight: InspectorMetrics.rowHeight)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, SidebarSpacing.sectionPadding)

            StudioDivider(isSection: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension InspectorSection where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, trailing: { EmptyView() })
    }
}

extension View {
    /// This view as a section's body, under `title`. See `InspectorSection`.
    ///
    /// `systemImage` is not drawn — a column of little grey glyphs beside headings that
    /// already say what they are was decoration — and is kept so the call sites go on
    /// describing themselves.
    func inspectorSection(_ title: String,
                          systemImage: String,
                          @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        InspectorSection(title, content: { self }, trailing: trailing)
    }
}

/// The name of a control, on the left of its row or above its track.
///
/// Dims with the control when the control is off. A disabled `Toggle` or `Picker` greys
/// itself, but a `Text` beside it does not, and a bright name next to a dead control
/// reads as a control that is broken rather than one that is waiting for something.
struct InspectorLabel: View {
    let title: String

    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .opacity(isEnabled ? 1 : 0.55)
            // Wraps rather than truncates: a name cut to "Keep size wh…" is a name you
            // have to hover to read, and the column is narrow enough that some will meet
            // its edge.
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A name on the left, a control on the right.
///
/// The one row the panel is built from. The control is given its own width first and the
/// name wraps in what is left, so nothing is ever cut short — the failure the old fixed
/// 66-point name column had, where "Holds the frame at" lost its end. The control sits
/// against the right-hand edge, where the sliders put their readouts, so the column has
/// one edge down each side.
///
/// The label is a `Text` of its own rather than a control's own label, because a
/// `Picker`'s built-in label sets a minimum width nobody can argue with.
struct InspectorRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: InspectorMetrics.labelGap) {
            InspectorLabel(title)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            control
                .labelsHidden()
                .layoutPriority(1)
                .accessibilityLabel(title)
        }
        .frame(minHeight: InspectorMetrics.rowHeight)
        .accessibilityElement(children: .contain)
    }
}

extension InspectorRow where Control == InspectorValue {
    /// A name on the left, a fact on the right: a size, a time, a file's name.
    init(title: String, value: String) {
        self.init(title) { InspectorValue(value) }
    }
}

/// A fact at the end of a row.
///
/// Shrinks rather than truncates or pushes: a pixel size like "2,714 × 1,612" in a view
/// that refuses to give up its ideal width made the whole panel demand more room than its
/// column had, and a fixed-width frame does not clip.
struct InspectorValue: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// An on-and-off, as a row: the name on the left, a small switch on the right.
///
/// One style of on-and-off for the whole editor. The panels used to mix checkboxes with
/// the odd switch, which made two settings of the same kind look like two kinds of
/// setting; a switch at the row's end lines up with the pop-ups and colour wells in the
/// rows around it, where a checkbox would sit at the opposite edge.
struct InspectorSwitch: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        HStack(alignment: .center, spacing: InspectorMetrics.labelGap) {
            InspectorLabel(title)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .layoutPriority(1)
        }
        .frame(minHeight: InspectorMetrics.rowHeight)
    }
}

/// A sentence under a control, for the rare one that needs it.
///
/// Rare on purpose. The panels had a paragraph under nearly every control, which made
/// them long and made the one sentence that mattered — "No stretch asks for it yet" —
/// look like all the others. The explanations moved into tooltips on the controls they
/// explain, word for word; what stays here is a line that changes what you would do next.
struct InspectorNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row of choices that always fits the panel.
///
/// Drawn as a segmented control — one recessed track, the chosen segment raised out of
/// it — and laid out on as many rows as it takes for every title to be shown whole, in
/// one size of type. A single row of six ("Wallpaper Gradient Color Image Motion None")
/// is wider than the column, and the old answer was to shrink each title until it fitted,
/// which left "Color" in larger type than "Motion" next to it and still cut "Wallp…" short.
/// Now the row is tried first, then two, then three: the first that fits is the one drawn.
///
/// Not `.pickerStyle(.segmented)`: a segmented control reports the sum of its titles as
/// the width it must have, and cannot wrap.
struct InspectorTabs<Item: Identifiable & Hashable>: View {
    @Binding var selection: Item
    let items: [Item]
    let title: (Item) -> String

    @State private var hovered: Item?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            track(rows: 1)
            track(rows: 2)
            track(rows: 3)
        }
        .animation(StudioMotion.state, value: selection)
        .animation(StudioMotion.hover, value: hovered)
        .accessibilityElement(children: .contain)
    }

    private func track(rows: Int) -> some View {
        let perRow = max(1, Int((Double(items.count) / Double(rows)).rounded(.up)))
        let lines = stride(from: 0, to: items.count, by: perRow).map {
            Array(items[$0..<min($0 + perRow, items.count)])
        }
        return VStack(spacing: 2) {
            ForEach(lines.indices, id: \.self) { line in
                HStack(spacing: 2) {
                    ForEach(lines[line]) { item in
                        segment(item)
                    }
                }
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
        }
    }

    private func segment(_ item: Item) -> some View {
        let isSelected = item == selection
        return Button { selection = item } label: {
            Text(title(item))
                .font(.system(size: 12))
                .lineLimit(1)
                // Its whole width, always: this is what lets the row fail to fit and
                // hand over to two rows, rather than squeezing its titles.
                .fixedSize()
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(fill(isSelected: isSelected, isHovered: hovered == item))
                        .shadow(color: .black.opacity(isSelected && colorScheme == .light ? 0.12 : 0),
                                radius: 1, y: 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
        .accessibilityLabel(title(item))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The chosen segment is a raised surface, as a system segmented control draws it:
    /// white in light mode, a lighter grey in dark. The rest are the track, lit a little
    /// under the pointer.
    private func fill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return colorScheme == .dark ? Color.white.opacity(0.17) : Color.white
        }
        return Color.primary.opacity(isHovered ? 0.05 : 0)
    }
}

/// A word you can press: Reset, Show all. Quiet enough to sit on a heading or under a
/// section without competing with the controls between them.
struct SectionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(.tint)
            .lineLimit(1)
    }
}

/// A pop-up: the system's own, small, sized to what it is showing.
///
/// It used to be a hand-made squircle with fourteen points of padding either side — a
/// pill that was the largest thing in its row, and the audit's "Shape: Linear" slab. A
/// small system pop-up says "menu" the way every Mac app says it, in light and dark, and
/// takes the width of its longest title rather than the row's.
struct InspectorPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    var body: some View {
        // A value the list does not offer — a speed set some other way — is added to it
        // rather than shown as a blank: the old pop-up drew whatever the value was, and a
        // system pop-up with no matching item draws nothing at all.
        let shown = options.contains(selection) ? options : options + [selection]
        Picker(selection: $selection) {
            ForEach(shown, id: \.self) { option in
                Text(title(option)).tag(option)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityValue(Text(title(selection)))
    }
}

/// A colour well, the system's, at the size of the rows around it.
struct InspectorColorWell: View {
    let title: String
    @Binding var selection: Color
    var supportsOpacity = false

    var body: some View {
        ColorPicker(title, selection: $selection, supportsOpacity: supportsOpacity)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel(title)
    }
}

/// A time with a step either way: a caption's start, a clip's out-point, a zoom's start.
///
/// One control for all of them, so a nudge looks and behaves the same wherever it is —
/// they had grown up as three different pairs of buttons, two of them `+` and `−` and one
/// of them chevrons, each with its own column width for the name.
struct InspectorNudgeRow: View {
    let title: String
    let value: String
    /// What a press of each one does, said in the tooltip and to VoiceOver.
    let earlierHelp: String
    let laterHelp: String
    let earlier: () -> Void
    let later: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            InspectorLabel(title)
            Spacer(minLength: InspectorMetrics.labelGap)
            NudgeButton(symbol: "chevron.left", help: earlierHelp, action: earlier)
            Text(value)
                .font(.system(size: 12).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 58)
            NudgeButton(symbol: "chevron.right", help: laterHelp, action: later)
        }
        .frame(minHeight: InspectorMetrics.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) \(value)")
    }
}

/// One step of an `InspectorNudgeRow`.
private struct NudgeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(isHovering ? 0.11 : 0.06),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .animation(StudioMotion.hover, value: isHovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// More settings, folded away until asked for.
///
/// One disclosure for every panel, so "Advanced" under a zoom and under an annotation are
/// the same row with the same chevron — not one system disclosure triangle and one
/// hand-drawn label each.
struct InspectorDisclosure<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let content: Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Button {
                withAnimation(StudioMotion.state) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: InspectorMetrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                    content
                }
            }
        }
    }
}

/// A labelled slider that records one undo entry per drag.
///
/// Two lines: the name and its value on top, the track its own full width underneath.
/// Side by side, a 70-point name column and a 34-point number column left the track
/// about half the panel, which is half the precision. The value is right-aligned in the
/// name's row, in secondary monospaced digits, so a column of sliders has its numbers in
/// one straight line that does not shuffle as they change.
struct InspectorSlider: View {
    let model: EditorModel
    let title: String
    let systemImage: String?
    let value: Binding<Double>
    let range: ClosedRange<Double>
    /// How the number reads. The default is the value's share of the range, which is the
    /// only honest reading of a setting whose units are arbitrary.
    let format: (Double) -> String

    @State private var isDragging = false
    @Environment(\.isEnabled) private var isEnabled

    init(model: EditorModel,
         _ title: String,
         systemImage: String? = nil,
         value: Binding<Double>,
         range: ClosedRange<Double>,
         format: ((Double) -> String)? = nil) {
        self.model = model
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.range = range
        self.format = format ?? { value in
            let span = range.upperBound - range.lowerBound
            guard span > 0 else { return "" }
            return "\(Int((((value - range.lowerBound) / span) * 100).rounded()))%"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.withinControl) {
            // No glyph. A row of little grey icons down the left of the names was a
            // second column of decoration for words that already say what they are. The
            // argument stays so the call sites keep describing themselves.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                InspectorLabel(title)
                Spacer(minLength: 8)
                Text(format(value.wrappedValue))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(isDragging ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .opacity(isEnabled ? 1 : 0.55)
                    .lineLimit(1)
                    .fixedSize()
            }

            StudioSlider(value: value, in: range) { editing in
                // The edit is recorded once per drag, not once per pixel of movement:
                // undo should step back over "Padding", not over four hundred tiny
                // changes.
                isDragging = editing
                if editing {
                    model.document.beginInteraction(title)
                } else {
                    model.finishInteraction()
                }
            }
        }
        .animation(StudioMotion.state, value: isDragging)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// One background choice in the grid.
struct SwatchTile<Content: View>: View {
    let isSelected: Bool
    let title: String
    /// What the tooltip says, when the name alone is not enough.
    var tooltip: String?
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            // The square is laid out first and the picture put inside it, rather than
            // the picture being asked to be square: a wallpaper is 16:9, and asking a
            // 16:9 image to fill a square cell made it take the width it wanted — which
            // is how the grid ended up with pictures lying across their neighbours.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { content }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                        .padding(-3)
                }
                .animation(StudioMotion.selection, value: isSelected)
        }
        .buttonStyle(.plain)
        .help(tooltip ?? title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Collapses a burst of writes into one undo entry.
///
/// For the one control that cannot say when a drag starts and stops: `ColorPicker` has
/// no `onEditingChanged`, and dragging inside the system colour panel writes
/// continuously. Without this, picking a colour by eye costs several hundred undo steps
/// and shoves everything else off the stack.
@MainActor
@Observable
final class InteractionCoalescer {
    private var closing: Task<Void, Never>?
    private var isOpen = false

    /// Takes the model rather than the document, because closing an interaction is not
    /// only a bookkeeping change any more: work deferred for the duration of a gesture is
    /// done on the way out, and a close that went straight to the document would leave the
    /// player holding a mix of the edit as it was before the colour was picked.
    func touch(_ name: String, model: EditorModel, wait: Duration = .milliseconds(400)) {
        if !isOpen {
            model.document.beginInteraction(name)
            isOpen = true
        }
        closing?.cancel()
        closing = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            model.finishInteraction()
            self?.isOpen = false
        }
    }
}
