import SwiftUI

/// One choice in a `StudioMenuPicker`.
struct StudioMenuItem<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var systemImage: String?
    /// A picture in place of a glyph — a font's sample, a wallpaper — for the menus where
    /// seeing the choice beats reading its name.
    var thumbnail: AnyView?
    var isEnabled = true

    var id: Value { value }

    init(_ value: Value,
         title: String,
         systemImage: String? = nil,
         thumbnail: AnyView? = nil,
         isEnabled: Bool = true) {
        self.value = value
        self.title = title
        self.systemImage = systemImage
        self.thumbnail = thumbnail
        self.isEnabled = isEnabled
    }
}

/// A group of choices under an optional heading.
struct StudioMenuSection<Value: Hashable> {
    var title: String?
    let items: [StudioMenuItem<Value>]

    init(_ title: String? = nil, items: [StudioMenuItem<Value>]) {
        self.title = title
        self.items = items
    }
}

/// A pop-up: a squircle field showing the current choice, opening a list of the others.
///
/// The system pop-up is a bezelled button with a blue double-chevron cap and opens a
/// full-width system menu, both of which belong to a settings window rather than to a
/// panel of flat controls. This is a field in the kit's own fill and edge with a quiet
/// chevron, opening the kit's own list: a check on the current choice, a soft highlight
/// under the pointer, and the keyboard — up, down, Return to choose, Escape to leave.
///
/// The field is as wide as its *longest* choice, not its current one, so choosing a short
/// name does not pull the row's edge in and out under the pointer.
struct StudioMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let sections: [StudioMenuSection<Value>]
    var size: StudioTheme.ControlSize = .small
    /// Stretches the field across the width it is offered.
    var fillsWidth = false

    @State private var isPresented = false

    init(selection: Binding<Value>,
         sections: [StudioMenuSection<Value>],
         size: StudioTheme.ControlSize = .small,
         fillsWidth: Bool = false) {
        _selection = selection
        self.sections = sections
        self.size = size
        self.fillsWidth = fillsWidth
    }

    /// The common case: one list of values, named by a closure.
    init(selection: Binding<Value>,
         options: [Value],
         title: @escaping (Value) -> String,
         systemImage: ((Value) -> String?)? = nil,
         size: StudioTheme.ControlSize = .small,
         fillsWidth: Bool = false) {
        self.init(selection: selection,
                  sections: [StudioMenuSection(items: options.map {
                      StudioMenuItem($0, title: title($0), systemImage: systemImage?($0))
                  })],
                  size: size,
                  fillsWidth: fillsWidth)
    }

    private var allItems: [StudioMenuItem<Value>] { sections.flatMap(\.items) }
    private var current: StudioMenuItem<Value>? { allItems.first { $0.value == selection } }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 6) {
                if let symbol = current?.systemImage {
                    Image(systemName: symbol)
                        .font(.system(size: size.iconSize - 1))
                        .foregroundStyle(StudioTheme.Palette.textSecondary)
                }
                // Every title laid out and all but the current one hidden: the field takes
                // the width of the longest, and keeps it.
                ZStack(alignment: .leading) {
                    ForEach(allItems) { item in
                        Text(item.title)
                            .opacity(item.value == selection ? 1 : 0)
                            .accessibilityHidden(item.value != selection)
                    }
                }
                .font(.system(size: size.fontSize))
                .foregroundStyle(StudioTheme.Palette.textPrimary)
                if fillsWidth { Spacer(minLength: 0) }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(StudioTheme.Palette.textSecondary)
            }
        }
        .buttonStyle(StudioButtonStyle(variant: .secondary, size: size, fillsWidth: fillsWidth))
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            StudioMenuList(sections: sections.map { section in
                StudioMenuList.Section(title: section.title, rows: section.items.map { item in
                    StudioMenuList.Row(title: item.title,
                                       systemImage: item.systemImage,
                                       thumbnail: item.thumbnail,
                                       isChecked: item.value == selection,
                                       isEnabled: item.isEnabled) {
                        selection = item.value
                    }
                })
            }, showsChecks: true)
        }
        .accessibilityValue(Text(current?.title ?? ""))
        .accessibilityHint("Shows a list of choices")
    }
}

/// A button that opens a list of actions — Add Zoom, Auto-Zoom — rather than choices.
/// The same list as the picker's, without the checkmarks.
struct StudioActionMenu<Label: View>: View {
    struct Action {
        let title: String
        var systemImage: String?
        var isEnabled = true
        let perform: () -> Void

        init(_ title: String, systemImage: String? = nil, isEnabled: Bool = true, perform: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.isEnabled = isEnabled
            self.perform = perform
        }
    }

    let actions: [Action]
    var style: StudioButtonStyle
    @ViewBuilder let label: Label

    @State private var isPresented = false

    init(actions: [Action], style: StudioButtonStyle = .studio(.ghost), @ViewBuilder label: () -> Label) {
        self.actions = actions
        self.style = style
        self.label = label()
    }

    var body: some View {
        Button { isPresented.toggle() } label: { label }
            .buttonStyle(style)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                StudioMenuList(sections: [
                    .init(title: nil, rows: actions.map { action in
                        .init(title: action.title, systemImage: action.systemImage, thumbnail: nil,
                              isChecked: false, isEnabled: action.isEnabled, action: action.perform)
                    })
                ], showsChecks: false)
            }
    }
}

/// The list inside a picker's or an action menu's popover.
///
/// Rows are flattened to one run of indices so the keyboard moves through them in order
/// across sections, skipping the ones that cannot be chosen.
struct StudioMenuList: View {
    struct Row {
        let title: String
        let systemImage: String?
        let thumbnail: AnyView?
        let isChecked: Bool
        let isEnabled: Bool
        let action: () -> Void
    }

    struct Section {
        let title: String?
        let rows: [Row]
    }

    let sections: [Section]
    let showsChecks: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var highlighted: Int?
    @FocusState private var isFocused: Bool

    private var rows: [Row] { sections.flatMap(\.rows) }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(sections.indices, id: \.self) { sectionIndex in
                        let section = sections[sectionIndex]
                        if sectionIndex > 0 {
                            Rectangle()
                                .fill(StudioTheme.Palette.stroke)
                                .frame(height: 1)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                        }
                        if let title = section.title {
                            Text(title)
                                .font(.system(size: StudioTheme.FontSize.caption, weight: .medium))
                                .foregroundStyle(StudioTheme.Palette.textTertiary)
                                .padding(.horizontal, 8)
                                .padding(.top, 4)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.rows.indices, id: \.self) { rowIndex in
                            let index = flatIndex(section: sectionIndex, row: rowIndex)
                            row(section.rows[rowIndex], index: index)
                                .id(index)
                        }
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.automatic)
            .frame(minWidth: 168, maxHeight: 380)
            .fixedSize(horizontal: true, vertical: true)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, scroller); return .handled }
            .onKeyPress(.upArrow) { move(-1, scroller); return .handled }
            .onKeyPress(.return) {
                guard let highlighted, rows.indices.contains(highlighted) else { return .ignored }
                choose(rows[highlighted])
                return .handled
            }
            .onKeyPress(.escape) { dismiss(); return .handled }
            .onAppear {
                // Opens on the current choice, so Return straight away keeps it and an
                // arrow moves from where you already are.
                highlighted = rows.firstIndex(where: \.isChecked)
                if let highlighted { scroller.scrollTo(highlighted, anchor: .center) }
                isFocused = true
            }
        }
    }

    private func row(_ row: Row, index: Int) -> some View {
        let shape = StudioTheme.squircle(StudioTheme.Radius.inner)
        let isHighlighted = highlighted == index && row.isEnabled

        return Button { choose(row) } label: {
            HStack(spacing: 8) {
                if showsChecks {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StudioTheme.Palette.accent)
                        .opacity(row.isChecked ? 1 : 0)
                        .frame(width: 12)
                }
                if let thumbnail = row.thumbnail {
                    thumbnail
                        .frame(width: 28, height: 18)
                        .clipShape(StudioTheme.squircle(4))
                } else if let symbol = row.systemImage {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.Palette.textSecondary)
                        .frame(width: 16)
                }
                Text(row.title)
                    .font(.system(size: StudioTheme.FontSize.label))
                    .foregroundStyle(StudioTheme.Palette.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 8)
            .frame(height: row.thumbnail == nil ? 24 : 28)
            .background { shape.fill(isHighlighted ? StudioTheme.Palette.menuHover : .clear) }
            .contentShape(shape)
        }
        .buttonStyle(StudioPressStyle())
        .disabled(!row.isEnabled)
        .opacity(row.isEnabled ? 1 : 0.4)
        .onHover { inside in
            if inside { highlighted = index } else if highlighted == index { highlighted = nil }
        }
        .accessibilityAddTraits(row.isChecked ? [.isSelected] : [])
    }

    private func flatIndex(section: Int, row: Int) -> Int {
        sections.prefix(section).reduce(0) { $0 + $1.rows.count } + row
    }

    private func move(_ direction: Int, _ scroller: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        var next = highlighted ?? (direction > 0 ? -1 : rows.count)
        repeat {
            next += direction
        } while rows.indices.contains(next) && !rows[next].isEnabled
        guard rows.indices.contains(next) else { return }
        highlighted = next
        scroller.scrollTo(next)
    }

    private func choose(_ row: Row) {
        guard row.isEnabled else { return }
        row.action()
        dismiss()
    }
}
