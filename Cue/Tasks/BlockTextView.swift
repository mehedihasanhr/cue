import AppKit
import SwiftUI

/// One text block of the description: a single line of rich text (a paragraph, a
/// heading, a list item, a quote) in the task editor's own view, so it shows Markdown
/// as what it means. Keys that cross blocks go to the editor: ↩ splits the line, ⌫ at
/// its start joins the one above, ↑ / ↓ off its first or last line move on, and `/`
/// opens the block menu, which then takes the arrows, ↩ and ⎋.
final class BlockTextView: RichTextView {
    var blockID = UUID()
    weak var model: BlockEditorModel?
    /// The line as last reported, so loading it back in is not seen as a change.
    var lastLine = ""
    private var focused = false

    private var slashOpen: Bool { model?.slash?.blockID == blockID }

    // MARK: The line

    /// Loads a line; an empty heading or item keeps its kind for what is typed next.
    func load(line: String) {
        lastLine = line
        let (mark, body) = TaskText.splitMark(line)
        if body.isEmpty, !mark.isEmpty, let block = EditorBlock.from(mark: mark) {
            textStorage?.setAttributedString(NSAttributedString(string: ""))
            typingAttributes = style.attributes(for: block)
        } else {
            load(markdown: line)
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// The line as Markdown, an empty one keeping its mark (`# ` for an empty heading).
    var line: String {
        guard let textStorage, textStorage.length > 0 else {
            let block = EditorStyle.block(of: typingAttributes)
            return block == .code ? "" : block.mark(number: listStart)
        }
        return markdown
    }

    override func didChangeText() {
        super.didChangeText()
        normalize()
        invalidateIntrinsicContentSize()
        let line = self.line
        if slashOpen { model?.slashTextChanged(in: blockID, view: self) }
        guard line != lastLine else { return }
        lastLine = line
        model?.textChanged(blockID, line: line)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        if slashOpen, !stillSelectingFlag { model?.slashTextChanged(in: blockID, view: self) }
    }

    // MARK: Size

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let font = style.font(for: EditorStyle.block(of: typingAttributes), .plain)
        let minimum = ceil(font.ascender - font.descender + font.leading) + 2
        return NSSize(width: NSView.noIntrinsicMetric, height: max(ceil(used.height), minimum) + textContainerInset.height * 2)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    // MARK: Keys

    override func insertNewline(_ sender: Any?) {
        if slashOpen { model?.slashKey(.choose); return }
        guard let textStorage else { return }
        let block = self.block(at: 0)
        if textStorage.length == 0, block != .paragraph {
            // ↩ on an empty heading or item: back to a plain line, as Notion does.
            setBlock(.paragraph)
            didChangeText()
            return
        }
        let caret = selectedRange()
        let before = textStorage.attributedSubstring(from: NSRange(location: 0, length: caret.location))
        let afterStart = NSMaxRange(caret)
        let after = textStorage.attributedSubstring(from: NSRange(location: afterStart, length: textStorage.length - afterStart))
        let beforeLine = block.mark(number: listStart) + EditorMarkdown.inlineMarkdown(before, in: NSRange(location: 0, length: before.length), block: block)
        let next = block.continuation
        let afterLine = next.mark(number: listStart + 1) + EditorMarkdown.inlineMarkdown(after, in: NSRange(location: 0, length: after.length), block: block)
        // The view keeps the whole line until the editor gives it back just the first part.
        model?.split(blockID, before: beforeLine, after: afterLine)
    }

    override func insertLineBreak(_ sender: Any?) { insertNewline(sender) }
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewline(sender) }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, selection.location == 0, !slashOpen {
            if (textStorage?.length ?? 0) == 0, EditorStyle.block(of: typingAttributes) != .paragraph {
                setBlock(.paragraph)
                didChangeText()
                return
            }
            if block(at: 0) == .paragraph {
                model?.backspaceAtStart(blockID, line: line)
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func moveUp(_ sender: Any?) {
        if slashOpen { model?.slashKey(.up); return }
        if caretLine(first: true), model?.arrow(from: blockID, up: true) == true { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if slashOpen { model?.slashKey(.down); return }
        if caretLine(first: false), model?.arrow(from: blockID, up: false) == true { return }
        super.moveDown(sender)
    }

    override func insertTab(_ sender: Any?) {
        if slashOpen { model?.slashKey(.choose); return }
        super.insertTab(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if slashOpen { model?.slashKey(.cancel); return }
        // ⎋ leaves the text, as Notion's does, and the window's ⎋ then closes the task.
        window?.makeFirstResponder(nil)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard let typed = (string as? String) ?? (string as? NSAttributedString)?.string, typed == "/" else { return }
        let location = selectedRange().location - 1
        let text = self.string as NSString
        let atStart = location == 0
        let afterSpace = location > 0 && CharacterSet.whitespaces.contains(UnicodeScalar(text.character(at: location - 1)) ?? " ")
        if atStart || afterSpace { model?.slashTyped(in: blockID, at: location) }
    }

    /// Whether the caret is on the block's first (or last) line of text.
    private func caretLine(first: Bool) -> Bool {
        guard let layoutManager, let textStorage, textStorage.length > 0 else { return true }
        let caret = min(selectedRange().location, textStorage.length - 1)
        let caretLine = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: caret), effectiveRange: nil)
        let edge = layoutManager.lineFragmentRect(forGlyphAt: first ? 0 : layoutManager.numberOfGlyphs - 1, effectiveRange: nil)
        return abs(caretLine.minY - edge.minY) < 1
    }

    // MARK: Focus and placeholder

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focused = true; needsDisplay = true }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            focused = false
            needsDisplay = true
            if slashOpen { model?.slashKey(.cancel) }
        }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard (textStorage?.length ?? 0) == 0 else { return }
        let block = EditorStyle.block(of: typingAttributes)
        // Notion's hints: on the line being typed in, and always on an empty heading or item.
        guard focused || block != .paragraph else { return }
        let hint = switch block {
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bullet, .numbered: "List"
        case .todo, .done: "To-do"
        case .quote: "Empty quote"
        default: "Type '/' for commands"
        }
        var attributes = style.attributes(for: block)
        attributes[.foregroundColor] = NSColor.tertiaryLabelColor
        let padding = textContainer?.lineFragmentPadding ?? 0
        let indent = (attributes[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
        NSAttributedString(string: hint, attributes: attributes)
            .draw(at: NSPoint(x: textContainerOrigin.x + padding + indent, y: textContainerOrigin.y))
    }
}

/// A text block in SwiftUI: the view grows with its text and follows its block's line.
struct BlockTextRepresentable: NSViewRepresentable {
    let id: UUID
    let line: String
    let listStart: Int
    let model: BlockEditorModel
    var fontSize: CGFloat = 16

    func makeNSView(context: Context) -> BlockTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = BlockTextView(frame: .zero, textContainer: container)
        view.blockID = id
        view.model = model
        // About 1.5× line height for the page's prose, as Notion sets it: at the
        // forms' spacing, a long description read as a wall of text.
        view.style = EditorStyle(size: fontSize, proseLineSpacing: (fontSize * 0.45).rounded())
        view.listStart = listStart
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.backgroundColor = .clear
        view.drawsBackground = false
        view.isRichText = true
        view.usesFontPanel = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.linkTextAttributes = [.foregroundColor: NSColor.labelColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.textContainerInset = NSSize(width: 0, height: 3)
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        let services = model.services
        view.insertImage = services.saveImage
        view.insertFile = services.saveFile
        view.imageForSource = { services.imageURL($0).flatMap(ImageCache.image(at:)) }
        view.iconForSource = { services.attachmentURL($0).map { NSWorkspace.shared.icon(forFile: $0.path) } }
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        view.load(line: line)
        model.register(view, for: id)
        return view
    }

    func updateNSView(_ view: BlockTextView, context: Context) {
        view.model = model
        if view.listStart != listStart {
            view.listStart = listStart
            view.needsDisplay = true
        }
        // A change made to the block from outside the view (Turn into, the slash menu).
        if line != view.lastLine { view.load(line: line) }
    }
}
