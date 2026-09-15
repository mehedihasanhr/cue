import AppKit
import SwiftUI

/// The subset of Markdown task descriptions use: headings, paragraphs with inline
/// **bold** / *italic* / `code` / links, bullet and numbered lists, quotes, and images.
nonisolated enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case quote(String)
    case image(alt: String, source: String)

    /// Splits Markdown text into blocks. Consecutive plain lines join into one
    /// paragraph; a blank line separates blocks.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quote: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))); quote = [] }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let image = imageLine(line) {
                flush()
                blocks.append(image)
            } else if line.hasPrefix("#") {
                flush()
                let level = min(3, line.prefix { $0 == "#" }.count)
                blocks.append(.heading(level: level, text: line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("> ") || line == ">" {
                if !paragraph.isEmpty || !bullets.isEmpty || !numbered.isEmpty { flush() }
                quote.append(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                if !paragraph.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
                bullets.append(String(line.dropFirst(2)))
            } else if let item = numberedItem(line) {
                if !paragraph.isEmpty || !bullets.isEmpty || !quote.isEmpty { flush() }
                numbered.append(item)
            } else {
                if !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func imageLine(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("!["), let close = line.firstIndex(of: "]"),
              line[line.index(after: close)...].hasPrefix("("), line.hasSuffix(")")
        else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close])
        let source = String(line[line.index(close, offsetBy: 2)..<line.index(before: line.endIndex)])
        return .image(alt: alt, source: source)
    }

    private static func numberedItem(_ line: String) -> String? {
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), dot != line.startIndex,
              line[..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].hasPrefix(" ")
        else { return nil }
        return String(line[line.index(dot, offsetBy: 2)...])
    }
}

/// Renders a task description.
struct MarkdownView: View {
    let markdown: String
    /// Resolves `klik://name.png` image references to files.
    var imageURL: (String) -> URL? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: level == 1 ? 16 : level == 2 ? 14 : 12.5, weight: .bold))
                .padding(.top, 2)
        case .paragraph(let text):
            inline(text).font(.system(size: 12))
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                        inline(item).font(.system(size: 12))
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).frame(minWidth: 16, alignment: .trailing)
                        inline(item).font(.system(size: 12))
                    }
                }
            }
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(red: 0x0E / 255, green: 0x4F / 255, blue: 0xEC / 255)).frame(width: 3)
                inline(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).italic()
            }
            .padding(.vertical, 2)
        case .image(let alt, let source):
            if let url = imageURL(source) ?? (source.hasPrefix("/") ? URL(fileURLWithPath: source) : nil), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help(alt)
            } else {
                Label(alt.isEmpty ? "Image" : alt, systemImage: "photo").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    /// Inline Markdown (bold, italic, code, links) through Foundation's parser.
    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
