import Foundation

// A task's description as Notion lays a page out: a column of blocks, each one
// thing — a line of text (a paragraph, a heading, a list item, a quote), a code
// block, a diagram, a table, a divider, an image or a file. What is stored is still
// Markdown; these turn it into blocks for the editor and back.

/// One block of a description.
nonisolated struct DocBlock: Identifiable, Equatable {
    let id: UUID
    var kind: Kind

    enum Kind: Equatable {
        /// One line of Markdown, its block mark included: `# Title`, `- item`,
        /// `- [ ] to do`, `1. step`, `> quote`, or a plain paragraph.
        case text(String)
        /// A fenced code block; `mermaid` draws a diagram.
        case code(language: String, code: String)
        case divider
        case image(alt: String, source: String)
        /// A line that is only a link to an attached file.
        case file(name: String, source: String)
        case table(DocTable)
    }

    init(id: UUID = UUID(), _ kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// The same block under a new identity (Duplicate).
    var copy: DocBlock { DocBlock(kind) }

    var isText: Bool {
        if case .text = kind { return true }
        return false
    }

    var text: String? {
        if case .text(let line) = kind { return line }
        return nil
    }
}

/// A pipe table: rows of cells (each inline Markdown), the first row the header
/// unless told otherwise — and what Markdown cannot say about it, kept in the
/// options comment above it: a header column, column widths, row heights, colours.
nonisolated struct DocTable: Equatable {
    var rows: [[String]]
    var headerRow = true
    var headerColumn = false
    /// Widths dragged to, by column (nil: the column takes its share).
    var columnWidths: [Double?] = []
    /// Least heights dragged to, by row (nil: as tall as its text).
    var rowHeights: [Double?] = []
    /// Background colours by name: a row `r2`, a column `c1`, a cell `2.1`.
    var colors: [String: String] = [:]

    init(rows: [[String]], headerRow: Bool = true, headerColumn: Bool = false) {
        self.rows = rows
        self.headerRow = headerRow
        self.headerColumn = headerColumn
    }

    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    /// A new table: a header row and two empty rows, three columns.
    static let empty = DocTable(rows: [["", "", ""], ["", "", ""], ["", "", ""]])

    /// Every row as wide as the widest.
    var padded: DocTable {
        var table = self
        let width = max(columnCount, 1)
        table.rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        if table.rows.isEmpty { table.rows = [Array(repeating: "", count: width)] }
        return table
    }

    // MARK: Sizes and colours

    func width(of column: Int) -> Double? { columnWidths.indices.contains(column) ? columnWidths[column] : nil }
    func height(of row: Int) -> Double? { rowHeights.indices.contains(row) ? rowHeights[row] : nil }

    mutating func setWidth(_ width: Double?, of column: Int) {
        guard column >= 0 else { return }
        while columnWidths.count <= column { columnWidths.append(nil) }
        columnWidths[column] = width
        while columnWidths.last == .some(nil) { columnWidths.removeLast() }
    }

    mutating func setHeight(_ height: Double?, of row: Int) {
        guard row >= 0 else { return }
        while rowHeights.count <= row { rowHeights.append(nil) }
        rowHeights[row] = height
        while rowHeights.last == .some(nil) { rowHeights.removeLast() }
    }

    /// The colour a cell shows: its own, else its row's, else its column's.
    func color(row: Int, column: Int) -> String? {
        colors["\(row).\(column)"] ?? colors["r\(row)"] ?? colors["c\(column)"]
    }

    mutating func setColor(_ color: String?, row: Int) { colors["r\(row)"] = color }
    mutating func setColor(_ color: String?, column: Int) { colors["c\(column)"] = color }
    mutating func setColor(_ color: String?, row: Int, column: Int) { colors["\(row).\(column)"] = color }

    /// Colours follow their rows and columns as others come and go: `shift` maps an old
    /// row (or column) index to its new one, nil when it is gone.
    private mutating func remapColors(rows shift: ((Int) -> Int?)? = nil, columns shiftColumn: ((Int) -> Int?)? = nil) {
        var moved: [String: String] = [:]
        for (key, value) in colors {
            if key.hasPrefix("r"), let row = Int(key.dropFirst()) {
                guard let new = shift.map({ $0(row) }) ?? row else { continue }
                moved["r\(new)"] = value
            } else if key.hasPrefix("c"), let column = Int(key.dropFirst()) {
                guard let new = shiftColumn.map({ $0(column) }) ?? column else { continue }
                moved["c\(new)"] = value
            } else {
                let parts = key.split(separator: ".").compactMap { Int($0) }
                guard parts.count == 2,
                      let row = shift.map({ $0(parts[0]) }) ?? parts[0],
                      let column = shiftColumn.map({ $0(parts[1]) }) ?? parts[1] else { continue }
                moved["\(row).\(column)"] = value
            }
        }
        colors = moved
    }

    // MARK: Rows

    mutating func insertRow(at index: Int) {
        self = padded
        let index = min(max(index, 0), rows.count)
        rows.insert(Array(repeating: "", count: columnCount), at: index)
        if rowHeights.count > index { rowHeights.insert(nil, at: index) }
        remapColors(rows: { $0 >= index ? $0 + 1 : $0 })
    }

    mutating func duplicateRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.insert(rows[index], at: index + 1)
        if rowHeights.count > index + 1 { rowHeights.insert(height(of: index), at: index + 1) } else if let height = height(of: index) { setHeight(height, of: index + 1) }
        let copied = colors.filter { $0.key == "r\(index)" || $0.key.hasPrefix("\(index).") }
        remapColors(rows: { $0 > index ? $0 + 1 : $0 })
        for (key, value) in copied {
            colors[key == "r\(index)" ? "r\(index + 1)" : "\(index + 1)." + key.split(separator: ".")[1]] = value
        }
    }

    mutating func clearRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index] = Array(repeating: "", count: rows[index].count)
    }

    /// The last row stays: a table has at least one.
    mutating func deleteRow(_ index: Int) {
        guard rows.count > 1, rows.indices.contains(index) else { return }
        rows.remove(at: index)
        if rowHeights.indices.contains(index) { rowHeights.remove(at: index) }
        while rowHeights.last == .some(nil) { rowHeights.removeLast() }
        remapColors(rows: { $0 == index ? nil : $0 > index ? $0 - 1 : $0 })
    }

    mutating func moveRow(_ from: Int, to: Int) {
        guard rows.indices.contains(from), from != to else { return }
        let to = min(max(to, 0), rows.count - 1)
        let row = rows.remove(at: from)
        rows.insert(row, at: to)
        var heights = (0..<rows.count).map { height(of: $0) }
        heights.insert(heights.remove(at: from), at: to)
        rowHeights = heights
        while rowHeights.last == .some(nil) { rowHeights.removeLast() }
        remapColors(rows: { old in
            if old == from { return to }
            if from < to, old > from, old <= to { return old - 1 }
            if to < from, old >= to, old < from { return old + 1 }
            return old
        })
    }

    // MARK: Columns

    mutating func insertColumn(at index: Int) {
        self = padded
        let index = min(max(index, 0), columnCount)
        for row in rows.indices { rows[row].insert("", at: index) }
        if columnWidths.count > index { columnWidths.insert(nil, at: index) }
        remapColors(columns: { $0 >= index ? $0 + 1 : $0 })
    }

    mutating func duplicateColumn(_ index: Int) {
        self = padded
        guard index < columnCount else { return }
        for row in rows.indices { rows[row].insert(rows[row][index], at: index + 1) }
        if columnWidths.count > index + 1 { columnWidths.insert(width(of: index), at: index + 1) } else if let width = width(of: index) { setWidth(width, of: index + 1) }
        let copied = colors.filter { $0.key == "c\(index)" || $0.key.hasSuffix(".\(index)") }
        remapColors(columns: { $0 > index ? $0 + 1 : $0 })
        for (key, value) in copied {
            colors[key == "c\(index)" ? "c\(index + 1)" : key.split(separator: ".")[0] + ".\(index + 1)"] = value
        }
    }

    mutating func clearColumn(_ index: Int) {
        self = padded
        guard index < columnCount else { return }
        for row in rows.indices { rows[row][index] = "" }
    }

    /// The last column stays.
    mutating func deleteColumn(_ index: Int) {
        self = padded
        guard columnCount > 1, index < columnCount else { return }
        for row in rows.indices { rows[row].remove(at: index) }
        if columnWidths.indices.contains(index) { columnWidths.remove(at: index) }
        while columnWidths.last == .some(nil) { columnWidths.removeLast() }
        remapColors(columns: { $0 == index ? nil : $0 > index ? $0 - 1 : $0 })
    }

    mutating func moveColumn(_ from: Int, to: Int) {
        self = padded
        guard from < columnCount, from != to else { return }
        let to = min(max(to, 0), columnCount - 1)
        for row in rows.indices {
            let cell = rows[row].remove(at: from)
            rows[row].insert(cell, at: to)
        }
        var widths = (0..<columnCount).map { width(of: $0) }
        widths.insert(widths.remove(at: from), at: to)
        columnWidths = widths
        while columnWidths.last == .some(nil) { columnWidths.removeLast() }
        remapColors(columns: { old in
            if old == from { return to }
            if from < to, old > from, old <= to { return old - 1 }
            if to < from, old >= to, old < from { return old + 1 }
            return old
        })
    }

    // MARK: Options

    /// Whether anything needs the options comment.
    var hasOptions: Bool { !headerRow || headerColumn || !columnWidths.isEmpty || !rowHeights.isEmpty || !colors.isEmpty }

    /// `header-column no-header-row widths=200,,180 heights=,60 colors=r1:yellow;c0:blue;2.1:red`
    var options: String {
        var parts: [String] = []
        if headerColumn { parts.append("header-column") }
        if !headerRow { parts.append("no-header-row") }
        func list(_ values: [Double?]) -> String { values.map { $0.map { String(Int($0.rounded())) } ?? "" }.joined(separator: ",") }
        if !columnWidths.isEmpty { parts.append("widths=" + list(columnWidths)) }
        if !rowHeights.isEmpty { parts.append("heights=" + list(rowHeights)) }
        if !colors.isEmpty {
            parts.append("colors=" + colors.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ";"))
        }
        return parts.joined(separator: " ")
    }

    /// Reads what `options` wrote.
    mutating func apply(options: String) {
        for token in options.split(separator: " ").map(String.init) {
            switch token {
            case "header-column": headerColumn = true
            case "no-header-row": headerRow = false
            default:
                let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let numbers = pair[1].split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
                switch pair[0] {
                case "widths": columnWidths = numbers
                case "heights": rowHeights = numbers
                case "colors":
                    for entry in pair[1].split(separator: ";") {
                        let kv = entry.split(separator: ":", maxSplits: 1).map(String.init)
                        if kv.count == 2 { colors[kv[0]] = kv[1] }
                    }
                default: break
                }
            }
        }
    }
}

/// Markdown ⇄ blocks.
nonisolated enum BlockMarkdown {
    /// What a table's options are written as, on the line before it (Markdown has no
    /// way to say a table has a header column, or none in its first row).
    static let tableOptionsPrefix = "<!-- cue:table"

    static func parse(_ markdown: String) -> [DocBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [DocBlock] = []
        var index = 0
        var tableOptions: String?

        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }

            if line.isEmpty { continue }

            if line.hasPrefix(tableOptionsPrefix) {
                tableOptions = String(line.dropFirst(tableOptionsPrefix.count)).replacingOccurrences(of: "-->", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }

            // ```lang … ```
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "```" {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(DocBlock(.code(language: language, code: code.joined(separator: "\n"))))
                continue
            }

            if isDivider(line) {
                blocks.append(DocBlock(.divider))
                continue
            }

            // | a | b |  then  | --- | --- |
            if line.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                var rows = [cells(of: line)]
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(of: lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                index -= 1
                var table = DocTable(rows: rows)
                if let tableOptions { table.apply(options: tableOptions) }
                blocks.append(DocBlock(.table(table.padded)))
                tableOptions = nil
                continue
            }

            if let match = line.wholeMatch(of: #/!\[([^\]]*)\]\(([^)\s]+)\)/#) {
                blocks.append(DocBlock(.image(alt: String(match.1), source: String(match.2))))
                continue
            }
            if let match = line.wholeMatch(of: #/\[([^\]]+)\]\((cue-file://[^)\s]+)\)/#) {
                blocks.append(DocBlock(.file(name: String(match.1), source: String(match.2))))
                continue
            }

            blocks.append(DocBlock(.text(line)))
        }
        return blocks
    }

    /// Blocks back to Markdown: a blank line between blocks, list items of a list on
    /// consecutive lines, numbered items counted afresh. Empty text blocks — the empty
    /// line someone is about to type in — are left out.
    static func serialize(_ blocks: [DocBlock]) -> String {
        var out = ""
        var previous: DocBlock?
        var number = 0
        for block in blocks {
            if case .text(let line) = block.kind, TaskText.splitMark(line).body.trimmingCharacters(in: .whitespaces).isEmpty,
               TaskText.splitMark(line).mark.isEmpty {
                continue
            }
            let list = listFamily(block)
            number = list == .numbered ? (previous.flatMap(listFamily) == .numbered ? number + 1 : 1) : 0
            var rendered = render(block, number: number)
            if case .table(let table) = block.kind, table.hasOptions {
                rendered = "\(tableOptionsPrefix) \(table.options) -->\n" + rendered
            }
            if let previous {
                out += list != nil && list == listFamily(previous) ? "\n" : "\n\n"
            }
            out += rendered
            previous = block
        }
        return out
    }

    private static func render(_ block: DocBlock, number: Int) -> String {
        switch block.kind {
        case .text(let line):
            // Space left at the end of a line (where a `/search` was) is not kept.
            var line = line
            if !TaskText.splitMark(line).body.isEmpty {
                while line.last == " " { line.removeLast() }
            }
            if listFamily(block) == .numbered {
                return "\(number). " + TaskText.splitMark(line).body
            }
            return line
        case .code(let language, let code):
            return "```\(language)\n\(code)\n```"
        case .divider:
            return "---"
        case .image(let alt, let source):
            return "![\(alt)](\(source))"
        case .file(let name, let source):
            return "[\(name)](\(source))"
        case .table(let table):
            let table = table.padded
            var lines = [row(table.rows[0])]
            lines.append("| " + Array(repeating: "---", count: table.columnCount).joined(separator: " | ") + " |")
            lines += table.rows.dropFirst().map(row)
            return lines.joined(separator: "\n")
        }
    }

    enum ListFamily { case bullet, numbered, todo }

    /// Which list a text block is an item of (to-dos ticked or not are one list).
    static func listFamily(_ block: DocBlock) -> ListFamily? {
        guard case .text(let line) = block.kind else { return nil }
        let mark = TaskText.splitMark(line).mark
        guard !mark.isEmpty else { return nil }
        switch EditorBlock.from(mark: mark) {
        case .bullet: return .bullet
        case .numbered: return .numbered
        case .todo, .done: return .todo
        default: return nil
        }
    }

    // MARK: Lines

    static func isDivider(_ line: String) -> Bool {
        line.wholeMatch(of: #/(-\s*){3,}|(\*\s*){3,}|(_\s*){3,}/#) != nil
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.contains("-") else { return false }
        return line.wholeMatch(of: #/\|?(\s*:?-+:?\s*\|)+\s*(:?-+:?\s*)?\|?/#) != nil
    }

    /// A table row's cells; `\|` is a bar inside a cell.
    static func cells(of line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func row(_ cells: [String]) -> String {
        "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
    }
}

/// The kinds a block can be turned into or made from the slash menu, with what a
/// text line of each kind starts with.
nonisolated enum BlockChoice: String, CaseIterable, Identifiable {
    case text, heading1, heading2, heading3, bullet, numbered, todo, quote
    case divider, code, mermaid, table, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bullet: "Bulleted list"
        case .numbered: "Numbered list"
        case .todo: "To-do list"
        case .quote: "Quote"
        case .divider: "Divider"
        case .code: "Code"
        case .mermaid: "Mermaid diagram"
        case .table: "Table"
        case .image: "Image"
        }
    }

    var symbol: String {
        switch self {
        case .text: "textformat"
        case .heading1: "1.square"
        case .heading2: "2.square"
        case .heading3: "3.square"
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .todo: "checklist"
        case .quote: "text.quote"
        case .divider: "minus"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .mermaid: "point.3.connected.trianglepath.dotted"
        case .table: "tablecells"
        case .image: "photo"
        }
    }

    /// What Notion shows on the right: the Markdown that makes it as you type.
    var shortcut: String? {
        switch self {
        case .heading1: "#"
        case .heading2: "##"
        case .heading3: "###"
        case .bullet: "-"
        case .numbered: "1."
        case .todo: "[]"
        case .quote: ">"
        case .divider: "---"
        case .code: "```"
        default: nil
        }
    }

    /// Other words that find it.
    var keywords: String {
        switch self {
        case .text: "paragraph plain"
        case .heading1: "h1 title big"
        case .heading2: "h2 subtitle"
        case .heading3: "h3"
        case .bullet: "ul unordered points"
        case .numbered: "ol ordered steps"
        case .todo: "checkbox task check"
        case .quote: "blockquote citation"
        case .divider: "hr rule line separator"
        case .code: "snippet pre programming"
        case .mermaid: "chart flow graph diagram flowchart sequence"
        case .table: "grid rows columns"
        case .image: "picture photo screenshot"
        }
    }

    enum Section: String, CaseIterable { case basic = "Basic blocks", media = "Media", advanced = "Advanced" }

    var section: Section {
        switch self {
        case .image: .media
        case .code, .mermaid, .table: .advanced
        default: .basic
        }
    }

    /// The text line mark this kind starts with; nil for the kinds that are not text.
    var textMark: String? {
        switch self {
        case .text: ""
        case .heading1: "# "
        case .heading2: "## "
        case .heading3: "### "
        case .bullet: "- "
        case .numbered: "1. "
        case .todo: "- [ ] "
        case .quote: "> "
        default: nil
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return title.lowercased().contains(query) || keywords.contains(query) || (shortcut?.hasPrefix(query) ?? false)
    }

    /// The text kind a line is, for Turn into's tick.
    static func of(_ block: DocBlock) -> BlockChoice? {
        switch block.kind {
        case .text(let line):
            let mark = TaskText.splitMark(line).mark
            guard !mark.isEmpty else { return .text }
            return switch EditorBlock.from(mark: mark) {
            case .heading1: .heading1
            case .heading2: .heading2
            case .heading3: .heading3
            case .bullet: .bullet
            case .numbered: .numbered
            case .todo, .done: .todo
            case .quote: .quote
            default: .text
            }
        case .code(let language, _): return language.lowercased() == "mermaid" ? .mermaid : .code
        case .divider: return .divider
        case .table: return .table
        case .image: return .image
        case .file: return nil
        }
    }
}
