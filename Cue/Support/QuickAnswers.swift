import Foundation

/// Something the search field can work out on the spot, shown as a card to copy:
/// a color in every format, a Unix timestamp as a date, hex ↔ decimal ↔ binary,
/// px ↔ rem, base64 either way, a sum, a fresh UUID, the time now.
nonisolated struct QuickAnswer: Identifiable, Hashable {
    let id: String
    /// What a click copies.
    let value: String
    /// What it is: "RGB", "Date from Unix seconds".
    let label: String
    let symbol: String
    var color: PickedColor? = nil
}

nonisolated enum QuickAnswers {
    static func answers(for rawQuery: String) -> [QuickAnswer] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        // Numbers first: "0b1010" is binary, not the color #0B1010.
        return number(query) ?? color(query) ?? timestamp(query) ?? length(query) ?? base64(query)
            ?? uuid(query) ?? now(query) ?? math(query) ?? []
    }

    // MARK: - Colors

    /// "#0E4FEC", "0e4fec", "#fff": the color in the formats a developer pastes.
    private static let colorFormats: [ColorFormat] = [.hex, .rgb, .hsl, .oklch, .displayP3, .swiftUI]

    private static func color(_ query: String) -> [QuickAnswer]? {
        let body = query.hasPrefix("#") ? String(query.dropFirst()) : query
        // Without a "#", six plain digits are a number, not a color.
        guard query.hasPrefix("#") || (body.count == 6 || body.count == 8) && body.contains(where: \.isLetter),
              let color = PickedColor(hex: query) else { return nil }
        return colorFormats.map { format in
            QuickAnswer(id: "color.\(format.rawValue)", value: format.string(for: color), label: format.title, symbol: "paintpalette", color: color)
        }
    }

    // MARK: - Dates

    private static func timestamp(_ query: String) -> [QuickAnswer]? {
        guard query.allSatisfy(\.isNumber), let raw = Double(query) else { return nil }
        let seconds: Double
        switch query.count {
        case 9...10: seconds = raw
        case 12...13: seconds = raw / 1000
        default: return nil
        }
        let date = Date(timeIntervalSince1970: seconds)
        return [
            QuickAnswer(id: "ts.local", value: date.formatted(date: .abbreviated, time: .shortened),
                        label: query.count > 10 ? "Date from Unix milliseconds" : "Date from Unix seconds", symbol: "calendar"),
            QuickAnswer(id: "ts.iso", value: date.formatted(.iso8601), label: "ISO 8601 (UTC)", symbol: "globe"),
            QuickAnswer(id: "ts.relative", value: date.formatted(.relative(presentation: .named)), label: "From now", symbol: "clock.arrow.circlepath"),
        ]
    }

    private static func now(_ query: String) -> [QuickAnswer]? {
        guard ["now", "time", "today", "date"].contains(query.lowercased()) else { return nil }
        let date = Date()
        return [
            QuickAnswer(id: "now.unix", value: String(Int(date.timeIntervalSince1970)), label: "Unix seconds", symbol: "number"),
            QuickAnswer(id: "now.iso", value: date.formatted(.iso8601), label: "ISO 8601 (UTC)", symbol: "globe"),
            QuickAnswer(id: "now.date", value: date.formatted(date: .complete, time: .omitted), label: "Today", symbol: "calendar"),
            QuickAnswer(id: "now.time", value: date.formatted(date: .omitted, time: .standard), label: "Time", symbol: "clock"),
        ]
    }

    // MARK: - Numbers

    /// "0x1F", "0b1010", "255": the same number in the other bases.
    private static func number(_ query: String) -> [QuickAnswer]? {
        let lower = query.lowercased()
        let value: UInt64
        if lower.hasPrefix("0x"), let hex = UInt64(lower.dropFirst(2), radix: 16) {
            value = hex
        } else if lower.hasPrefix("0b"), let binary = UInt64(lower.dropFirst(2), radix: 2) {
            value = binary
        } else if lower.allSatisfy(\.isNumber), lower.count <= 8, let decimal = UInt64(lower) {
            value = decimal
        } else {
            return nil
        }
        return [
            QuickAnswer(id: "n.dec", value: String(value), label: "Decimal", symbol: "number"),
            QuickAnswer(id: "n.hex", value: "0x" + String(value, radix: 16).uppercased(), label: "Hex", symbol: "number"),
            QuickAnswer(id: "n.bin", value: "0b" + String(value, radix: 2), label: "Binary", symbol: "number"),
            QuickAnswer(id: "n.oct", value: "0o" + String(value, radix: 8), label: "Octal", symbol: "number"),
        ].filter { $0.value.lowercased() != lower }
    }

    /// "256px" ↔ rem/em at 16 px, and points.
    private static func length(_ query: String) -> [QuickAnswer]? {
        guard let match = query.lowercased().wholeMatch(of: /(\d+(?:\.\d+)?)\s*(px|rem|em|pt)/),
              let amount = Double(match.1) else { return nil }
        let px: Double = switch match.2 {
        case "px": amount
        case "pt": amount * 4 / 3
        default: amount * 16
        }
        return [
            QuickAnswer(id: "len.px", value: "\(plain(px))px", label: "Pixels", symbol: "ruler"),
            QuickAnswer(id: "len.rem", value: "\(plain(px / 16))rem", label: "rem at 16 px", symbol: "ruler"),
            QuickAnswer(id: "len.em", value: "\(plain(px / 16))em", label: "em at 16 px", symbol: "ruler"),
            QuickAnswer(id: "len.pt", value: "\(plain(px * 3 / 4))pt", label: "Points (CSS)", symbol: "ruler"),
        ].filter { $0.value != query.lowercased().replacingOccurrences(of: " ", with: "") }
    }

    // MARK: - Text

    /// "b64 hello" encodes; "decode aGVsbG8=" (or plain base64) decodes.
    private static func base64(_ query: String) -> [QuickAnswer]? {
        let lower = query.lowercased()
        for prefix in ["base64 ", "b64 ", "encode "] where lower.hasPrefix(prefix) {
            let text = String(query.dropFirst(prefix.count))
            guard !text.isEmpty else { return nil }
            return [QuickAnswer(id: "b64.enc", value: Data(text.utf8).base64EncodedString(), label: "Base64", symbol: "lock.doc")]
        }
        let candidate = lower.hasPrefix("decode ") ? String(query.dropFirst(7)) : query
        guard candidate.count >= 8, candidate.count % 4 == 0,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || "+/=".contains($0) }),
              candidate.contains(where: \.isLetter),
              let data = Data(base64Encoded: candidate), let text = String(data: data, encoding: .utf8),
              !text.isEmpty, text.allSatisfy({ !$0.isASCII || $0.isASCII && ($0.asciiValue! >= 32 || $0.isNewline) })
        else { return nil }
        return [QuickAnswer(id: "b64.dec", value: text, label: "Decoded from Base64", symbol: "lock.open.doc")]
    }

    private static func uuid(_ query: String) -> [QuickAnswer]? {
        guard ["uuid", "guid"].contains(query.lowercased()) else { return nil }
        let id = UUID().uuidString
        return [
            QuickAnswer(id: "uuid.upper", value: id, label: "New UUID", symbol: "number.square"),
            QuickAnswer(id: "uuid.lower", value: id.lowercased(), label: "New UUID, lowercase", symbol: "number.square"),
        ]
    }

    // MARK: - Arithmetic

    /// "12*8", "(3+4)/2", "2^10", "17 % 5".
    private static func math(_ query: String) -> [QuickAnswer]? {
        let allowed = Set("0123456789.+-*/()%^ ×÷")
        guard query.allSatisfy(allowed.contains), query.contains(where: \.isNumber),
              query.contains(where: { "+-*/%^×÷".contains($0) }),
              let result = { var calculator = Calculator(query); return calculator.evaluate() }(), result.isFinite else { return nil }
        return [QuickAnswer(id: "math", value: plain(result), label: "= \(query)", symbol: "function")]
    }

    /// A small recursive-descent evaluator (NSExpression throws Objective-C
    /// exceptions on bad input, which Swift cannot catch).
    private struct Calculator {
        private var chars: [Character]
        private var index = 0

        init(_ text: String) {
            chars = Array(text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").filter { !$0.isWhitespace })
        }

        mutating func evaluate() -> Double? {
            guard let value = sum(), index == chars.count else { return nil }
            return value
        }

        private mutating func sum() -> Double? {
            guard var left = product() else { return nil }
            while index < chars.count, chars[index] == "+" || chars[index] == "-" {
                let op = chars[index]; index += 1
                guard let right = product() else { return nil }
                left = op == "+" ? left + right : left - right
            }
            return left
        }

        private mutating func product() -> Double? {
            guard var left = power() else { return nil }
            while index < chars.count, "*/%".contains(chars[index]) {
                let op = chars[index]; index += 1
                guard let right = power() else { return nil }
                switch op {
                case "*": left *= right
                case "/": left /= right
                default: left = left.truncatingRemainder(dividingBy: right)
                }
            }
            return left
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if index < chars.count, chars[index] == "^" {
                index += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if index < chars.count, chars[index] == "-" { index += 1; return unary().map { -$0 } }
            if index < chars.count, chars[index] == "+" { index += 1; return unary() }
            return atom()
        }

        private mutating func atom() -> Double? {
            guard index < chars.count else { return nil }
            if chars[index] == "(" {
                index += 1
                guard let inner = sum(), index < chars.count, chars[index] == ")" else { return nil }
                index += 1
                return inner
            }
            let start = index
            while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
            guard index > start else { return nil }
            return Double(String(chars[start..<index]))
        }
    }

    // MARK: - Formatting

    /// A number without trailing zeros: "16", "2.5", "0.3333".
    private static func plain(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)).grouping(.never))
    }
}
