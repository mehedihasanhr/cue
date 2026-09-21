import AppKit
import SwiftUI

/// The subset of Markdown task descriptions use: headings, paragraphs with inline
/// **bold** / *italic* / `code` / links, bullet and numbered lists, quotes, and images.
nonisolated enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case checklist([CheckItem])
    case quote(String)
    /// A fenced code block.
    case code(String)
    case image(alt: String, source: String)
    /// A line that is just a link to an attached file.
    case attachment(name: String, source: String)

    struct CheckItem: Equatable {
        var done: Bool
        var text: String
    }

    /// Splits Markdown text into blocks. Consecutive plain lines join into one
    /// paragraph; a blank line separates blocks.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var checklist: [CheckItem] = []
        var quote: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !checklist.isEmpty { blocks.append(.checklist(checklist)); checklist = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))); quote = [] }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if line == "```" {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(rawLine)
                    code = lines
                }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if let item = checkItem(line) {
                if !paragraph.isEmpty || !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
                checklist.append(item)
            } else if let image = imageLine(line) {
                flush()
                blocks.append(image)
            } else if let attachment = attachmentLine(line) {
                flush()
                blocks.append(attachment)
            } else if line.hasPrefix("#") {
                flush()
                let level = min(3, line.prefix { $0 == "#" }.count)
                blocks.append(.heading(level: level, text: line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("> ") || line == ">" {
                if !paragraph.isEmpty || !bullets.isEmpty || !numbered.isEmpty { flush() }
                quote.append(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") || line.hasPrefix("• ") {
                if !paragraph.isEmpty || !numbered.isEmpty || !checklist.isEmpty || !quote.isEmpty { flush() }
                bullets.append(String(line.dropFirst(2)))
            } else if let item = numberedItem(line) {
                if !paragraph.isEmpty || !bullets.isEmpty || !checklist.isEmpty || !quote.isEmpty { flush() }
                numbered.append(item)
            } else {
                if !bullets.isEmpty || !numbered.isEmpty || !checklist.isEmpty || !quote.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    private static func checkItem(_ line: String) -> CheckItem? {
        guard let match = line.wholeMatch(of: #/[-*+]\s+\[([ xX])\]\s*(.*)/#) else { return nil }
        return CheckItem(done: match.1 != " ", text: String(match.2))
    }

    private static func imageLine(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("!["), let close = line.firstIndex(of: "]"),
              line[line.index(after: close)...].hasPrefix("("), line.hasSuffix(")")
        else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close])
        let source = String(line[line.index(close, offsetBy: 2)..<line.index(before: line.endIndex)])
        return .image(alt: alt, source: source)
    }

    private static func attachmentLine(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              line[line.index(after: close)...].hasPrefix("(klik-file://"), line.hasSuffix(")")
        else { return nil }
        let name = String(line[line.index(after: line.startIndex)..<close])
        let source = String(line[line.index(close, offsetBy: 2)..<line.index(before: line.endIndex)])
        return .attachment(name: name, source: source)
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
    /// Resolves `klik-file://id/name` attachment references to files.
    var attachmentURL: (String) -> URL? = { _ in nil }

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
        case .checklist(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.done ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(item.done ? Color(red: 0x0E / 255, green: 0x4F / 255, blue: 0xEC / 255) : .white.opacity(0.6))
                        inline(item.text)
                            .font(.system(size: 12))
                            .strikethrough(item.done, color: .white.opacity(0.5))
                            .foregroundStyle(item.done ? .white.opacity(0.55) : .white)
                    }
                }
            }
        case .code(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        case .attachment(let name, let source):
            let url = attachmentURL(source)
            Button {
                if let url { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 6) {
                    if let url {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "doc").font(.system(size: 11))
                    }
                    Text(name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    if url != nil { Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5)) }
                }
                .foregroundStyle(url == nil ? .white.opacity(0.5) : .white)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(url == nil ? "File missing" : "Open")
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
