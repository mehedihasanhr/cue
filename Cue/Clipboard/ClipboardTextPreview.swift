import AppKit
import SwiftUI

/// A text entry shown as what it is: code highlighted with its language named (HTML
/// source included), Markdown rendered (tables too), text that was copied with
/// formatting in that formatting — in the island's own colours — and anything else
/// as plain text; a switch shows the source of the rendered ones. Copying the entry
/// puts back every flavour it came with.
struct ClipboardTextPreview: View {
    let item: ClipboardItem
    let clipboard: ClipboardHistory
    /// Inside the island's inline detail: a smaller type.
    var compact = false
    @State private var showSource = false

    enum Presentation {
        case rich(NSAttributedString)
        case code(CodeSnippet.Language)
        case markdown
        case plain

        /// Named on a pill; nil for plain text.
        var label: String? {
            switch self {
            case .rich: "Rich text"
            case .code(let language): language.title
            case .markdown: "Markdown"
            case .plain: nil
            }
        }

        var symbol: String {
            switch self {
            case .rich: "textformat"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .markdown, .plain: "text.alignleft"
            }
        }
    }

    /// What the entry is: code by its shape, Markdown by its marks — the text says
    /// what it is — then the formatting it was copied with, else plain.
    static func presentation(of item: ClipboardItem, clipboard: ClipboardHistory) -> Presentation {
        guard item.kind == .text else { return .plain }
        if let language = CodeSnippet.detect(item.text) { return language == .markdown ? .markdown : .code(language) }
        if looksLikeMarkdown(item.text) { return .markdown }
        if let rich = clipboard.richText(for: item) { return .rich(rich) }
        return .plain
    }

    /// Headings, list marks, fences, emphasis or links on enough lines.
    static func looksLikeMarkdown(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2 else { return false }
        var marks = 0
        for line in lines {
            if line.hasPrefix("#"), line.drop(while: { $0 == "#" }).hasPrefix(" ") { marks += 2 }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("> ") || line.hasPrefix("```") { marks += 1 }
            else if line.first?.isNumber == true, line.contains(". ") { marks += 1 }
        }
        if text.components(separatedBy: "**").count >= 3 { marks += 1 }
        if text.range(of: #"\[[^\]]+\]\([^)]+\)"#, options: .regularExpression) != nil { marks += 1 }
        return marks >= 2
    }

    var body: some View {
        let presentation = Self.presentation(of: item, clipboard: clipboard)
        ScrollView {
            content(presentation)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            if presentation.label != nil {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showSource.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Icon(showSource ? "eye" : "chevron.left.forwardslash.chevron.right", size: 10, weight: .bold)
                        Text(showSource ? "Preview" : "Source").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(.black.opacity(0.45), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func content(_ presentation: Presentation) -> some View {
        if showSource {
            source
        } else {
            switch presentation {
            case .rich(let rich):
                Text(AttributedString(Self.themed(rich)))
                    .textSelection(.enabled)
            case .code(let language):
                Text(CodeSnippet.highlighted(item.text.trimmingCharacters(in: .whitespacesAndNewlines), as: language, limit: 20_000))
                    .font(.system(size: compact ? 11 : 12, design: .monospaced))
                    .textSelection(.enabled)
            case .markdown:
                MarkdownView(markdown: item.text)
            case .plain:
                source
            }
        }
    }

    private var source: some View {
        Text(item.text)
            .font(.system(size: compact ? 12 : 13))
            .textSelection(.enabled)
    }

    /// The formatting without its colours: the island is dark, and text meant for a
    /// white page would vanish on it. Fonts, weights, slants, underlines and links stay.
    static func themed(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: copy.length)
        copy.removeAttribute(.backgroundColor, range: whole)
        copy.removeAttribute(.foregroundColor, range: whole)
        copy.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.92), range: whole)
        copy.enumerateAttribute(.link, in: whole) { value, range, _ in
            if value != nil { copy.addAttribute(.foregroundColor, value: NSColor(Color.brand), range: range) }
        }
        return copy
    }
}
