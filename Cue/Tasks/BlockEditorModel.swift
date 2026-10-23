import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the editor needs from whoever stores the task: where images and files are,
/// how to keep new ones, and how to open them.
struct BlockServices {
    var imageURL: (String) -> URL? = { _ in nil }
    var attachmentURL: (String) -> URL? = { _ in nil }
    var saveImage: (Data) -> String? = { _ in nil }
    var saveFile: (URL) -> String? = { _ in nil }
    var openImage: (URL) -> Void = { _ in }
}

/// The description editor's state: its blocks, which one has the caret, the slash
/// menu, a drag under way. Every change is written back as Markdown through
/// `onChange`; nothing else holds the text.
@Observable
@MainActor
final class BlockEditorModel {
    var blocks: [DocBlock] = []
    /// The block under the pointer, whose handles show in the margin.
    var hoveredID: UUID?
    /// The block whose actions menu is open (its handles stay while it is).
    var menuID: UUID?
    var slash: SlashState?
    /// A block being dragged by its handle, and where it would land.
    var draggingID: UUID?
    var dropTarget: DropTarget?

    struct SlashState: Equatable {
        var blockID: UUID
        /// Where the `/` is in the block's text.
        var location: Int
        var query = ""
        var highlighted = 0
    }

    struct DropTarget: Equatable {
        var id: UUID
        var below: Bool
    }

    enum Caret: Equatable { case start, end, offset(Int) }
    enum SlashKey { case up, down, choose, cancel }

    @ObservationIgnored var onChange: (String) -> Void = { _ in }
    @ObservationIgnored var services = BlockServices()
    /// The Markdown last loaded or written, to tell an edit made here from one elsewhere.
    @ObservationIgnored private(set) var markdown = ""
    @ObservationIgnored private var views: [UUID: WeakTextView] = [:]
    @ObservationIgnored private var pendingFocus: (id: UUID, caret: Caret, typeSlash: Bool)?

    private struct WeakTextView { weak var view: NSTextView? }

    #if DEBUG
    /// The editor last shown, for the `cue://debug/…` commands that drive it in tests.
    static weak var current: BlockEditorModel?
    #endif

    // MARK: Loading and saving

    func load(_ markdown: String) {
        self.markdown = markdown
        blocks = BlockMarkdown.parse(markdown)
        if blocks.isEmpty { blocks = [DocBlock(.text(""))] }
        slash = nil
    }

    private func commit() {
        let markdown = BlockMarkdown.serialize(blocks)
        guard markdown != self.markdown else { return }
        self.markdown = markdown
        onChange(markdown)
    }

    func index(of id: UUID) -> Int? { blocks.firstIndex { $0.id == id } }

    /// The number a numbered item shows: how many numbered items run up to it.
    func listNumber(of id: UUID) -> Int {
        guard let index = index(of: id) else { return 1 }
        var number = 0
        var cursor = index
        while cursor >= 0, BlockMarkdown.listFamily(blocks[cursor]) == .numbered {
            number += 1
            cursor -= 1
        }
        return max(number, 1)
    }

    // MARK: Text views

    func register(_ view: NSTextView, for id: UUID) {
        views[id] = WeakTextView(view: view)
        if let pending = pendingFocus, pending.id == id {
            DispatchQueue.main.async { [weak self] in self?.applyFocus() }
        }
    }

    func textView(for id: UUID) -> NSTextView? { views[id]?.view }

    /// Puts the caret in a block, now or as soon as its view exists.
    func focus(_ id: UUID, _ caret: Caret = .end, typeSlash: Bool = false) {
        pendingFocus = (id, caret, typeSlash)
        DispatchQueue.main.async { [weak self] in self?.applyFocus() }
    }

    private func applyFocus() {
        guard let pending = pendingFocus, let view = views[pending.id]?.view, let window = view.window else { return }
        pendingFocus = nil
        // The line may have changed since the view last showed it (lines just joined).
        if let text = view as? BlockTextView, let line = blocks.first(where: { $0.id == pending.id })?.text, text.lastLine != line {
            text.load(line: line)
        }
        window.makeFirstResponder(view)
        let length = (view.string as NSString).length
        let location = switch pending.caret {
        case .start: 0
        case .end: length
        case .offset(let offset): min(max(offset, 0), length)
        }
        view.setSelectedRange(NSRange(location: location, length: 0))
        if pending.typeSlash { view.insertText("/", replacementRange: view.selectedRange()) }
    }

    // MARK: Text edits (from a block's text view)

    /// A text block's line changed as it was typed; a line that now holds more than
    /// one line (a paste, a dropped image, a ``` fence) becomes the blocks it says.
    func textChanged(_ id: UUID, line: String) {
        guard let index = index(of: id) else { return }
        if line.contains("\n") || isBlockLine(line) {
            let parsed = BlockMarkdown.parse(line)
            replace(at: index, with: parsed.isEmpty ? [DocBlock(id: id, .text(""))] : parsed)
            return
        }
        guard blocks[index].kind != .text(line) else { return }
        blocks[index].kind = .text(line)
        commit()
    }

    /// A line that is a block of another kind on its own (an image, a file, a divider).
    private func isBlockLine(_ line: String) -> Bool {
        let parsed = BlockMarkdown.parse(line)
        return parsed.count == 1 && !parsed[0].isText
    }

    private func replace(at index: Int, with parsed: [DocBlock]) {
        blocks.replaceSubrange(index...index, with: parsed)
        // Somewhere to go on typing after what was pasted.
        let after = index + parsed.count
        if parsed.last.map({ !$0.isText }) ?? false, after >= blocks.count || !blocks[after].isText {
            blocks.insert(DocBlock(.text("")), at: after)
        }
        commit()
        // The caret goes to the last line of what came in, or the line made after it.
        let end = min(index + parsed.count + 1, blocks.count)
        if let target = blocks[index..<end].last(where: \.isText) { focus(target.id, .end) }
    }

    /// ↩: the line splits at the caret into this block and a new one below.
    func split(_ id: UUID, before: String, after: String) {
        guard let index = index(of: id) else { return }
        blocks[index].kind = .text(before)
        let new = DocBlock(.text(after))
        blocks.insert(new, at: index + 1)
        commit()
        focus(new.id, .start)
    }

    /// ⌫ at the start of a plain line: it joins the line above (or, after a divider,
    /// takes the divider away).
    func backspaceAtStart(_ id: UUID, line: String) {
        guard let index = index(of: id), index > 0 else { return }
        let previous = blocks[index - 1]
        switch previous.kind {
        case .text(let above):
            let caret = (textView(for: previous.id)?.string as NSString?)?.length ?? (above as NSString).length
            let joined = joinable(above) + TaskText.splitMark(line).body
            blocks[index - 1].kind = .text(joined)
            blocks.remove(at: index)
            commit()
            focus(previous.id, .offset(caret))
        case .divider:
            blocks.remove(at: index - 1)
            commit()
        default:
            // An image, table or code above: an empty line goes, and the caret stays put otherwise.
            if TaskText.splitMark(line).body.isEmpty {
                blocks.remove(at: index)
                commit()
                if let text = blocks[..<index].last(where: \.isText) { focus(text.id, .end) }
            }
        }
    }

    /// An empty heading or item above keeps its mark: "# " + what is joined to it.
    private func joinable(_ line: String) -> String {
        let (mark, body) = TaskText.splitMark(line)
        return body.isEmpty ? mark : line
    }

    /// ↑ / ↓ off the first or last line of a block: on to the text block above or below.
    func arrow(from id: UUID, up: Bool) -> Bool {
        guard let index = index(of: id) else { return false }
        let range = up ? Array(blocks[..<index].reversed()) : Array(blocks[(index + 1)...])
        guard let target = range.first(where: { views[$0.id]?.view != nil }) else { return false }
        focus(target.id, up ? .end : .start)
        return true
    }

    // MARK: Block edits

    func update(_ id: UUID, _ kind: DocBlock.Kind) {
        guard let index = index(of: id), blocks[index].kind != kind else { return }
        blocks[index].kind = kind
        commit()
    }

    func updateTable(_ id: UUID, _ change: (inout DocTable) -> Void) {
        guard let index = index(of: id), case .table(var table) = blocks[index].kind else { return }
        change(&table)
        blocks[index].kind = .table(table)
        commit()
    }

    func insert(_ block: DocBlock, after id: UUID?) {
        let index = id.flatMap(index(of:)).map { $0 + 1 } ?? blocks.count
        blocks.insert(block, at: index)
        commit()
    }

    func delete(_ id: UUID) {
        guard let index = index(of: id) else { return }
        blocks.remove(at: index)
        if blocks.isEmpty { blocks = [DocBlock(.text(""))] }
        commit()
        if menuID == id { menuID = nil }
    }

    func duplicate(_ id: UUID) {
        guard let index = index(of: id) else { return }
        blocks.insert(blocks[index].copy, at: index + 1)
        commit()
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = index(of: id) else { return }
        let target = index + offset
        guard blocks.indices.contains(target) else { return }
        blocks.swapAt(index, target)
        commit()
    }

    /// Where a dragged block lands: above or below the block it was dropped on.
    func move(_ id: UUID, to target: DropTarget) {
        guard id != target.id, let from = index(of: id) else { return }
        let block = blocks.remove(at: from)
        guard let anchor = index(of: target.id) else { blocks.insert(block, at: from); return }
        blocks.insert(block, at: target.below ? anchor + 1 : anchor)
        commit()
    }

    /// Turn into: a text line keeps its words under the new mark; text becomes code
    /// (or a diagram) with them as its code, and back.
    func turn(_ id: UUID, into choice: BlockChoice) {
        guard let index = index(of: id) else { return }
        let words: String = switch blocks[index].kind {
        case .text(let line): TaskText.splitMark(line).body
        case .code(_, let code): code.replacingOccurrences(of: "\n", with: " ")
        default: ""
        }
        if let mark = choice.textMark {
            blocks[index].kind = .text(mark + words)
        } else if choice == .code || choice == .mermaid {
            let code: String = if case .code(_, let code) = blocks[index].kind { code } else { words }
            blocks[index].kind = .code(language: choice == .mermaid ? "mermaid" : "", code: code)
        } else {
            return
        }
        commit()
        if blocks[index].isText { focus(id, .end) }
    }

    /// A click under the last block: into the last line if it is an empty one, else a
    /// new line there.
    func focusEnd() {
        if let last = blocks.last, case .text(let line) = last.kind, TaskText.splitMark(line).body.isEmpty {
            focus(last.id, .end)
            return
        }
        let new = DocBlock(.text(""))
        blocks.append(new)
        focus(new.id, .start)
    }

    /// The + in a block's margin: a new line under it, with the slash menu open.
    func addBelow(_ id: UUID) {
        let new = DocBlock(.text(""))
        insert(new, after: id)
        focus(new.id, .start, typeSlash: true)
    }

    func markdown(of id: UUID) -> String {
        guard let index = index(of: id) else { return "" }
        return BlockMarkdown.serialize([blocks[index]])
    }

    // MARK: Slash menu

    var slashChoices: [BlockChoice] {
        guard let slash else { return [] }
        return BlockChoice.allCases.filter { $0.matches(slash.query) }
    }

    /// `/` was typed at `location` in a block, at its start or after a space.
    func slashTyped(in id: UUID, at location: Int) {
        slash = SlashState(blockID: id, location: location)
    }

    /// After each edit or caret move in the block with the menu: what follows the `/`
    /// is the search; the `/` gone, the caret before it, or two spaces typed closes it.
    func slashTextChanged(in id: UUID, view: NSTextView) {
        guard var state = slash, state.blockID == id else { return }
        let text = view.string as NSString
        let caret = view.selectedRange().location
        guard state.location < text.length, text.character(at: state.location) == 47, caret > state.location else {
            slash = nil
            return
        }
        let query = text.substring(with: NSRange(location: state.location + 1, length: caret - state.location - 1))
        if query.hasSuffix("  ") || query.contains("\n") { slash = nil; return }
        if query != state.query {
            state.query = query
            state.highlighted = 0
        }
        slash = state
        if slashChoices.isEmpty, query.count > 12 { slash = nil }
    }

    func slashKey(_ key: SlashKey) {
        guard var state = slash else { return }
        let count = slashChoices.count
        switch key {
        case .up:
            guard count > 0 else { return }
            state.highlighted = (state.highlighted - 1 + count) % count
            slash = state
        case .down:
            guard count > 0 else { return }
            state.highlighted = (state.highlighted + 1) % count
            slash = state
        case .choose:
            if slashChoices.indices.contains(state.highlighted) { chooseSlash(slashChoices[state.highlighted]) } else { slash = nil }
        case .cancel:
            slash = nil
        }
    }

    /// Takes the `/search` out of the line, then makes the choice: the line itself
    /// becomes it when nothing else is on it, else it goes in below.
    func chooseSlash(_ choice: BlockChoice) {
        guard let state = slash, let index = index(of: state.blockID) else { slash = nil; return }
        slash = nil
        if let view = textView(for: state.blockID) {
            let text = view.string as NSString
            let end = min(max(view.selectedRange().location, state.location + 1), text.length)
            let range = NSRange(location: state.location, length: end - state.location)
            if view.shouldChangeText(in: range, replacementString: "") {
                view.textStorage?.replaceCharacters(in: range, with: "")
                view.didChangeText()
                view.setSelectedRange(NSRange(location: state.location, length: 0))
            }
        }
        guard index < blocks.count else { return }
        let id = blocks[index].id
        let line = blocks[index].text ?? ""
        let empty = TaskText.splitMark(line).body.trimmingCharacters(in: .whitespaces).isEmpty
        make(choice, at: id, replacing: empty)
    }

    /// Makes a block of the chosen kind at a block: in its place, or below it.
    func make(_ choice: BlockChoice, at id: UUID, replacing: Bool) {
        guard let index = index(of: id) else { return }
        if let mark = choice.textMark {
            if replacing {
                blocks[index].kind = .text(mark + TaskText.splitMark(blocks[index].text ?? "").body)
                commit()
                focus(id, .end)
            } else {
                let new = DocBlock(.text(mark))
                blocks.insert(new, at: index + 1)
                commit()
                focus(new.id, .start)
            }
            return
        }
        let new: DocBlock
        switch choice {
        case .divider: new = DocBlock(.divider)
        case .code: new = DocBlock(.code(language: "", code: ""))
        case .mermaid: new = DocBlock(.code(language: "mermaid", code: "flowchart TD\n    A[Start] --> B{Decide}\n    B -->|Yes| C[Do it]\n    B -->|No| D[Skip]"))
        case .table: new = DocBlock(.table(.empty))
        case .image:
            pickImage(at: id, replacing: replacing)
            return
        default: return
        }
        place(new, at: index, replacing: replacing)
    }

    /// Puts a non-text block in a line's place (or below it), with a line after it to
    /// go on typing in.
    private func place(_ block: DocBlock, at index: Int, replacing: Bool) {
        if replacing { blocks[index] = block } else { blocks.insert(block, at: index + 1) }
        let at = replacing ? index : index + 1
        let next = at + 1
        // An empty plain line after it, to go on typing in — not the next line of text,
        // whose start the caret would otherwise land on.
        let emptyLineFollows = next < blocks.count && blocks[next].text.map { $0.trimmingCharacters(in: .whitespaces).isEmpty } == true
        if !emptyLineFollows {
            blocks.insert(DocBlock(.text("")), at: next)
        }
        commit()
        if case .code = block.kind { focus(block.id, .start) } else { focus(blocks[next].id, .start) }
    }

    private func pickImage(at id: UUID, replacing: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
                      let markdown = self.services.saveImage(data), let index = self.index(of: id),
                      case .image = BlockMarkdown.parse(markdown).first?.kind, let image = BlockMarkdown.parse(markdown).first else { return }
                self.place(image, at: index, replacing: replacing)
            }
        }
    }
}
