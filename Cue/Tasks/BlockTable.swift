import AppKit
import SwiftUI

/// A table as Notion draws one: hairline cells, a tinted header row (and, when asked,
/// header column), inline Markdown shown as what it means, colours on cells, rows and
/// columns. Under the pointer a thin line marks the column (above it) and the row
/// (left of it); over the line it becomes the dot grip, and a click opens what can be
/// done to the column or row. Column and row edges drag to resize. Outlined + bars at
/// the right and the foot add a column or a row. A click edits a cell — outlined in
/// blue, with a handle on its right edge for its own menu; ⇥ / ⇧⇥ move along, ↩ down.
struct TableBlockView: View {
    let id: UUID
    let table: DocTable
    let model: BlockEditorModel

    struct Cell: Hashable {
        var row: Int
        var column: Int
    }

    enum OpenMenu: Equatable {
        case row(Int), column(Int), cell(Cell)
    }

    @State private var editing: Cell?
    @State private var draft = ""
    @FocusState private var focus: Cell?
    @State private var hovered: Cell?
    @State private var hoveringTable = false
    @State private var openMenu: OpenMenu?
    /// Sizes while an edge is being dragged, before they are saved.
    @State private var liveWidths: [Int: CGFloat] = [:]
    @State private var liveHeights: [Int: CGFloat] = [:]
    @State private var dragStart: CGFloat?
    /// Each row's drawn height, for the row outline and resizing.
    @State private var measuredHeights: [Int: CGFloat] = [:]
    @State private var available: CGFloat = 600

    /// Room at the left and top, inside the scroll area, for the row and column handles.
    private static let pad: CGFloat = 14
    fileprivate static let minimumWidth: CGFloat = 80
    private static let minimumHeight: CGFloat = 36
    static let headerFill = NotionStyle.dynamic(light: NotionStyle.rgb(247, 246, 243), dark: NotionStyle.rgb(37, 37, 37))

    private var padded: DocTable { table.padded }

    /// The room the table has: the column, less the handles' margin, the + bar beside
    /// it and the scroll area's own edges.
    private var space: CGFloat { max(available - Self.pad - 24 - 6, Self.minimumWidth) }

    /// Every column's width and where each begins, worked out once per drawing and
    /// handed to the cells, the grips and the outline (rather than each cell working
    /// all of it out again, which grows with rows × columns²).
    struct ColumnLayout {
        let widths: [CGFloat]
        /// Each column's leading edge; the last entry is the table's width.
        let edges: [CGFloat]

        var total: CGFloat { edges.last ?? 0 }
        func width(_ column: Int) -> CGFloat { widths.indices.contains(column) ? widths[column] : TableBlockView.minimumWidth }
        func edge(_ column: Int) -> CGFloat { edges[min(max(column, 0), edges.count - 1)] }
    }

    /// One dragged to keeps its width; the others share what room is left by how much
    /// text they hold (their longest cell, within bounds), filling the table to the
    /// page. If they still do not fit, all come in together — never under the least a
    /// column may be — so the table's right edge always shows. A column being dragged
    /// follows the drag.
    private func columnLayout(for table: DocTable) -> ColumnLayout {
        let count = table.columnCount
        guard count > 0 else { return ColumnLayout(widths: [], edges: [0]) }
        // One pass over the cells: each column's longest text and longest word, counted
        // without Markdown's marks (an estimate, not a measure — cheap enough to redo on
        // every drawing).
        var longest = Array(repeating: 0, count: count)
        var longestWord = Array(repeating: 0, count: count)
        for row in table.rows {
            for (column, text) in row.enumerated() where column < count {
                var length = 0, word = 0, widest = 0
                for character in text where !"*_`~".contains(character) {
                    length += 1
                    if character.isWhitespace { word = 0 } else { word += 1; widest = max(widest, word) }
                }
                longest[column] = max(longest[column], length)
                longestWord[column] = max(longestWord[column], widest)
            }
        }
        let weights = longest.map { CGFloat(min(max($0, 6), 48)) }
        // A column is never narrower than its longest word (in the header's bolder type),
        // so words wrap between, never inside, themselves.
        let floors = longestWord.map { min(max(CGFloat($0) * 8.6 + 22, Self.minimumWidth), 280) }
        let set = (0..<count).map { liveWidths[$0] ?? table.width(of: $0).map { CGFloat($0) } }
        let taken = set.compactMap { $0 }.reduce(0, +)
        let free = (0..<count).filter { set[$0] == nil }
        let totalWeight = free.map { weights[$0] }.reduce(0, +)
        let left = max(space - taken, free.map { floors[$0] }.reduce(0, +))
        var widths = (0..<count).map { column in
            set[column] ?? max(left * weights[column] / max(totalWeight, 1), floors[column])
        }
        // Floors raised some columns past their share: the others give the room back.
        let over = free.map { widths[$0] }.reduce(0, +) - left
        if over > 0 {
            let slack = free.map { widths[$0] - floors[$0] }.reduce(0, +)
            if slack > 0 {
                for column in free {
                    widths[column] -= min(over, slack) * (widths[column] - floors[column]) / slack
                }
            }
        }
        let total = widths.reduce(0, +)
        if total > space {
            widths = widths.enumerated().map { column, width in
                liveWidths[column] != nil ? width : max(width * space / total, Self.minimumWidth)
            }
        }
        var edges = [CGFloat(0)]
        for width in widths { edges.append(edges[edges.count - 1] + width) }
        return ColumnLayout(widths: widths, edges: edges)
    }

    #if DEBUG
    /// A state to open tables in, for `cue://debug/table` to show what is otherwise
    /// only seen under the pointer.
    static var debugState: (hovered: Cell?, menu: OpenMenu?, editing: Cell?)?
    #endif

    var body: some View {
        let table = padded
        let layout = columnLayout(for: table)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                ScrollView(.horizontal) {
                    grid(table, layout)
                        .padding(.leading, Self.pad)
                        .padding(.top, Self.pad)
                        .padding([.trailing, .bottom], 2)
                }
                .thinScrollers()
                .frame(maxWidth: layout.total + Self.pad + 4, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                addBar(vertical: true) { model.updateTable(id) { $0.insertColumn(at: $0.columnCount) } }
                    .padding(.top, Self.pad)
                    .padding(.bottom, 2)
            }
            .fixedSize(horizontal: false, vertical: true)
            addBar(vertical: false) { model.updateTable(id) { $0.insertRow(at: $0.rows.count) } }
                .frame(width: max(min(layout.total, available - Self.pad - 24), 60))
                .padding(.leading, Self.pad)
        }
        .padding(.leading, -Self.pad)
        .padding(.top, -Self.pad)
        // As wide as the page column, whatever the table's own width — the room it is
        // measured in must not be the table itself, or it can never grow.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { available = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, value in available = value }
            }
        }
        .onHover { over in
            hoveringTable = over
            if !over, openMenu == nil { hovered = nil }
        }
        #if DEBUG
        .onAppear {
            guard let state = Self.debugState else { return }
            hovered = state.hovered
            hoveringTable = state.hovered != nil
            if let cell = state.editing { startEditing(cell, in: padded) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { openMenu = state.menu }
        }
        #endif
        .onChange(of: focus) { _, value in
            // Left the cell (a click elsewhere, ⎋): what was typed is kept.
            if value == nil, editing != nil, openMenu == nil { commit(); editing = nil }
        }
    }

    // MARK: Grid

    private func grid(_ table: DocTable, _ layout: ColumnLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(table.rows.indices, id: \.self) { row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(Cell(row: row, column: column), in: table, width: layout.width(column))
                    }
                }
                .frame(minHeight: liveHeights[row] ?? table.height(of: row).map { CGFloat($0) } ?? Self.minimumHeight, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { measuredHeights[row] = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, value in measuredHeights[row] = value }
                    }
                }
                .overlay(alignment: .leading) {
                    if editing == nil, hovered?.row == row || openMenu == .row(row) {
                        // Centred on the table's left border, as Notion's is.
                        rowHandle(row, in: table).offset(x: -TableHandle.thickness / 2)
                    }
                }
                .overlay(alignment: .bottom) { rowResizer(row) }
            }
        }
        .overlay(Rectangle().strokeBorder(NotionStyle.divider, lineWidth: 1).allowsHitTesting(false))
        .overlay(alignment: .topLeading) { columnResizers(table, layout) }
        .overlay(alignment: .topLeading) { selectionOutline(table, layout) }
    }

    private func cell(_ cell: Cell, in table: DocTable, width: CGFloat) -> some View {
        let header = (table.headerRow && cell.row == 0) || (table.headerColumn && cell.column == 0)
        let text = table.rows[cell.row][cell.column]
        let font = Font.system(size: 14, weight: header ? .semibold : .regular)
        let color = table.color(row: cell.row, column: cell.column).flatMap(NotionColor.init(rawValue:))
        return Group {
            if editing == cell {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(font)
                    .focused($focus, equals: cell)
                    .onSubmit { move(from: cell, rows: 1, columns: 0, in: table) }
                    .onKeyPress(.tab, phases: .down) { press in
                        move(from: cell, rows: 0, columns: press.modifiers.contains(.shift) ? -1 : 1, in: table)
                        return .handled
                    }
                    .onExitCommand { openMenu = nil; focus = nil }
            } else {
                Text(Self.inline(text))
                    .font(font)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(color?.background.opacity(0.8) ?? (header ? Self.headerFill : .clear))
        .overlay(alignment: .trailing) { Hairline(axis: .vertical) }
        .overlay(alignment: .bottom) { Hairline() }
        .overlay {
            if editing == cell {
                Rectangle().strokeBorder(NotionStyle.accent, lineWidth: 2).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if editing == cell {
                TableHandle(kind: .cell, active: openMenu == .cell(cell)) { openMenu = .cell(cell) }
                    .offset(x: 7)
                    .popover(isPresented: menuBinding(.cell(cell)), arrowEdge: .trailing) { cellMenu(cell, in: table) }
            }
        }
        .overlay(alignment: .top) {
            if cell.row == 0, editing == nil, hovered?.column == cell.column || openMenu == .column(cell.column) {
                // Centred on the table's top border.
                columnHandle(cell.column, in: table).offset(y: -TableHandle.thickness / 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { startEditing(cell, in: table) }
        .onHover { if $0, openMenu == nil { hovered = cell } }
    }

    /// A cell's inline Markdown as styled text; what will not parse shows as typed.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// The column or row whose menu is open, outlined in blue.
    @ViewBuilder
    private func selectionOutline(_ table: DocTable, _ layout: ColumnLayout) -> some View {
        switch openMenu {
        case .column(let column):
            Rectangle()
                .strokeBorder(NotionStyle.accent, lineWidth: 2)
                .frame(width: layout.width(column))
                .frame(maxHeight: .infinity)
                .offset(x: layout.edge(column))
                .allowsHitTesting(false)
        case .row(let row):
            Rectangle()
                .strokeBorder(NotionStyle.accent, lineWidth: 2)
                .frame(width: layout.total, height: measuredHeights[row] ?? Self.minimumHeight)
                .offset(y: (0..<row).reduce(0) { $0 + (measuredHeights[$1] ?? Self.minimumHeight) })
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    // MARK: Resizing

    /// A grab band on each column's right edge, the table's whole height: a blue line
    /// under the pointer, dragged to set the column's width.
    private func columnResizers(_ table: DocTable, _ layout: ColumnLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<table.columnCount, id: \.self) { column in
                EdgeGrip(vertical: true)
                    .frame(width: 8)
                    .frame(maxHeight: .infinity)
                    .offset(x: layout.edge(column + 1) - 4)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStart ?? layout.width(column)
                                dragStart = start
                                liveWidths[column] = max(start + value.translation.width, Self.minimumWidth)
                            }
                            .onEnded { _ in
                                let final = liveWidths[column]
                                dragStart = nil
                                if let final { model.updateTable(id) { $0.setWidth(Double(final.rounded()), of: column) } }
                                liveWidths[column] = nil
                            }
                    )
            }
        }
    }

    /// A grab band along a row's foot, dragged to set how tall the row is at least.
    private func rowResizer(_ row: Int) -> some View {
        EdgeGrip(vertical: false)
            .frame(height: 8)
            .offset(y: 4)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? measuredHeights[row] ?? Self.minimumHeight
                        dragStart = start
                        liveHeights[row] = max(start + value.translation.height, Self.minimumHeight)
                    }
                    .onEnded { _ in
                        let final = liveHeights[row]
                        dragStart = nil
                        if let final { model.updateTable(id) { $0.setHeight(Double(final.rounded()), of: row) } }
                        liveHeights[row] = nil
                    }
            )
    }

    // MARK: Editing

    private func startEditing(_ cell: Cell, in table: DocTable) {
        if editing != nil { commit() }
        openMenu = nil
        draft = table.rows[cell.row][cell.column]
        editing = cell
        DispatchQueue.main.async { focus = cell }
    }

    private func commit() {
        guard let editing else { return }
        let value = draft.replacingOccurrences(of: "\n", with: " ")
        guard padded.rows.indices.contains(editing.row), editing.column < padded.columnCount,
              padded.rows[editing.row][editing.column] != value else { return }
        model.updateTable(id) { table in
            table = table.padded
            table.rows[editing.row][editing.column] = value
        }
    }

    /// ⇥ along the row (and on to the next), ↩ down the column — past the last row, a new one.
    private func move(from cell: Cell, rows: Int, columns: Int, in table: DocTable) {
        commit()
        var next = Cell(row: cell.row + rows, column: cell.column + columns)
        if next.column >= table.columnCount { next = Cell(row: next.row + 1, column: 0) }
        if next.column < 0 { next = Cell(row: next.row - 1, column: table.columnCount - 1) }
        guard next.row >= 0 else { focus = nil; return }
        if next.row >= table.rows.count {
            model.updateTable(id) { $0.insertRow(at: $0.rows.count) }
        }
        let updated = padded
        guard updated.rows.indices.contains(next.row) else { focus = nil; return }
        editing = nil
        startEditing(next, in: updated)
    }

    // MARK: Handles and menus

    private func menuBinding(_ menu: OpenMenu) -> Binding<Bool> {
        Binding(get: { openMenu == menu }, set: { open in
            if open { openMenu = menu } else if openMenu == menu { openMenu = nil }
        })
    }

    private func rowHandle(_ row: Int, in table: DocTable) -> some View {
        TableHandle(kind: .row, active: openMenu == .row(row)) { openMenu = .row(row) }
            .popover(isPresented: menuBinding(.row(row)), arrowEdge: .leading) {
                TableActionsMenu(
                    toggle: row == 0 ? ("Header row", "rectangle.topthird.inset.filled", table.headerRow, { on in model.updateTable(id) { $0.headerRow = on } }) : nil,
                    color: table.colors["r\(row)"],
                    pickColor: { color in model.updateTable(id) { $0.setColor(color, row: row) } },
                    actions: [
                        .init(title: "Insert above", symbol: "arrow.up") { model.updateTable(id) { $0.insertRow(at: row) } },
                        .init(title: "Insert below", symbol: "arrow.down") { model.updateTable(id) { $0.insertRow(at: row + 1) } },
                        .init(title: "Duplicate", symbol: "plus.square.on.square") { model.updateTable(id) { $0.duplicateRow(row) } },
                        .init(title: "Clear contents", symbol: "xmark.circle") { model.updateTable(id) { $0.clearRow(row) } },
                        .init(title: "Delete", symbol: "trash", destructive: true, enabled: table.rows.count > 1) { model.updateTable(id) { $0.deleteRow(row) } },
                    ],
                    close: { openMenu = nil })
            }
    }

    private func columnHandle(_ column: Int, in table: DocTable) -> some View {
        TableHandle(kind: .column, active: openMenu == .column(column)) { openMenu = .column(column) }
            .popover(isPresented: menuBinding(.column(column)), arrowEdge: .top) {
                TableActionsMenu(
                    toggle: ("Header column", "rectangle.leadingthird.inset.filled", table.headerColumn, { on in model.updateTable(id) { $0.headerColumn = on } }),
                    color: table.colors["c\(column)"],
                    pickColor: { color in model.updateTable(id) { $0.setColor(color, column: column) } },
                    actions: [
                        .init(title: "Insert left", symbol: "arrow.left") { model.updateTable(id) { $0.insertColumn(at: column) } },
                        .init(title: "Insert right", symbol: "arrow.right") { model.updateTable(id) { $0.insertColumn(at: column + 1) } },
                        .init(title: "Duplicate", symbol: "plus.square.on.square") { model.updateTable(id) { $0.duplicateColumn(column) } },
                        .init(title: "Clear contents", symbol: "xmark.circle") { model.updateTable(id) { $0.clearColumn(column) } },
                        .init(title: "Delete", symbol: "trash", destructive: true, enabled: table.columnCount > 1) { model.updateTable(id) { $0.deleteColumn(column) } },
                    ],
                    close: { openMenu = nil })
            }
    }

    private func cellMenu(_ cell: Cell, in table: DocTable) -> some View {
        TableActionsMenu(
            toggle: nil,
            color: table.colors["\(cell.row).\(cell.column)"],
            pickColor: { color in model.updateTable(id) { $0.setColor(color, row: cell.row, column: cell.column) } },
            actions: [
                .init(title: "Clear contents", symbol: "xmark.circle") {
                    draft = ""
                    model.updateTable(id) { table in
                        table = table.padded
                        table.rows[cell.row][cell.column] = ""
                    }
                },
            ],
            searchable: false,
            close: { openMenu = nil })
    }

    /// The outlined + bar along the right or the foot, shown while the pointer is over the table.
    private func addBar(vertical: Bool, action: @escaping () -> Void) -> some View {
        AddBar(vertical: vertical, action: action)
            .frame(width: vertical ? 18 : nil, height: vertical ? nil : 18)
            .frame(maxHeight: vertical ? .infinity : nil)
            .opacity(hoveringTable && editing == nil ? 1 : 0)
    }
}

// MARK: - Pieces

/// A column's, row's or cell's handle: a thin line until the pointer is on it, then
/// the grip (for a cell, a ⋮) — blue while its menu is open.
struct TableHandle: View {
    enum Kind { case row, column, cell }

    let kind: Kind
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    /// The handle's depth across the border it sits on (its width for a row's, its
    /// height for a column's): half of it each side of the line.
    static let thickness: CGFloat = 16

    var body: some View {
        Button(action: action) {
            ZStack {
                if hovering || active {
                    button
                } else {
                    Capsule()
                        .fill(kind == .cell ? NotionStyle.accent : NotionStyle.tertiary)
                        .frame(width: kind == .column ? 18 : 3, height: kind == .column ? 3 : 16)
                }
            }
            .frame(width: kind == .column ? 34 : Self.thickness, height: kind == .column ? Self.thickness : 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(kind == .cell ? "Cell options" : kind == .row ? "Row options" : "Column options")
        .animation(.easeOut(duration: 0.1), value: hovering)
    }

    @ViewBuilder
    private var button: some View {
        if kind == .cell {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 22)
                .background(NotionStyle.accent, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            DragDots(horizontal: kind == .column, color: active ? .white : NotionStyle.secondary)
                .frame(width: kind == .column ? 26 : 14, height: kind == .column ? 14 : 26)
                .background(active ? NotionStyle.accent : NotionStyle.card, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(active ? .clear : NotionStyle.divider))
                .shadow(color: .black.opacity(active ? 0 : 0.06), radius: 1, y: 1)
        }
    }
}

/// A band along an edge that resizes: invisible until the pointer is on it, then a
/// blue line, with the matching cursor.
private struct EdgeGrip: View {
    let vertical: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            if hovering {
                Rectangle()
                    .fill(NotionStyle.accent.opacity(0.7))
                    .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { over in
            hovering = over
            if over { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
    }
}

/// Notion's add bar: an outlined, rounded strip with a + in the middle.
private struct AddBar: View {
    let vertical: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hovering ? NotionStyle.hover : .clear)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(NotionStyle.divider))
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(NotionStyle.tertiary)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(vertical ? "Add a column" : "Add a row")
    }
}

/// The menu a table handle opens, after Notion's: a search over the actions, a
/// header switch, Color (a list of its own), then the actions.
private struct TableActionsMenu: View {
    struct Action: Identifiable {
        var id: String { title }
        let title: String
        let symbol: String
        var destructive = false
        var enabled = true
        let run: () -> Void
    }

    typealias Toggle = (title: String, symbol: String, isOn: Bool, set: (Bool) -> Void)

    let toggle: Toggle?
    let color: String?
    let pickColor: (String?) -> Void
    let actions: [Action]
    var searchable = true
    let close: () -> Void

    @State private var query = ""
    @State private var choosingColor = false
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if choosingColor {
                colorList
            } else {
                if searchable {
                    TextField("Search actions…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(NotionStyle.field, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(NotionStyle.accent.opacity(searching ? 0.7 : 0), lineWidth: 1.5))
                        .focused($searching)
                        .padding(.bottom, 4)
                }
                if let toggle, matches(toggle.title) {
                    HStack(spacing: 10) {
                        Image(systemName: toggle.symbol).font(.system(size: 13)).frame(width: 18).foregroundStyle(NotionStyle.secondary)
                        Text(toggle.title).font(.system(size: 14))
                        Spacer()
                        SwiftUI.Toggle("", isOn: Binding(get: { toggle.isOn }, set: { toggle.set($0) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                }
                if matches("Color") {
                    row("Color", symbol: "paintbrush", chevron: true) { choosingColor = true }
                }
                ForEach(actions.filter { matches($0.title) }) { action in
                    row(action.title, symbol: action.symbol, tint: action.destructive ? .red : NotionStyle.text) {
                        action.run()
                        close()
                    }
                    .disabled(!action.enabled)
                    .opacity(action.enabled ? 1 : 0.4)
                }
            }
        }
        .padding(6)
        .frame(width: 240)
        .foregroundStyle(NotionStyle.text)
    }

    private func matches(_ title: String) -> Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty || title.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespaces))
    }

    private var colorList: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                choosingColor = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Color").font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(NotionStyle.secondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            swatchRow(nil, title: "Default")
            ForEach(NotionColor.allCases, id: \.self) { swatchRow($0, title: $0.title) }
        }
    }

    private func swatchRow(_ swatch: NotionColor?, title: String) -> some View {
        Button {
            pickColor(swatch?.rawValue)
            close()
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(swatch?.background ?? NotionStyle.page)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(NotionStyle.divider))
                    .frame(width: 18, height: 18)
                Text(title).font(.system(size: 14))
                Spacer()
                if color == swatch?.rawValue {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(NotionStyle.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotionHoverStyle())
    }

    private func row(_ title: String, symbol: String, chevron: Bool = false, tint: Color = NotionStyle.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 18).foregroundStyle(tint == NotionStyle.text ? NotionStyle.secondary : tint)
                Text(title).font(.system(size: 14)).foregroundStyle(tint)
                Spacer()
                if chevron { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(NotionStyle.tertiary) }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotionHoverStyle())
    }
}
