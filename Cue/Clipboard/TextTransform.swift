import Foundation

/// Ways to paste (or copy) a clipboard text other than as it was copied: without
/// formatting, trimmed, in another case, pretty JSON, URL-encoded, and so on.
nonisolated enum TextTransform: String, CaseIterable, Identifiable {
    case plain, trimmed, oneLine, lowercased, uppercased, titleCase, sentenceCase
    case camelCase, snakeCase, kebabCase
    case jsonPretty, jsonMinified, urlEncoded, urlDecoded, markdownPlain, quoted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: "Plain text"
        case .trimmed: "Trimmed"
        case .oneLine: "One line"
        case .lowercased: "lowercase"
        case .uppercased: "UPPERCASE"
        case .titleCase: "Title Case"
        case .sentenceCase: "Sentence case"
        case .camelCase: "camelCase"
        case .snakeCase: "snake_case"
        case .kebabCase: "kebab-case"
        case .jsonPretty: "Pretty JSON"
        case .jsonMinified: "Minified JSON"
        case .urlEncoded: "URL-encoded"
        case .urlDecoded: "URL-decoded"
        case .markdownPlain: "Markdown → plain text"
        case .quoted: "Quoted (> …)"
        }
    }

    /// The transforms that would change (or apply to) this text, in menu order.
    static func applicable(to text: String) -> [TextTransform] {
        allCases.filter { transform in
            guard let result = transform.apply(to: text) else { return false }
            return transform == .plain || result != text
        }
    }

    /// The transformed text, or nil when it does not apply (not JSON, say).
    func apply(to text: String) -> String? {
        switch self {
        case .plain:
            return text
        case .trimmed:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .oneLine:
            return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        case .lowercased:
            return text.lowercased()
        case .uppercased:
            return text.uppercased()
        case .titleCase:
            return text.capitalized
        case .sentenceCase:
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    let lower = line.lowercased()
                    guard let first = lower.firstIndex(where: \.isLetter) else { return lower }
                    return lower[..<first] + lower[first...].prefix(1).uppercased() + lower[lower.index(after: first)...]
                }
                .joined(separator: "\n")
        case .camelCase:
            let words = Self.words(in: text)
            guard !words.isEmpty else { return nil }
            return words.enumerated().map { $0.offset == 0 ? $0.element.lowercased() : $0.element.capitalized }.joined()
        case .snakeCase:
            let words = Self.words(in: text)
            return words.isEmpty ? nil : words.map { $0.lowercased() }.joined(separator: "_")
        case .kebabCase:
            let words = Self.words(in: text)
            return words.isEmpty ? nil : words.map { $0.lowercased() }.joined(separator: "-")
        case .jsonPretty:
            return Self.json(text, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        case .jsonMinified:
            return Self.json(text, options: [.sortedKeys, .withoutEscapingSlashes])
        case .urlEncoded:
            return text.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)
        case .urlDecoded:
            guard text.contains("%") || text.contains("+") else { return nil }
            return text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        case .markdownPlain:
            guard text.contains(where: { "#*_`[>-".contains($0) }) else { return nil }
            // Block syntax line by line (headings, quotes, list markers), then the
            // inline marks; blank lines between paragraphs are dropped.
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
                var body = String(line)
                if let stripped = body.replacing(/^\s*(#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)/, with: "") as String? { body = stripped }
                let inline = (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    .map { String($0.characters) } ?? body
                return inline.trimmingCharacters(in: .whitespaces).isEmpty ? nil : inline
            }
            return lines.joined(separator: "\n")
        case .quoted:
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        }
    }

    /// Words for the identifier cases: splits on whitespace, punctuation and
    /// camelCase humps ("userID" → user, ID).
    private static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character.isLetter || character.isNumber {
                if let previous, previous.isLowercase, character.isUppercase, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func json(_ text: String, options: JSONSerialization.WritingOptions) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              JSONSerialization.isValidJSONObject(object) || object is NSNumber || object is NSString,
              let output = try? JSONSerialization.data(withJSONObject: object, options: options.union(.fragmentsAllowed))
        else { return nil }
        return String(data: output, encoding: .utf8)
    }
}

nonisolated extension CharacterSet {
    /// What may stay as-is in a URL query value (RFC 3986 unreserved).
    static let urlQueryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
