import SwiftUI
import TimelineKit

/// A row of choices in one trough, the chosen one lifted out of it.
///
/// The highlight is one shape that slides from segment to segment rather than a fill that
/// blinks off one and on the next, so the eye follows the change instead of hunting for it.
///
/// Every segment is the width of the widest, so the row reads as one control rather than
/// a run of words; and when that is wider than the column, it breaks onto two lines, then
/// three — never shrinking or cutting a title. A single row of six ("Wallpaper Gradient
/// Color Image Motion None") is wider than the panel, and the system control's answer —
/// squeeze each title until it fits — left "Color" in larger type than "Motion" beside it
/// and still cut "Wallp…" short. How many go on a line is `SegmentGrid`, in TimelineKit.
struct StudioSegmented<Item: Hashable>: View {
    @Binding var selection: Item
    let items: [Item]
    let title: (Item) -> String
    var systemImage: ((Item) -> String?)?
    /// A tooltip for each segment, for a row whose one-word titles need a sentence to say
    /// what choosing them does — the preview's Framing and Result.
    var help: ((Item) -> String?)?
    /// Off for a row of glyphs — the four corners — where the title is said by the
    /// tooltip and to VoiceOver instead of being written in the segment.
    var showsTitles = true

    init(selection: Binding<Item>,
         items: [Item],
         title: @escaping (Item) -> String,
         systemImage: ((Item) -> String?)? = nil,
         help: ((Item) -> String?)? = nil,
         showsTitles: Bool = true) {
        _selection = selection
        self.items = items
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.showsTitles = showsTitles
    }

    @Namespace private var highlight
    @State private var hovered: Item?
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    private static var inset: CGFloat { 2 }
    private static var segmentHeight: CGFloat { StudioTheme.Height.small - 2 }

    var body: some View {
        let shape = StudioTheme.squircle(StudioTheme.Radius.inner + Self.inset)

        EqualWidthRows(spacing: Self.inset) {
            ForEach(items, id: \.self) { item in
                segment(item)
            }
        }
        .padding(Self.inset)
        .background { shape.fill(StudioTheme.Palette.fill) }
        .studioFocusRing(isFocused, radius: StudioTheme.Radius.inner + Self.inset)
        .opacity(isEnabled ? 1 : 0.45)
        .focusable(isEnabled, interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard let index = items.firstIndex(of: selection) else { return .ignored }
            let next = press.key == .leftArrow ? index - 1 : index + 1
            guard items.indices.contains(next) else { return .handled }
            selection = items[next]
            return .handled
        }
        .animation(StudioMotion.selection, value: selection)
        .animation(StudioMotion.hover, value: hovered)
        .accessibilityElement(children: .contain)
    }

    private func segment(_ item: Item) -> some View {
        let isSelected = item == selection
        let shape = StudioTheme.squircle(StudioTheme.Radius.inner)

        return Button { selection = item } label: {
            HStack(spacing: 5) {
                if let symbol = systemImage?(item) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                if showsTitles {
                    Text(title(item))
                        .font(.system(size: StudioTheme.FontSize.label, weight: isSelected ? .medium : .regular))
                }
            }
            .lineLimit(1)
            // Its whole width, always: this is what makes the row break onto two lines
            // rather than squeeze its titles.
            .fixedSize()
            .foregroundStyle(isSelected ? StudioTheme.Palette.textPrimary : StudioTheme.Palette.textSecondary)
            .padding(.horizontal, showsTitles ? 10 : 8)
            .frame(maxWidth: .infinity)
            .frame(height: Self.segmentHeight)
            .background {
                if isSelected {
                    shape
                        .fill(StudioTheme.Palette.raised)
                        .overlay { shape.strokeBorder(StudioTheme.Palette.stroke) }
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                } else if hovered == item {
                    shape.fill(StudioTheme.Palette.ghostHover)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(StudioPressStyle())
        .onHover { inside in
            hovered = inside ? item : (hovered == item ? nil : hovered)
        }
        // The segment's own sentence if it has one; otherwise its title where the title is
        // not written. Nothing at all otherwise: an empty tooltip here would hide the one
        // the row around the control gives.
        .segmentHelp(help?(item) ?? (showsTitles ? nil : title(item)))
        .accessibilityLabel(title(item))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Lays its children out as equal-width cells, on as few balanced lines as fit.
///
/// Each child is measured at its ideal width; the widest decides the cell, `SegmentGrid`
/// decides how many cells to a line, and the cells then share the width they are given so
/// the row runs edge to edge.
struct EqualWidthRows: Layout {
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let grid = arrange(subviews, width: proposal.width)
        return CGSize(width: grid.width, height: grid.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = arrange(subviews, width: bounds.width)
        for index in subviews.indices {
            let line = index / grid.perRow
            let column = index % grid.perRow
            let origin = CGPoint(x: bounds.minX + CGFloat(column) * (grid.cell + spacing),
                                 y: bounds.minY + CGFloat(line) * (grid.rowHeight + spacing))
            subviews[index].place(at: origin, anchor: .topLeading,
                                  proposal: ProposedViewSize(width: grid.cell, height: grid.rowHeight))
        }
    }

    private struct Grid {
        var perRow: Int
        var cell: CGFloat
        var rowHeight: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> Grid {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widest = sizes.map(\.width).max() ?? 0
        let rowHeight = sizes.map(\.height).max() ?? 0
        let count = max(1, subviews.count)
        let natural = CGFloat(count) * widest + CGFloat(count - 1) * spacing
        // An unbounded offer — a horizontal scroll view, an ideal-size query — is answered
        // with the row at its natural width rather than cells of infinite width.
        let available = width.flatMap { $0.isFinite ? $0 : nil } ?? natural
        let perRow = SegmentGrid.perRow(count: count, widest: widest, available: available, spacing: spacing)
        let lines = Int((Double(count) / Double(perRow)).rounded(.up))
        let cell = max(0, (available - CGFloat(perRow - 1) * spacing) / CGFloat(perRow))
        return Grid(perRow: perRow,
                    cell: cell,
                    rowHeight: rowHeight,
                    width: available,
                    height: CGFloat(lines) * rowHeight + CGFloat(max(0, lines - 1)) * spacing)
    }
}

private extension View {
    /// A tooltip when there is one to give, and no `.help` at all when there is not.
    @ViewBuilder
    func segmentHelp(_ text: String?) -> some View {
        if let text {
            help(text)
        } else {
            self
        }
    }
}
