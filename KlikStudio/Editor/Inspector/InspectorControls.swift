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

extension View {
    /// A section: a heading row, its controls, and a rule closing it off.
    ///
    /// The rule moved out from under the title to the end of the section, where it is
    /// doing the job a rule is for: saying where one thing stops and the next starts.
    /// Under the title it was underlining a word that was not in any doubt, and the
    /// sections themselves were left to be told apart by a gap.
    ///
    /// The same air above and below the rule, so the line is a boundary between two
    /// blocks rather than a lid on the one above it. Which means the stack holding the
    /// sections must add nothing itself: a gap there lands entirely on one side.
    func inspectorSection(_ title: String,
                          systemImage: String,
                          @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                // Centred rather than baseline-aligned, because what sits at the end of
                // a heading is as often a control as a word.
                HStack(alignment: .center, spacing: 8) {
                    Text(title)
                        .font(.system(size: 12.5))
                        // Brighter than `.secondary`, which is where the control labels
                        // under it sit: with no weight left to separate a heading from
                        // the names below it, the only thing doing that job is how much
                        // white it is given.
                        .foregroundStyle(Color.primary.opacity(0.82))
                    Spacer(minLength: 4)
                    trailing()
                        .lineLimit(1)
                }
                self
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, SidebarSpacing.sectionPadding)

            StudioDivider(isSection: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A row of choices that always fits the panel.
///
/// Not `.pickerStyle(.segmented)`: a segmented control reports the sum of its titles as
/// the width it must have, and four of them ("Wallpaper Gradient Color Image") ask for
/// more than the settings column is wide. A fixed-width frame does not enforce anything,
/// so the panel simply drew wider than its column — clipped at both edges, and jumping
/// sideways every time a number in it grew a digit. These chips divide whatever width
/// they are given and shrink their text to suit.
struct InspectorTabs<Item: Identifiable & Hashable>: View {
    @Binding var selection: Item
    let items: [Item]
    let title: (Item) -> String

    @State private var hovered: Item?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(items) { item in
                let isSelected = item == selection
                Button { selection = item } label: {
                    Text(title(item))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        // White on the chosen one, secondary on the rest. The tint and
                        // the stroke already say which is chosen; the text only has to
                        // be the most readable thing in the row.
                        .foregroundStyle(isSelected
                                         ? AnyShapeStyle(.white)
                                         : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            // Every one of them is a button, so every one of them has a
                            // surface. The chosen one is the app's own blue at a
                            // fraction of it; the rest are a wash you can only just see,
                            // which is enough to say "these are four things you can
                            // press" without four slabs in a 300-point column.
                            //
                            // Squircle, not a capsule: the panel's rounded rectangles
                            // are all continuous-corner, and one pill in the middle of
                            // them would be a second shape language.
                            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                            shape
                                .fill(fill(isSelected: isSelected, isHovered: hovered == item))
                                // The chosen one is drawn as well as filled: a tint at
                                // eighteen percent is a soft edge against dark chrome,
                                // and the border is what makes it look chosen rather
                                // than merely lit.
                                .overlay {
                                    shape.strokeBorder(Color.accentColor.opacity(isSelected ? 0.55 : 0))
                                }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(BarButtonStyle())
                .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
                .accessibilityLabel(title(item))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .animation(StudioMotion.state, value: selection)
        .animation(StudioMotion.hover, value: hovered)
        .accessibilityElement(children: .contain)
    }

    private func fill(isSelected: Bool, isHovered: Bool) -> AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        }
        return AnyShapeStyle(Color.primary.opacity(isHovered ? 0.11 : 0.06))
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

/// A pop-up in the panel's own shape.
///
/// The system's is a blue-chevroned bezel with its own corner radius, drawn for a
/// settings window; next to the squircle tabs above it, it was the one control in the
/// column shaped like something else. This is the same surface as those tabs — the same
/// radius, the same wash, the same hover — with the system's menu behind it.
struct InspectorPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    @State private var isHovering = false

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(title(option), systemImage: "checkmark")
                    } else {
                        Text(title(option))
                    }
                }
            }
        } label: {
            // No chevron of our own: the menu style draws the system's, and two of them
            // in one control is how a hand-styled pop-up gives itself away. Sized to the
            // word it is showing rather than stretched across the row, because a pop-up
            // that fills the width reads as a text field.
            Text(title(selection))
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .fixedSize()
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Both the room and the surface go outside the menu. A menu style re-hosts its
        // label in a container of its own, and neither the padding nor a background set
        // in there survives the trip — which is why the fill was drawn tight around the
        // word however much padding the label asked for.
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.11 : 0.06))
        }
        .onHover { isHovering = $0 }
        .animation(StudioMotion.hover, value: isHovering)
        .accessibilityValue(Text(title(selection)))
    }
}

/// A name on the left, a control on the right, on the same column as the sliders.
///
/// The label is a `Text` of its own rather than a control's own label, because a
/// `Picker`'s built-in label sets a minimum width nobody can argue with.
struct InspectorField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 66, alignment: .leading)
            content
                .labelsHidden()
                // Against the right-hand edge, where the sliders put their readouts, so
                // the column has one edge down each side rather than a control floating
                // in the middle.
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// A name on the left, a fact on the right.
///
/// Not `LabeledContent`: that one refuses to give up its ideal width, so a pixel size
/// like "2,714 × 1,612" made the whole panel demand more room than its column has — and
/// a fixed-width frame does not clip, so the panel drew out over the tool rail on one
/// side and the picture on the other. This row shrinks instead.
struct InspectorRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }
}

/// A labelled slider that records one undo entry per drag.
///
/// Two lines: the name and its value on top, the track its own full width underneath.
/// Side by side, a 70-point name column and a 34-point number column left the track
/// about half the panel, which is half the precision — and the numbers only fitted by
/// hiding until you hovered. Given its own line the track is as long as the panel is
/// wide, and the value can simply always be there.
struct InspectorSlider: View {
    let model: EditorModel
    let title: String
    let systemImage: String?
    let value: Binding<Double>
    let range: ClosedRange<Double>
    /// How the number reads. The default is the value's share of the range, which is the
    /// only honest reading of a setting whose units are arbitrary.
    let format: (Double) -> String

    @State private var isHovering = false
    @State private var isDragging = false

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
            // second column of decoration for words that already say what they are, and
            // the section headings above them dropped theirs for the same reason. The
            // argument stays so the call sites keep describing themselves.
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(format(value.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(isHovering || isDragging ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
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
        .onHover { isHovering = $0 }
        .animation(StudioMotion.state, value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// One background choice in the grid.
struct SwatchTile<Content: View>: View {
    let isSelected: Bool
    let title: String
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
        .help(title)
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
