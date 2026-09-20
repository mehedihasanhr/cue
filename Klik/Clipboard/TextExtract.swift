import Foundation

/// Pulls the useful bits out of a text: links, e-mail addresses, numbers — for
/// "Copy URLs" on a clipboard entry or a screenshot's text.
nonisolated enum TextExtract {
    enum Kind: CaseIterable {
        case urls, emails, numbers

        var title: String {
            switch self {
            case .urls: "URLs"
            case .emails: "E-mail addresses"
            case .numbers: "Numbers"
            }
        }
    }

    static func extract(_ kind: Kind, from text: String) -> [String] {
        var found: [String] = []
        switch kind {
        case .urls:
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, let range = Range(match.range, in: text) else { continue }
                if url.scheme == "mailto" { continue }
                found.append(String(text[range]))
            }
        case .emails:
            let pattern = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/
            found = text.matches(of: pattern).map { String($0.output) }
        case .numbers:
            // Tokens that are numbers: digits with separators, optional sign, decimals, %.
            let pattern = /[-+]?\d[\d,]*(?:\.\d+)?%?/
            for token in text.split(whereSeparator: { $0.isWhitespace || "()[]{}<>\"';:".contains($0) }) {
                guard let match = token.wholeMatch(of: pattern) ?? String(token).trimmingCharacters(in: .punctuationCharacters).wholeMatch(of: pattern) else { continue }
                found.append(String(match.output))
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// "3 URLs, 1 e-mail address" — what the text holds, for a hint.
    static func summary(of text: String) -> String {
        let parts: [String] = Kind.allCases.compactMap { kind in
            let count = extract(kind, from: text).count
            guard count > 0, kind != .numbers || count >= 3 else { return nil }
            let name = count == 1 ? String(kind.title.dropLast(kind.title.hasSuffix("es") ? 2 : 1)) : kind.title
            return "\(count) \(name)"
        }
        return parts.joined(separator: ", ")
    }
}
