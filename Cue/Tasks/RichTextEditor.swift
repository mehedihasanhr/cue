import AppKit
import SwiftUI

// The task editor shows Markdown the way Notes or Notion do: as what it means,
// never as marks. `# ` at the start of a line makes a heading, `- ` a bullet,
// `*word*` italic — the marks vanish as they are typed. What is stored is still
// Markdown: the attributed text is turned back into it on every change.

/// What a paragraph is, kept on each of its characters as `.cueBlock`.
nonisolated enum EditorBlock: String, CaseIterable {
    case paragraph, heading1, heading2, heading3, bullet, numbered, todo, done, quote, code

    var isList: Bool { [.bullet, .numbered, .todo, .done].contains(self) }
    var isHeading: Bool { [.heading1, .heading2, .heading3].contains(self) }

    /// What Enter at the end of a line of this block starts.
    var continuation: EditorBlock {
        switch self {
        case .heading1, .heading2, .heading3: .paragraph
        case .done: .todo
        default: self
        }
    }

    /// The block a line with this mark is (`##`, `-`, `1.`, `- [x]`, `>`, ```` ``` ````).
    static func from(mark: String) -> EditorBlock? {
        let mark = mark.trimmingCharacters(in: .whitespaces)
        switch mark {
        case "#": return .heading1
        case "##": return .heading2
        case "###", "####", "#####", "######": return .heading3
        case "-", "+", "*", "•": return .bullet
        case ">": return .quote
        case "```": return .code
        default: break
        }
        if mark.wholeMatch(of: #/[-*+]\s*\[ ?\]/#) != nil { return .todo }
        if mark.wholeMatch(of: #/[-*+]\s*\[[xX]\]/#) != nil { return .done }
        if mark.wholeMatch(of: #/\d+[.)]/#) != nil { return .numbered }
        return nil
    }

    /// The Markdown that starts a line of this block (numbered lists count as they go).
    func mark(number: Int = 1) -> String {
        switch self {
        case .paragraph, .code: ""
        case .heading1: "# "
        case .heading2: "## "
        case .heading3: "### "
        case .bullet: "- "
        case .numbered: "\(number). "
        case .todo: "- [ ] "
        case .done: "- [x] "
        case .quote: "> "
        }
    }
}

extension NSAttributedString.Key {
    /// An `EditorBlock` raw value, on every character of the paragraph.
    static let cueBlock = NSAttributedString.Key("cue.block")
    /// Inline code.
    static let cueCode = NSAttributedString.Key("cue.code")
    /// The Markdown an attachment (image or file) is written back as.
    static let cueSource = NSAttributedString.Key("cue.source")
}

/// The inline traits of a run, apart from its block.
nonisolated struct InlineTraits: Equatable {
    var bold = false
    var italic = false
    var code = false
    var strike = false
    var link: String?

    static let plain = InlineTraits()
}

/// Fonts, colors and paragraph styles for every block.
@MainActor
struct EditorStyle {
    var size: CGFloat = 12
    /// Room between the lines of a wrapped paragraph, list item or quote. Small by
    /// default, for the compact forms; the task page, where descriptions are read and
    /// written at length, asks for more. Added under each line rather than as a line
    /// height, so a block's first line — and the handles and markers level with it —
    /// stays where it was.
    var proseLineSpacing: CGFloat = 1
    /// The room list markers and quote bars take on the left.
    static let listIndent: CGFloat = 20
    static let quoteIndent: CGFloat = 14
    static let codeIndent: CGFloat = 8

    func font(for block: EditorBlock, _ traits: InlineTraits) -> NSFont {
        if block == .code || traits.code {
            return .monospacedSystemFont(ofSize: size - 1, weight: traits.bold ? .semibold : .regular)
        }
        let (pointSize, weight): (CGFloat, NSFont.Weight) = switch block {
        case .heading1: (size + 6, .bold)
        case .heading2: (size + 3, .bold)
        case .heading3: (size + 1, .semibold)
        default: (size, traits.bold ? .bold : .regular)
        }
        let font = NSFont.systemFont(ofSize: pointSize, weight: weight)
        guard traits.italic || block == .quote else { return font }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: pointSize) ?? font
    }

    func paragraphStyle(for block: EditorBlock) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = proseLineSpacing
        style.paragraphSpacing = 3
        switch block {
        case .heading1, .heading2, .heading3:
            style.lineSpacing = 1
            style.paragraphSpacingBefore = 6
            style.paragraphSpacing = 4
        case .bullet, .numbered, .todo, .done:
            style.firstLineHeadIndent = Self.listIndent
            style.headIndent = Self.listIndent
            style.paragraphSpacing = 2
        case .quote:
            style.firstLineHeadIndent = Self.quoteIndent
            style.headIndent = Self.quoteIndent
        case .code:
            style.firstLineHeadIndent = Self.codeIndent
            style.headIndent = Self.codeIndent
            style.paragraphSpacing = 0
            style.lineSpacing = 2
        case .paragraph:
            break
        }
        return style
    }

    static let codeBackground = NSColor.labelColor.withAlphaComponent(0.08)

    /// Every attribute a character of `block` with `traits` carries.
    func attributes(for block: EditorBlock, _ traits: InlineTraits = .plain) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: block, traits),
            .paragraphStyle: paragraphStyle(for: block),
            .foregroundColor: block == .quote ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .cueBlock: block.rawValue,
        ]
        if traits.code, block != .code {
            attributes[.cueCode] = true
            attributes[.backgroundColor] = Self.codeBackground
        }
        if traits.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = traits.link { attributes[.link] = link }
        return attributes
    }

    /// The traits a character's attributes say it has (a heading's bold and a
    /// quote's italic are the block's, not the character's).
    static func traits(of attributes: [NSAttributedString.Key: Any], block: EditorBlock) -> InlineTraits {
        var traits = InlineTraits()
        let symbolic = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        traits.bold = symbolic.contains(.bold) && !block.isHeading
        traits.italic = symbolic.contains(.italic) && block != .quote
        traits.code = attributes[.cueCode] != nil && block != .code
        traits.strike = ((attributes[.strikethroughStyle] as? Int) ?? 0) != 0
        if let link = attributes[.link] { traits.link = (link as? URL)?.absoluteString ?? link as? String }
        return traits
    }

    static func block(of attributes: [NSAttributedString.Key: Any]) -> EditorBlock {
        (attributes[.cueBlock] as? String).flatMap(EditorBlock.init(rawValue:)) ?? .paragraph
    }
}

/// Markdown to attributed text and back. One paragraph per line; a fenced code
/// block is a run of `.code` paragraphs; an image or file line is one attachment.
@MainActor
enum EditorMarkdown {
    static func attributed(_ markdown: String, style: EditorStyle, image: (String) -> NSImage?, fileIcon: (String) -> NSImage?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var inCode = false
        let lines = markdown.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            var paragraph: NSAttributedString
            if inCode {
                if line == "```" { inCode = false; continue }
                paragraph = NSAttributedString(string: rawLine, attributes: style.attributes(for: .code))
            } else if line.hasPrefix("```") {
                inCode = true
                continue
            } else if case .image(let alt, let source) = MarkdownBlock.line(line) {
                paragraph = attachment(source: line, image: image(source), fallback: alt.isEmpty ? "Image" : alt, style: style)
            } else if case .attachment(let name, let source) = MarkdownBlock.line(line) {
                paragraph = attachment(source: line, image: fileIcon(source), fallback: name, style: style, label: name)
            } else {
                let (mark, body) = TaskText.splitMark(line)
                let block: EditorBlock = mark.isEmpty ? .paragraph : (EditorBlock.from(mark: mark) ?? .paragraph)
                paragraph = inline(body, block: block, style: style)
            }
            result.append(paragraph)
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: style.attributes(for: EditorStyle.block(of: paragraph.length > 0 ? paragraph.attributes(at: 0, effectiveRange: nil) : [:]))))
            }
        }
        return result
    }

    /// One line's inline Markdown (bold, italic, code, strikethrough, links) as runs.
    static func inline(_ body: String, block: EditorBlock, style: EditorStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard block != .code,
              let parsed = try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return NSAttributedString(string: body, attributes: style.attributes(for: block)) }
        for run in parsed.runs {
            var traits = InlineTraits()
            if let intent = run.inlinePresentationIntent {
                traits.bold = intent.contains(.stronglyEmphasized)
                traits.italic = intent.contains(.emphasized)
                traits.code = intent.contains(.code)
                traits.strike = intent.contains(.strikethrough)
            }
            traits.link = run.link?.absoluteString
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: style.attributes(for: block, traits)))
        }
        return result
    }

    /// An image or file as one attachment character (with a name after it for files),
    /// written back as `source`.
    static func attachment(source: String, image: NSImage?, fallback: String, style: EditorStyle, label: String? = nil) -> NSAttributedString {
        var attributes = style.attributes(for: .paragraph)
        attributes[.cueSource] = source
        let result = NSMutableAttributedString()
        if let image {
            let attachment = NSTextAttachment()
            let scaled = image.copy() as! NSImage
            let maxWidth: CGFloat = 320, maxHeight: CGFloat = 180
            let ratio = min(1, maxWidth / max(image.size.width, 1), maxHeight / max(image.size.height, 1))
            scaled.size = label == nil ? NSSize(width: (image.size.width * ratio).rounded(), height: (image.size.height * ratio).rounded()) : NSSize(width: 16, height: 16)
            let cell = NSTextAttachmentCell(imageCell: scaled)
            attachment.attachmentCell = cell
            let string = NSMutableAttributedString(attachment: attachment)
            string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
            result.append(string)
        }
        if let label {
            result.append(NSAttributedString(string: (image == nil ? "" : " ") + label, attributes: attributes.merging([.foregroundColor: NSColor.secondaryLabelColor, .underlineStyle: NSUnderlineStyle.single.rawValue]) { $1 }))
        } else if image == nil {
            result.append(NSAttributedString(string: fallback, attributes: attributes.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }))
        }
        return result
    }

    /// The Markdown the attributed text stands for.
    static func markdown(_ attributed: NSAttributedString) -> String {
        let string = attributed.string as NSString
        var lines: [String] = []
        var number = 0
        var inCode = false
        var location = 0
        while location <= string.length {
            var start = 0, end = 0, contentsEnd = 0
            string.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let content = NSRange(location: start, length: contentsEnd - start)
            let block = content.length > 0 ? EditorStyle.block(of: attributed.attributes(at: start, effectiveRange: nil)) : .paragraph
            if block == .code, !inCode { lines.append("```"); inCode = true }
            if block != .code, inCode { lines.append("```"); inCode = false }
            number = block == .numbered ? number + 1 : 0
            lines.append(block.mark(number: number) + inlineMarkdown(attributed, in: content, block: block))
            if end == string.length { break }
            location = end
        }
        if inCode { lines.append("```") }
        return lines.joined(separator: "\n")
    }

    static func inlineMarkdown(_ attributed: NSAttributedString, in range: NSRange, block: EditorBlock) -> String {
        var out = ""
        var source: String?
        var runs: [(InlineTraits, String)] = []
        attributed.enumerateAttributes(in: range) { attributes, subrange, _ in
            if let attachmentSource = attributes[.cueSource] as? String {
                if source != attachmentSource { out += attachmentSource; source = attachmentSource }
                return
            }
            let text = (attributed.string as NSString).substring(with: subrange)
            let traits = block == .code ? .plain : EditorStyle.traits(of: attributes, block: block)
            if let last = runs.last, last.0 == traits { runs[runs.count - 1].1 += text } else { runs.append((traits, text)) }
        }
        for (traits, text) in runs {
            // Marks hug the words: `**bold** ` rather than `** bold**`.
            let leading = text.prefix { $0.isWhitespace }
            let trailing = text.reversed().prefix { $0.isWhitespace }.reversed()
            let core = text.dropFirst(leading.count).dropLast(trailing.count)
            guard !core.isEmpty else { out += text; continue }
            var wrapped = String(core)
            if traits.code { wrapped = "`" + wrapped + "`" }
            if traits.bold { wrapped = "**" + wrapped + "**" }
            if traits.italic { wrapped = "*" + wrapped + "*" }
            if traits.strike { wrapped = "~~" + wrapped + "~~" }
            if let link = traits.link { wrapped = "[" + wrapped + "](" + link + ")" }
            out += leading + wrapped + trailing
        }
        return out
    }
}

extension MarkdownBlock {
    /// An image or attachment line, else nil.
    static func line(_ line: String) -> MarkdownBlock? {
        parse(line).first { if case .image = $0 { return true }; if case .attachment = $0 { return true }; return false }
    }
}

/// The text view: paragraphs styled by their block, marks turned into style as
/// they are typed, list markers and quote bars drawn in the margin.
class RichTextView: NSTextView {
    var style = EditorStyle()
    /// Plain text (snippets): nothing is Markdown, nothing converts.
    var plain = false
    var insertImage: ((Data) -> String?)?
    var insertFile: ((URL) -> String?)?
    var imageForSource: (String) -> NSImage? = { _ in nil }
    var iconForSource: (String) -> NSImage? = { _ in nil }
    var onBacktab: (() -> Void)?
    /// The number the first numbered item shows: a block editor holds one item per
    /// view, and tells each where it falls in its list.
    var listStart = 1

    override var acceptsFirstResponder: Bool { true }

    // MARK: Loading and reading

    func load(markdown: String) {
        let attributed = plain
            ? NSAttributedString(string: markdown, attributes: style.attributes(for: .paragraph))
            : EditorMarkdown.attributed(markdown, style: style, image: imageForSource, fileIcon: iconForSource)
        textStorage?.setAttributedString(attributed)
        typingAttributes = style.attributes(for: .paragraph)
        setSelectedRange(NSRange(location: attributed.length, length: 0))
        needsDisplay = true
    }

    var markdown: String {
        guard let textStorage else { return "" }
        return plain ? textStorage.string : EditorMarkdown.markdown(textStorage)
    }

    /// Inserts plain text at the caret (a snippet's `{{blank}}`).
    func insertPlain(_ string: String) {
        insertText(string, replacementRange: selectedRange())
    }

    // MARK: Paragraphs and blocks

    private var storageString: NSString { string as NSString }

    func paragraphRange(at location: Int) -> NSRange {
        storageString.paragraphRange(for: NSRange(location: min(location, storageString.length), length: 0))
    }

    /// The paragraph's characters without its newline.
    private func content(of paragraph: NSRange) -> NSRange {
        var length = paragraph.length
        if length > 0, storageString.character(at: paragraph.location + length - 1) == 10 { length -= 1 }
        return NSRange(location: paragraph.location, length: length)
    }

    func block(at location: Int) -> EditorBlock {
        let paragraph = paragraphRange(at: location)
        guard paragraph.length > 0, let textStorage else { return EditorStyle.block(of: typingAttributes) }
        return EditorStyle.block(of: textStorage.attributes(at: paragraph.location, effectiveRange: nil))
    }

    /// Makes the paragraphs the selection touches this block (the block again on
    /// a paragraph that already is: back to a plain paragraph). Undoable.
    func setBlock(_ block: EditorBlock, toggling: Bool = false) {
        let selection = selectedRange()
        let first = paragraphRange(at: selection.location)
        let last = paragraphRange(at: max(selection.location, NSMaxRange(selection) - (selection.length > 0 ? 1 : 0)))
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let target = toggling && self.block(at: selection.location) == block ? .paragraph : block
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        textStorage?.beginEditing()
        restyle(range, block: target)
        textStorage?.endEditing()
        didChangeText()
        typingAttributes = style.attributes(for: target, EditorStyle.traits(of: typingAttributes, block: EditorStyle.block(of: typingAttributes)))
        needsDisplay = true
    }

    /// Gives every character in `range` the block's fonts and paragraph style,
    /// keeping each run's inline traits.
    private func restyle(_ range: NSRange, block: EditorBlock) {
        guard let textStorage else { return }
        textStorage.enumerateAttributes(in: range) { attributes, subrange, _ in
            if attributes[.cueSource] != nil {
                var kept = attributes
                kept[.paragraphStyle] = style.paragraphStyle(for: .paragraph)
                kept[.cueBlock] = EditorBlock.paragraph.rawValue
                textStorage.setAttributes(kept, range: subrange)
                return
            }
            let traits = EditorStyle.traits(of: attributes, block: EditorStyle.block(of: attributes))
            textStorage.setAttributes(style.attributes(for: block, traits), range: subrange)
        }
    }

    /// After any change: every paragraph takes the block of its first character
    /// throughout (lines joined by a deletion, pasted text).
    func normalize() {
        guard let textStorage, textStorage.length > 0 else { return }
        textStorage.beginEditing()
        var location = 0
        while location < textStorage.length {
            let paragraph = paragraphRange(at: location)
            let block = EditorStyle.block(of: textStorage.attributes(at: paragraph.location, effectiveRange: nil))
            var mismatch = false
            textStorage.enumerateAttribute(.cueBlock, in: paragraph) { value, _, stop in
                if (value as? String) != block.rawValue { mismatch = true; stop.pointee = true }
            }
            if mismatch { restyle(paragraph, block: block) }
            location = NSMaxRange(paragraph)
        }
        textStorage.endEditing()
    }

    // MARK: Inline traits

    /// Bold / italic / code / strikethrough on the selection, or for what is typed next.
    func toggle(_ keyPath: WritableKeyPath<InlineTraits, Bool>) {
        let selection = selectedRange()
        guard selection.length > 0, let textStorage else {
            let block = EditorStyle.block(of: typingAttributes)
            var traits = EditorStyle.traits(of: typingAttributes, block: block)
            traits[keyPath: keyPath].toggle()
            typingAttributes = style.attributes(for: block, traits)
            return
        }
        var allOn = true
        textStorage.enumerateAttributes(in: selection) { attributes, _, stop in
            if !EditorStyle.traits(of: attributes, block: EditorStyle.block(of: attributes))[keyPath: keyPath] { allOn = false; stop.pointee = true }
        }
        guard shouldChangeText(in: selection, replacementString: nil) else { return }
        textStorage.beginEditing()
        textStorage.enumerateAttributes(in: selection) { attributes, subrange, _ in
            guard attributes[.cueSource] == nil else { return }
            let block = EditorStyle.block(of: attributes)
            var traits = EditorStyle.traits(of: attributes, block: block)
            traits[keyPath: keyPath] = !allOn
            textStorage.setAttributes(style.attributes(for: block, traits), range: subrange)
        }
        textStorage.endEditing()
        didChangeText()
    }

    // MARK: Typing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard !plain, let typed = (string as? String) ?? (string as? NSAttributedString)?.string, typed.count == 1, let character = typed.first else { return }
        applyShortcuts(typed: character)
    }

    /// `# `, `- `, `1. `, `> `, ```` ``` ```` and `[ ] ` at the start of a line become the
    /// block; `**bold**`, `*italic*`, `` `code` `` and `~~struck~~` become the trait
    /// as soon as they close (or a space follows).
    private func applyShortcuts(typed: Character) {
        guard let textStorage else { return }
        let caret = selectedRange().location
        let paragraph = paragraphRange(at: caret)
        let block = block(at: caret)
        guard block != .code else { return }
        let before = storageString.substring(with: NSRange(location: paragraph.location, length: caret - paragraph.location))

        if typed == " " {
            let head = String(before.dropLast())
            // `* ` stays text (so `* word *` can become italic); `- ` and `+ ` make bullets.
            let candidate = head == "*" ? nil : EditorBlock.from(mark: head)
            let listCheck: EditorBlock? = block.isList && (head == "[]" || head == "[ ]") ? .todo : block.isList && head.lowercased() == "[x]" ? .done : nil
            if let target = listCheck ?? candidate {
                let range = NSRange(location: paragraph.location, length: (before as NSString).length)
                guard shouldChangeText(in: range, replacementString: "") else { return }
                textStorage.replaceCharacters(in: range, with: "")
                didChangeText()
                setSelectedRange(NSRange(location: paragraph.location, length: 0))
                restyleParagraph(at: paragraph.location, block: target)
                return
            }
        }

        guard " *_`~".contains(typed) else { return }
        let body = typed == " " ? String(before.dropLast()) : before
        // Each: what comes before (not a word or another mark), the marked span, its text.
        let patterns: [(Regex<(Substring, Substring, Substring, Substring)>, WritableKeyPath<InlineTraits, Bool>)] = [
            (#/(^|[^*])(\*\*(\S(?:[^*]*?\S)?)\*\*)$/#, \.bold),
            (#/(^|[^_])(__(\S(?:[^_]*?\S)?)__)$/#, \.bold),
            (#/(^|[^~])(~~(\S(?:[^~]*?\S)?)~~)$/#, \.strike),
            (#/(^|[^`])(`([^`]+)`)$/#, \.code),
            (#/(^|[^\w*])(\*[ ]?([^*]+?)[ ]?\*)$/#, \.italic),
            (#/(^|[^\w_])(_[ ]?([^_]+?)[ ]?_)$/#, \.italic),
        ]
        for (pattern, trait) in patterns {
            guard let match = body.firstMatch(of: pattern) else { continue }
            let span = NSRange(match.2.startIndex..<match.2.endIndex, in: body)
            let range = NSRange(location: paragraph.location + span.location, length: span.length)
            let inner = String(match.3)
            var traits = EditorStyle.traits(of: textStorage.attributes(at: range.location, effectiveRange: nil), block: block)
            traits[keyPath: trait] = true
            let replacement = NSAttributedString(string: inner, attributes: style.attributes(for: block, traits))
            guard shouldChangeText(in: range, replacementString: inner) else { return }
            textStorage.replaceCharacters(in: range, with: replacement)
            didChangeText()
            let after = range.location + replacement.length
            if typed == " " {
                // The space that closed it stays, plain.
                textStorage.setAttributes(style.attributes(for: block), range: NSRange(location: after, length: 1))
                setSelectedRange(NSRange(location: after + 1, length: 0))
            } else {
                setSelectedRange(NSRange(location: after, length: 0))
            }
            typingAttributes = style.attributes(for: block)
            return
        }
    }

    private func restyleParagraph(at location: Int, block: EditorBlock) {
        let paragraph = paragraphRange(at: location)
        if paragraph.length > 0 {
            guard shouldChangeText(in: paragraph, replacementString: nil) else { return }
            textStorage?.beginEditing()
            restyle(paragraph, block: block)
            textStorage?.endEditing()
            didChangeText()
        }
        typingAttributes = style.attributes(for: block)
        needsDisplay = true
    }

    /// Enter continues a list or quote, ends one on an empty item, and leaves a
    /// heading for a plain paragraph.
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let block = block(at: selection.location)
        guard !plain, block != .paragraph else { super.insertNewline(sender); return }
        let paragraph = paragraphRange(at: selection.location)
        let content = content(of: paragraph)
        if content.length == 0, block.isList || block == .quote {
            restyleParagraph(at: paragraph.location, block: .paragraph)
            return
        }
        if block == .code, content.length == 0, paragraph.location > 0 {
            // A second empty line ends the code block.
            let previous = paragraphRange(at: paragraph.location - 1)
            if self.content(of: previous).length == 0, self.block(at: previous.location) == .code {
                guard shouldChangeText(in: previous, replacementString: "") else { return }
                textStorage?.replaceCharacters(in: previous, with: "")
                didChangeText()
                restyleParagraph(at: previous.location, block: .paragraph)
                return
            }
        }
        let next = block.continuation
        let newline = NSAttributedString(string: "\n", attributes: style.attributes(for: next))
        guard shouldChangeText(in: selection, replacementString: "\n") else { return }
        textStorage?.replaceCharacters(in: selection, with: newline)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + 1, length: 0))
        // What was split off after the caret takes the new paragraph's block.
        let rest = paragraphRange(at: selection.location + 1)
        if self.content(of: rest).length > 0 {
            textStorage?.beginEditing()
            restyle(rest, block: next)
            textStorage?.endEditing()
        }
        typingAttributes = style.attributes(for: next)
        needsDisplay = true
    }

    /// Backspace at the start of a styled paragraph makes it plain first.
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if !plain, selection.length == 0, selection.location == paragraphRange(at: selection.location).location, block(at: selection.location) != .paragraph {
            restyleParagraph(at: selection.location, block: .paragraph)
            return
        }
        super.deleteBackward(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        onBacktab?()
    }

    // MARK: Checkboxes

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !plain, let paragraph = todoParagraph(at: point) {
            let block = block(at: paragraph.location)
            restyleParagraph(at: paragraph.location, block: block == .done ? .todo : .done)
            return
        }
        // A click on an image or file opens it (an image in the viewer, a file in its
        // app) — where whoever hosts the editor says it can.
        if let openAttachment, event.clickCount == 1, let source = attachmentSource(at: point) {
            openAttachment(source)
            return
        }
        super.mouseDown(with: event)
    }

    /// Opens an image or file, given its `cue://` or `cue-file://` source. nil: a click
    /// on one selects it, as in any text.
    var openAttachment: ((String) -> Void)?

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // The text's I-beam everywhere but over what a click opens.
        if openAttachment != nil, attachmentSource(at: convert(event.locationInWindow, from: nil)) != nil {
            NSCursor.pointingHand.set()
        }
    }

    /// The source of the image or file drawn under `point`, if there is one.
    private func attachmentSource(at point: NSPoint) -> String? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.contains(local) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length, storage.attribute(.attachment, at: character, effectiveRange: nil) != nil else { return nil }
        return storage.attribute(.cueSource, at: character, effectiveRange: nil) as? String
    }

    /// The paragraph whose checkbox is under `point`, if any.
    private func todoParagraph(at point: NSPoint) -> NSRange? {
        guard point.x < textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) + EditorStyle.listIndent else { return nil }
        for (paragraph, block, rect) in paragraphRects() where block == .todo || block == .done {
            if rect.minY <= point.y, point.y < rect.maxY { return paragraph }
        }
        return nil
    }

    // MARK: Margin drawing

    /// Every paragraph with its block and its first line's rect (in view coordinates).
    private func paragraphRects() -> [(NSRange, EditorBlock, NSRect)] {
        guard let layoutManager else { return [] }
        var rects: [(NSRange, EditorBlock, NSRect)] = []
        let origin = textContainerOrigin
        var location = 0
        repeat {
            let paragraph = paragraphRange(at: location)
            let block = block(at: paragraph.location)
            var rect: NSRect
            if paragraph.length > 0 {
                let glyph = layoutManager.glyphIndexForCharacter(at: paragraph.location)
                rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                rect = layoutManager.extraLineFragmentRect
            }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            rects.append((paragraph, block, rect))
            location = NSMaxRange(paragraph)
        } while location < storageString.length
        // An empty last line after a newline is its own paragraph too.
        if storageString.length > 0, storageString.character(at: storageString.length - 1) == 10 {
            let rect = layoutManager.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
            rects.append((NSRange(location: storageString.length, length: 0), EditorStyle.block(of: typingAttributes), rect))
        }
        return rects
    }

    /// The whole paragraph's rect, all its lines.
    private func fullRect(of paragraph: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer, paragraph.length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !plain else { super.draw(dirtyRect); return }
        let rects = paragraphRects()
        drawCodeBackgrounds(rects)
        super.draw(dirtyRect)
        drawMarkers(rects)
    }

    private func drawCodeBackgrounds(_ rects: [(NSRange, EditorBlock, NSRect)]) {
        var union: NSRect?
        let left = textContainerOrigin.x + 1
        let right = bounds.width - textContainerInset.width - 1
        func flush() {
            guard let rect = union else { return }
            EditorStyle.codeBackground.setFill()
            NSBezierPath(roundedRect: NSRect(x: left, y: rect.minY - 1, width: right - left, height: rect.height + 2), xRadius: 5, yRadius: 5).fill()
            union = nil
        }
        for (paragraph, block, first) in rects {
            guard block == .code else { flush(); continue }
            let rect = fullRect(of: paragraph) ?? first
            union = union.map { $0.union(rect) } ?? rect
        }
        flush()
    }

    static let accent = NSColor(red: 0x0E / 255, green: 0x4F / 255, blue: 0xEC / 255, alpha: 1)

    private func drawMarkers(_ rects: [(NSRange, EditorBlock, NSRect)]) {
        let padding = textContainer?.lineFragmentPadding ?? 0
        let left = textContainerOrigin.x + padding
        var number = 0
        let markerColor = NSColor.labelColor.withAlphaComponent(0.55)
        for (paragraph, block, rect) in rects {
            number = block == .numbered ? number + 1 : 0
            let font = style.font(for: block, .plain)
            switch block {
            case .bullet:
                let dot = NSAttributedString(string: "•", attributes: [.font: NSFont.systemFont(ofSize: font.pointSize, weight: .bold), .foregroundColor: markerColor])
                dot.draw(at: NSPoint(x: left + 6, y: rect.minY))
            case .numbered:
                let label = NSAttributedString(string: "\(number + listStart - 1).", attributes: [.font: NSFont.systemFont(ofSize: font.pointSize - 1, weight: .semibold), .foregroundColor: markerColor])
                let width = label.size().width
                label.draw(at: NSPoint(x: left + EditorStyle.listIndent - 5 - width, y: rect.minY + 0.5))
            case .todo, .done:
                let size: CGFloat = 12
                let box = NSRect(x: left + 2, y: rect.minY + (font.ascender - font.descender - size) / 2 + 1, width: size, height: size)
                let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
                if block == .done {
                    Self.accent.setFill()
                    path.fill()
                    let check = NSBezierPath()
                    check.move(to: NSPoint(x: box.minX + 3, y: box.midY))
                    check.line(to: NSPoint(x: box.minX + 5.2, y: box.midY + 2.4))
                    check.line(to: NSPoint(x: box.maxX - 2.6, y: box.minY + 2.8))
                    check.lineWidth = 1.6
                    check.lineCapStyle = .round
                    check.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    check.stroke()
                } else {
                    markerColor.setStroke()
                    path.lineWidth = 1.2
                    path.stroke()
                }
            case .quote:
                let rect = fullRect(of: paragraph) ?? rect
                Self.accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: left + 2, y: rect.minY + 1, width: 3, height: rect.height - 2), xRadius: 1.5, yRadius: 1.5).fill()
            default:
                break
            }
        }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        // An attachment's attributes must not carry over to what is typed after it.
        if typingAttributes[.cueSource] != nil {
            var attributes = style.attributes(for: .paragraph)
            attributes[.paragraphStyle] = typingAttributes[.paragraphStyle] ?? attributes[.paragraphStyle]!
            typingAttributes = attributes
        }
    }

    // MARK: Attachments, paste and drop

    /// Inserts an image or file line (Markdown) on a line of its own.
    func insertBlock(markdown: String) {
        let range = selectedRange()
        let needsNewlineBefore = range.location > 0 && storageString.character(at: range.location - 1) != 10
        let block = EditorMarkdown.attributed(markdown, style: style, image: imageForSource, fileIcon: iconForSource)
        let snippet = NSMutableAttributedString()
        if needsNewlineBefore { snippet.append(NSAttributedString(string: "\n", attributes: style.attributes(for: .paragraph))) }
        snippet.append(block)
        snippet.append(NSAttributedString(string: "\n", attributes: style.attributes(for: .paragraph)))
        guard shouldChangeText(in: range, replacementString: snippet.string) else { return }
        textStorage?.replaceCharacters(in: range, with: snippet)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + snippet.length, length: 0))
        typingAttributes = style.attributes(for: .paragraph)
    }

    /// Text pastes as Markdown (so `**bold**` from elsewhere lands bold); an image
    /// or files paste as attachments.
    override func paste(_ sender: Any?) {
        if plain { pasteAsPlainText(sender); return }
        if takeContent(from: NSPasteboard.general) { return }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let block = EditorStyle.block(of: typingAttributes)
        let pasted: NSAttributedString
        if text.contains("\n") || block == .code {
            pasted = EditorMarkdown.attributed(text, style: style, image: imageForSource, fileIcon: iconForSource)
        } else {
            pasted = EditorMarkdown.inline(text, block: block, style: style)
        }
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: pasted.string) else { return }
        textStorage?.replaceCharacters(in: range, with: pasted)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + pasted.length, length: 0))
        normalize()
    }

    private static func carriesContent(_ sender: any NSDraggingInfo) -> Bool {
        let types = sender.draggingPasteboard.types ?? []
        return types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.carriesContent(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.carriesContent(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        Self.carriesContent(sender) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if Self.carriesContent(sender) {
            window?.makeFirstResponder(self)
            return takeContent(from: sender.draggingPasteboard)
        }
        return super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        if let sender, Self.carriesContent(sender) { return }
        super.concludeDragOperation(sender)
    }

    /// Files become images (when they are pictures) or attachments; raw image
    /// data becomes an image. Returns false when there is nothing of the kind.
    func takeContent(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            var inserted = false
            for url in urls {
                let isImage = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"].contains(url.pathExtension.lowercased())
                let markdown = isImage ? (try? Data(contentsOf: url)).flatMap { insertImage?($0) } : insertFile?(url)
                if let markdown {
                    insertBlock(markdown: markdown)
                    inserted = true
                }
            }
            return inserted
        }
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), let markdown = insertImage?(data) else { return false }
        insertBlock(markdown: markdown)
        return true
    }
}

/// The task editor for SwiftUI: `text` is Markdown, the view shows it rendered.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let handle: Handle
    let insertImage: (Data) -> String?
    let insertFile: (URL) -> String?
    /// Resolves `cue://name.png` image references to files.
    var imageURL: (String) -> URL? = { _ in nil }
    /// Resolves `cue-file://id/name` attachment references to files.
    var attachmentURL: (String) -> URL? = { _ in nil }
    var fontSize: CGFloat = 12
    /// Plain text, not Markdown (snippets).
    var plain = false
    /// ⇧⇥ in the editor.
    var onBacktab: () -> Void = {}
    /// A click on an image or file, with its source; nil leaves clicks to select them.
    var onOpenAttachment: ((String) -> Void)? = nil

    /// Lets the toolbar reach the text view.
    final class Handle {
        weak var textView: RichTextView?
        /// The word the caret is in when it starts with `/`, `#` or `!` (nil otherwise),
        /// reported on every change — for the form's suggestion lists.
        var onToken: (String?) -> Void = { _ in }
        /// A chance to take ↑ ↓ ↩ ⇥ ⎋ before the text view does (true: taken).
        var interceptCommand: (Selector) -> Bool = { _ in false }

        func bold() { textView?.toggle(\.bold) }
        func italic() { textView?.toggle(\.italic) }
        func strikethrough() { textView?.toggle(\.strike) }
        func code() { textView?.toggle(\.code) }
        /// The block for the current paragraph (again: back to a plain paragraph).
        func block(_ block: EditorBlock) { textView?.setBlock(block, toggling: true) }
        /// An image or file line.
        func insertBlock(_ markdown: String) { textView?.insertBlock(markdown: markdown) }
        /// Plain text at the caret.
        func insert(_ string: String) { textView?.insertPlain(string) }
        /// Puts the caret at the very start (a form seeded with an attachment wants the title typed above it).
        func moveToStart() { textView?.setSelectedRange(NSRange(location: 0, length: 0)) }

        /// The token at the caret (see `onToken`) and where it is.
        static func token(in textView: NSTextView) -> (String, NSRange)? {
            let text = textView.string as NSString
            let caret = textView.selectedRange().location
            guard textView.selectedRange().length == 0, caret <= text.length else { return nil }
            var start = caret
            while start > 0 {
                let character = Character(UnicodeScalar(text.character(at: start - 1)) ?? " ")
                if character.isWhitespace || character.isNewline { break }
                start -= 1
            }
            let range = NSRange(location: start, length: caret - start)
            let word = text.substring(with: range)
            guard let first = word.first, "/#!".contains(first) else { return nil }
            return (word, range)
        }

        /// Replaces the token at the caret with `replacement`.
        func replaceToken(with replacement: String) {
            guard let textView, let (_, range) = Self.token(in: textView) else { return }
            textView.insertText(replacement, replacementRange: range)
        }

        /// Removes the token at the caret (a `/command` once it has run, a `#project`
        /// or `!priority` once picked) and the space before it, so no gap is left.
        func removeToken() {
            guard let textView, let (_, range) = Self.token(in: textView) else { return }
            let text = textView.string as NSString
            var whole = range
            if whole.location > 0, text.character(at: whole.location - 1) == 0x20 {
                whole = NSRange(location: whole.location - 1, length: whole.length + 1)
            }
            textView.insertText("", replacementRange: whole)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, whose layout manager the margin drawing asks for line rects.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let textView = RichTextView(frame: .zero, textContainer: container)
        textView.style = EditorStyle(size: fontSize)
        textView.plain = plain
        textView.delegate = context.coordinator
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.linkTextAttributes = [.foregroundColor: RichTextView.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.insertImage = insertImage
        textView.insertFile = insertFile
        textView.imageForSource = { source in imageURL(source).flatMap(ImageCache.image(at:)) }
        textView.iconForSource = { source in attachmentURL(source).map { NSWorkspace.shared.icon(forFile: $0.path) } }
        textView.onBacktab = onBacktab
        textView.openAttachment = onOpenAttachment
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.load(markdown: text)
        context.coordinator.lastMarkdown = text
        handle.textView = textView

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? RichTextView)?.openAttachment = onOpenAttachment
        guard let textView = scroll.documentView as? RichTextView, text != context.coordinator.lastMarkdown else { return }
        context.coordinator.lastMarkdown = text
        textView.load(markdown: text)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, handle: handle) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let handle: Handle
        /// What the binding last held, so a change of our own is not loaded back.
        var lastMarkdown = ""

        init(text: Binding<String>, handle: Handle) {
            self.text = text
            self.handle = handle
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? RichTextView else { return }
            if !textView.plain { textView.normalize() }
            let markdown = textView.markdown
            lastMarkdown = markdown
            text.wrappedValue = markdown
            handle.onToken(Handle.token(in: textView)?.0)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            handle.onToken(Handle.token(in: textView)?.0)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            handle.interceptCommand(commandSelector)
        }
    }
}
