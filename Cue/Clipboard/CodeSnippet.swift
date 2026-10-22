import SwiftUI

/// Tells code from prose on the clipboard, guesses the language, and colours it a
/// little (keywords, strings, comments, numbers) for the card. Heuristics only —
/// good enough to badge a card and pick the fence for "Copy as code block".
nonisolated enum CodeSnippet {
    enum Language: String, CaseIterable {
        case swift, javascript, typescript, python, json, html, css, shell, sql, go, rust, ruby, java, kotlin, php, yaml, markdown, c

        var title: String {
            switch self {
            case .javascript: "JavaScript"
            case .typescript: "TypeScript"
            case .json: "JSON"
            case .html: "HTML"
            case .css: "CSS"
            case .sql: "SQL"
            case .php: "PHP"
            case .yaml: "YAML"
            case .c: "C"
            default: rawValue.capitalized
            }
        }

        /// The word after the fence: ```swift.
        var fence: String {
            switch self {
            case .javascript: "js"
            case .typescript: "ts"
            case .python: "python"
            case .shell: "sh"
            case .markdown: "md"
            default: rawValue
            }
        }

        fileprivate var keywords: Set<String> {
            switch self {
            case .swift: ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "import", "for", "in", "while", "switch", "case", "default", "private", "public", "static", "self", "true", "false", "nil", "throws", "try", "await", "async", "protocol", "extension", "some", "any", "where", "init"]
            case .javascript, .typescript: ["function", "const", "let", "var", "if", "else", "return", "class", "import", "export", "from", "for", "of", "in", "while", "switch", "case", "default", "new", "this", "true", "false", "null", "undefined", "async", "await", "try", "catch", "throw", "interface", "type", "extends", "implements"]
            case .python: ["def", "class", "if", "elif", "else", "return", "import", "from", "for", "in", "while", "try", "except", "with", "as", "lambda", "None", "True", "False", "and", "or", "not", "yield", "async", "await", "pass", "raise", "self"]
            case .go: ["func", "package", "import", "var", "const", "type", "struct", "interface", "if", "else", "for", "range", "return", "go", "defer", "chan", "map", "nil", "true", "false", "switch", "case", "default", "select"]
            case .rust: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "if", "else", "match", "for", "in", "while", "loop", "return", "self", "Self", "true", "false", "async", "await", "where", "as", "dyn"]
            case .ruby: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "return", "require", "do", "while", "yield", "self", "true", "false", "nil", "attr_accessor", "puts"]
            case .java, .kotlin: ["public", "private", "protected", "static", "final", "class", "interface", "fun", "val", "var", "void", "int", "if", "else", "return", "new", "for", "while", "import", "package", "this", "true", "false", "null", "override", "data", "object", "when"]
            case .php: ["function", "echo", "if", "else", "return", "class", "public", "private", "foreach", "as", "new", "null", "true", "false", "use", "namespace", "array"]
            case .c: ["int", "char", "void", "if", "else", "return", "for", "while", "struct", "typedef", "static", "const", "include", "define", "sizeof", "unsigned", "float", "double", "NULL"]
            case .sql: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "JOIN", "LEFT", "INNER", "ON", "GROUP", "BY", "ORDER", "LIMIT", "CREATE", "TABLE", "AND", "OR", "NOT", "NULL", "AS", "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "join", "on", "group", "by", "order", "limit", "create", "table", "and", "or", "not", "null", "as"]
            case .shell: ["if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function", "export", "echo", "return", "local", "in", "set"]
            case .css, .html, .json, .yaml, .markdown: []
            }
        }

        fileprivate var lineComment: String? {
            switch self {
            case .python, .shell, .ruby, .yaml: "#"
            case .sql: "--"
            case .html, .json, .markdown: nil
            default: "//"
            }
        }
    }

    /// The language when the text reads as code, else nil. Needs a few lines or some
    /// unmistakable syntax; prose, URLs and single words never count.
    static func detect(_ text: String) -> Language? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return nil }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let head = lines.first ?? ""

        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
           let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil { return .json }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") && trimmed.contains("</") || trimmed.lowercased().hasPrefix("<!doctype") { return .html }
        if head.hasPrefix("#!") { return head.contains("python") ? .python : .shell }
        if lines.count >= 2, lines.allSatisfy({ $0.isEmpty || $0.hasPrefix("$ ") || $0.hasPrefix("#") || $0.hasPrefix("  ") || $0.contains(" | ") || $0.hasPrefix("cd ") || $0.hasPrefix("git ") || $0.hasPrefix("npm ") || $0.hasPrefix("brew ") || $0.hasPrefix("export ") }),
           lines.contains(where: { $0.hasPrefix("$ ") || $0.hasPrefix("git ") || $0.hasPrefix("npm ") || $0.hasPrefix("brew ") || $0.hasPrefix("cd ") || $0.hasPrefix("export ") }) { return .shell }

        let upper = trimmed.uppercased()
        if ["SELECT ", "INSERT INTO", "UPDATE ", "DELETE FROM", "CREATE TABLE", "ALTER TABLE"].contains(where: upper.hasPrefix) { return .sql }

        // Scoring: language-specific tells, then generic code shape.
        var scores: [Language: Int] = [:]
        func add(_ language: Language, _ points: Int, if tell: Bool) { if tell { scores[language, default: 0] += points } }
        add(.swift, 3, if: text.contains("func ") && (text.contains("let ") || text.contains("var ")) || text.contains("guard ") || text.contains(" -> ") && text.contains("func "))
        add(.swift, 2, if: text.contains("import SwiftUI") || text.contains("import Foundation") || text.contains("@State") || text.contains("struct ") && text.contains(": View"))
        add(.typescript, 3, if: text.contains(": string") || text.contains(": number") || text.contains("interface ") || text.contains("<T>") || text.contains(": boolean"))
        add(.javascript, 3, if: text.contains("const ") || text.contains("=> ") || text.contains("function ") || text.contains("console.log") || text.contains("require("))
        add(.python, 3, if: text.contains("def ") && text.contains(":") || text.contains("import ") && text.contains("self") || text.contains("print(") || text.contains("elif "))
        add(.go, 3, if: text.contains("func ") && (text.contains(":=") || text.contains("package ")) || text.contains("fmt."))
        add(.rust, 3, if: text.contains("fn ") && (text.contains("let mut") || text.contains("->") || text.contains("::")) || text.contains("println!"))
        add(.ruby, 3, if: text.contains("def ") && text.contains("end") && !text.contains("{") || text.contains("puts "))
        add(.kotlin, 3, if: text.contains("fun ") && (text.contains("val ") || text.contains("var ")))
        add(.java, 3, if: text.contains("public class") || text.contains("System.out") || text.contains("public static void"))
        add(.php, 3, if: text.contains("<?php") || text.contains("$this->") || text.contains("echo "))
        add(.c, 2, if: text.contains("#include") || text.contains("printf(") || text.contains("int main("))
        add(.css, 3, if: lines.contains(where: { $0.contains("{") }) && text.contains(":") && text.contains(";") && (text.contains("px") || text.contains("color") || text.contains("margin") || text.contains("display:") || text.contains("font")) && !text.contains("=") )
        add(.yaml, 2, if: lines.count >= 3 && lines.filter({ $0.range(of: #"^\s*[\w-]+:( |$)"#, options: .regularExpression) != nil }).count >= lines.count / 2 && !text.contains("{") && !text.contains(";"))
        add(.markdown, 2, if: lines.filter({ $0.hasPrefix("#") || $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("```") }).count >= 2)

        let shape = text.filter { "{};()=<>[]".contains($0) }.count
        let generic = shape >= max(4, text.count / 30) && lines.count >= 2
        if let best = scores.max(by: { $0.value < $1.value }), best.value >= 3 { return best.key }
        if let best = scores.max(by: { $0.value < $1.value }), best.value >= 2, generic { return best.key }
        if generic, lines.contains(where: { $0.hasSuffix("{") || $0.hasSuffix(";") || $0.hasSuffix("}") }) { return .c }
        return nil
    }

    /// The text inside a Markdown fence.
    static func fenced(_ text: String, as language: Language?) -> String {
        "```\(language?.fence ?? "")\n\(text.trimmingCharacters(in: .newlines))\n```"
    }

    /// A lightly coloured copy for the card: comments dim, strings warm, keywords
    /// bold, numbers cool. Regex passes on at most `limit` characters.
    static func highlighted(_ text: String, as language: Language, limit: Int = 1200) -> AttributedString {
        let source = String(text.prefix(limit))
        var result = AttributedString(source)
        result.foregroundColor = .white.opacity(0.92)
        let ns = source as NSString
        func paint(_ pattern: String, _ style: (inout AttributedSubstring) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(match.range, in: source),
                      let lower = AttributedString.Index(range.lowerBound, within: result),
                      let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
                var sub = result[lower..<upper]
                style(&sub)
            }
        }
        paint(#"\b\d+(\.\d+)?\b"#) { $0.foregroundColor = Color(red: 0.55, green: 0.8, blue: 1) }
        if !language.keywords.isEmpty {
            let words = language.keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            paint(#"\b("# + words + #")\b"#) { $0.foregroundColor = Color(red: 1, green: 0.5, blue: 0.7); $0.font = .system(size: 11, weight: .semibold, design: .monospaced) }
        }
        paint(#""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`"#) { $0.foregroundColor = Color(red: 1, green: 0.8, blue: 0.45) }
        if let comment = language.lineComment {
            paint(NSRegularExpression.escapedPattern(for: comment) + ".*$") { $0.foregroundColor = .white.opacity(0.45) }
        }
        if language != .python, language != .shell, language != .yaml, language != .ruby {
            paint(#"/\*[\s\S]*?\*/"#) { $0.foregroundColor = .white.opacity(0.45) }
        }
        if language == .html { paint(#"</?[\w-]+|/?>"#) { $0.foregroundColor = Color(red: 1, green: 0.5, blue: 0.7) } }
        if language == .css { paint(#"^\s*[.#]?[\w-]+(?=\s*\{)"#) { $0.foregroundColor = Color(red: 1, green: 0.5, blue: 0.7) } }
        if language == .json { paint(#""(?:[^"\\]|\\.)*"(?=\s*:)"#) { $0.foregroundColor = Color(red: 0.75, green: 0.6, blue: 1) } }
        return result
    }
}
