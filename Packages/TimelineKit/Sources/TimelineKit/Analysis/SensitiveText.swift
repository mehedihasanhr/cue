import CoreGraphics
import Foundation

/// What kind of thing a piece of text on screen gives away.
public enum SensitiveKind: String, Codable, Sendable, CaseIterable {
    case email
    case phone
    case card
    /// A bank account: an IBAN, or digits after a word that says they are an account.
    case account
    /// An API key, a token, a private key: anything that lets somebody in as somebody else.
    case secret
    case ipAddress
    /// A password, or the dots a password field shows instead of one.
    case password

    /// What the review sheet calls it.
    public var title: String {
        switch self {
        case .email: "Email address"
        case .phone: "Phone number"
        case .card: "Card number"
        case .account: "Account number"
        case .secret: "Key or token"
        case .ipAddress: "IP address"
        case .password: "Password"
        }
    }
}

/// One stretch of a line of text that should not be shown.
public struct SensitiveMatch: Equatable, Sendable {
    public var kind: SensitiveKind
    /// Where it is in the line it was found in, so the recogniser can say where it is on
    /// the picture rather than where the whole line is.
    public var range: Range<String.Index>
    public var text: String

    public init(kind: SensitiveKind, range: Range<String.Index>, text: String) {
        self.kind = kind
        self.range = range
        self.text = text
    }
}

/// Finds the sensitive things in text read off the screen.
///
/// # What it is for, and what it is not
///
/// It reads what text recognition makes of a screen recording: short lines, a word or a
/// sentence each, with the occasional misread character. It is tuned to be sure rather
/// than eager, because every false alarm is a line in the review sheet somebody has to
/// untick, and a sheet full of version numbers and dates teaches people to hide
/// everything without looking. So each kind is recognised by its shape *and* by what
/// makes it more than a shape:
///
/// - a card number by its issuer's first digits and the Luhn check digit,
/// - an IBAN by its ISO 7064 check digits,
/// - a phone number only with a leading `+`, a trunk `0`, a North American grouping, or a
///   word such as "Phone" in front — a bare run of digits is an order number far more
///   often than a telephone,
/// - a key by a prefix a service puts on its keys, or by being long, random-looking and
///   mixing letters with digits the way nothing written by a person does,
/// - an IP address only when it is not a version number and not a mask or loopback.
///
/// Numbers straight after a currency sign are never anything but prices.
public enum SensitiveText {
    /// Every sensitive stretch of one line, the most specific kind winning where two
    /// overlap: a JWT is a key before it is a run of letters, a card number is a card
    /// before it is a phone number.
    public static func matches(in line: String) -> [SensitiveMatch] {
        var found: [SensitiveMatch] = []
        func add(_ candidates: [SensitiveMatch]) {
            for candidate in candidates where !found.contains(where: { $0.range.overlaps(candidate.range) }) {
                found.append(candidate)
            }
        }
        add(passwordDots(in: line))
        add(prefixedSecrets(in: line))
        add(labelled(in: line))
        add(emails(in: line))
        add(cards(in: line))
        add(ibans(in: line))
        add(accounts(in: line))
        add(ipAddresses(in: line))
        add(phones(in: line))
        add(randomTokens(in: line))
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: - Lines side by side

    /// One line of recognised text and where it is: any rectangle in any space, as long
    /// as every line handed in together uses the same one with y growing downwards.
    public struct Line: Equatable, Sendable {
        public var text: String
        public var box: CGRect

        public init(text: String, box: CGRect) {
            self.text = text
            self.box = box
        }
    }

    /// A sensitive value on a line of its own, found because of the line beside it.
    public struct Value: Equatable, Sendable {
        /// Which of the lines handed in.
        public var line: Int
        public var kind: SensitiveKind
    }

    /// Values recognised by their label on a neighbouring line: `Password` at the left of
    /// a form and `hunter2` in the field to its right come back from text recognition as
    /// two lines, and neither says anything on its own.
    ///
    /// Only to the right, on the same row, and close — a label above a field is also
    /// common, but "the line under the word Password" is far too often the next setting.
    public static func labelledValues(in lines: [Line]) -> [Value] {
        var values: [Value] = []
        for (index, label) in lines.enumerated() {
            guard let kind = trailingLabel(label.text) else { continue }
            let height = max(label.box.height, 1e-9)
            let beside = lines.enumerated().filter { other in
                other.offset != index
                    && other.element.box.minX >= label.box.maxX - height * 0.5
                    && other.element.box.minX - label.box.maxX <= height * 6
                    && abs(other.element.box.midY - label.box.midY) <= height * 0.5
            }
            guard let value = beside.min(by: { $0.element.box.minX < $1.element.box.minX }) else { continue }
            let text = value.element.text.trimmingCharacters(in: .whitespaces)
            guard isPlausibleValue(text, for: kind), trailingLabel(text) == nil else { continue }
            values.append(Value(line: value.offset, kind: kind))
        }
        return values
    }

    /// The kind a line's last words say the next thing is — "Password", "API key:" — or
    /// `nil` when they say nothing of the sort.
    static func trailingLabel(_ text: String) -> SensitiveKind? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = Pattern.trailingLabel?.firstMatch(in: text, range: range),
              let word = Range(match.range(at: 1), in: text) else { return nil }
        return labelKind(String(text[word]))
    }

    // MARK: - Checks

    /// The Luhn check every payment card number carries in its last digit.
    public static func luhn(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count, values.count >= 2 else { return false }
        var sum = 0
        for (offset, digit) in values.reversed().enumerated() {
            if offset.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }

    /// The ISO 7064 mod-97 check an IBAN carries in its third and fourth characters.
    public static func ibanChecksum(_ iban: String) -> Bool {
        let compact = iban.filter { !$0.isWhitespace }.uppercased()
        guard compact.count >= 15, compact.count <= 34, compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in rearranged {
            if let digit = character.wholeNumberValue {
                remainder = (remainder * 10 + digit) % 97
            } else if let ascii = character.asciiValue {
                remainder = (remainder * 100 + Int(ascii) - 55) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    /// Shannon entropy in bits per character: about 4.2 for 24 random letters and digits,
    /// about 3 for English, 0 for one character repeated.
    public static func entropy(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let total = Double(text.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

    // MARK: - Showing it without showing it

    /// Enough of the text to recognise which one it is, and not enough to use it:
    /// `j•••@example.com`, `•••• 4242`, `sk-proj-•••Qx`.
    public static func obscured(_ text: String, kind: SensitiveKind) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .email:
            guard let at = text.firstIndex(of: "@"), let first = text.first else { return "•••" }
            return "\(first)•••\(text[at...].filter { !$0.isWhitespace })"
        case .phone:
            let total = text.filter(\.isNumber).count
            var seen = 0
            return String(text.map { character -> Character in
                guard character.isNumber else { return character }
                seen += 1
                return seen > total - 2 ? character : "•"
            })
        case .card:
            return "•••• \(String(text.filter(\.isNumber).suffix(4)))"
        case .account:
            let compact = text.filter { $0.isLetter || $0.isNumber }
            let head = compact.first?.isLetter == true ? String(compact.prefix(2)) : ""
            return "\(head)•••\(String(compact.suffix(4)))"
        case .secret:
            let head = secretPrefix(of: text) ?? String(text.prefix(4))
            return text.count > head.count + 6 ? "\(head)•••\(String(text.suffix(2)))" : "\(head)•••"
        case .ipAddress:
            if text.contains(":"), !text.contains(".") {
                return "\(text.split(separator: ":").first ?? ""):•••"
            }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 4 else { return "•••" }
            return "\(parts[0]).\(parts[1]).•.•"
        case .password:
            return "••••••••"
        }
    }

    /// The same text however it was read: what grouping compares across frames, where one
    /// reading has a space the next one lost.
    public static func normalised(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace })
    }

    // MARK: - The kinds

    /// Bullets or asterisks where a password field hides what was typed. Four in a group
    /// are the start of a hidden card number (`•••• 4242`), not a password, so it takes
    /// five bullets or six asterisks, not followed by the digits a hidden number shows.
    ///
    /// Text recognition reads a field's bullets as full stops as often as not — `•......•`,
    /// or `........` on its own. Full stops alone are also an ellipsis or a table of
    /// contents' leaders, so a run of nothing but full stops counts only when it is the
    /// whole line or follows the word "Password".
    static func passwordDots(in line: String) -> [SensitiveMatch] {
        matches(of: Pattern.dots, in: line, kind: .password) { text, range in
            let after = line[range.upperBound...].drop(while: { $0 == " " })
            guard !(after.first?.isNumber ?? false) else { return false }
            guard text.allSatisfy({ $0 == "." }) else { return true }
            let before = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            return (before.isEmpty && after.trimmingCharacters(in: .whitespaces).isEmpty) || trailingLabel(before) == .password
        }
    }

    static func prefixedSecrets(in line: String) -> [SensitiveMatch] {
        matches(of: Pattern.prefixedSecret, in: line, kind: .secret)
            + matches(of: Pattern.bearer, in: line, kind: .secret, group: 1)
    }

    /// `password: hunter2`, `api_key = "…"`, `PIN 4821` — whatever follows a word that
    /// says what it is.
    static func labelled(in line: String) -> [SensitiveMatch] {
        let range = NSRange(line.startIndex..., in: line)
        return (Pattern.labelledValue?.matches(in: line, range: range) ?? []).compactMap { match in
            guard let labelRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line),
                  let kind = labelKind(String(line[labelRange])) else { return nil }
            let value = String(line[valueRange])
            guard isPlausibleValue(value, for: kind), !afterCurrency(line, valueRange) else { return nil }
            return SensitiveMatch(kind: kind, range: valueRange, text: value)
        }
    }

    static func emails(in line: String) -> [SensitiveMatch] {
        matches(of: Pattern.email, in: line, kind: .email) { text, _ in
            guard let at = text.firstIndex(of: "@") else { return false }
            let local = text[..<at].trimmingCharacters(in: .whitespaces).lowercased()
            let domain = text[text.index(after: at)...].trimmingCharacters(in: .whitespaces).lowercased()
            // `icon@2x.png` is a file, and `git@github.com` is how everybody's clone URL
            // starts: neither is anybody's address.
            if domain.range(of: #"^\d+(\.\d+)?x\."#, options: .regularExpression) != nil { return false }
            if local == "git" { return false }
            let tld = domain.split(separator: ".").last.map(String.init) ?? ""
            return !Self.fileExtensions.contains(tld)
        }
    }

    static func cards(in line: String) -> [SensitiveMatch] {
        matches(of: Pattern.card, in: line, kind: .card) { text, range in
            guard !afterCurrency(line, range) else { return false }
            let digits = text.filter(\.isNumber)
            guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
            // Grouped the way cards are printed, or not grouped at all: `1 2 3 4 …` or a
            // phone number's `(555) 123` is not a card.
            let groups = text.split(whereSeparator: { $0 == " " || $0 == "-" })
            if groups.count > 1 {
                guard groups.first?.count == 4, groups.allSatisfy({ (3...6).contains($0.count) }) else { return false }
            }
            return hasCardIssuer(digits) && luhn(digits)
        }
    }

    static func ibans(in line: String) -> [SensitiveMatch] {
        let hasLabel = line.range(of: "iban", options: .caseInsensitive) != nil
        let range = NSRange(line.startIndex..., in: line)
        return (Pattern.iban?.matches(in: line, range: range) ?? []).compactMap { match in
            guard let whole = Range(match.range, in: line) else { return nil }
            // The pattern runs on into whatever capitals follow, so the IBAN is the part of
            // it as long as its country says, ending at the end of a group.
            let text = line[whole]
            let country = String(text.prefix(2))
            let lengths = Self.ibanLengths[country].map { [$0] } ?? Array((15...34).reversed())
            for length in lengths {
                guard let end = index(afterAlphanumerics: length, in: line, from: whole.lowerBound),
                      end <= whole.upperBound else { continue }
                if end < line.endIndex, line[end].isLetter || line[end].isNumber { continue }
                let candidate = String(line[whole.lowerBound..<end])
                if ibanChecksum(candidate) || (hasLabel && Self.ibanLengths[country] != nil) {
                    return SensitiveMatch(kind: .account, range: whole.lowerBound..<end, text: candidate)
                }
            }
            return nil
        }
    }

    static func accounts(in line: String) -> [SensitiveMatch] {
        matches(of: Pattern.account, in: line, kind: .account, group: 1) { text, _ in
            text.filter(\.isNumber).count >= 6
        }
    }

    static func ipAddresses(in line: String) -> [SensitiveMatch] {
        let v4 = matches(of: Pattern.ipv4, in: line, kind: .ipAddress) { text, range in
            let address = text.split(whereSeparator: { $0 == ":" || $0 == "/" }).first ?? ""
            let octets = address.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return false }
            // Nobody's: the loopback, the unspecified address, and the netmasks.
            if octets[0] == 127 || octets[0] == 255 || octets.allSatisfy({ $0 == 0 }) { return false }
            // `v1.2.3.4`, `Version 10.0.0.1`, `Build 2.1.0.4`: a version, however it looks.
            let before = line[..<range.lowerBound].suffix(12).lowercased()
            return before.range(of: #"\b(v|version|ver\.?|build|release)\s*$"#, options: .regularExpression) == nil
        }
        let v6 = matches(of: Pattern.ipv6, in: line, kind: .ipAddress) { text, _ in
            let groups = text.split(separator: ":", omittingEmptySubsequences: false)
            let filled = groups.filter { !$0.isEmpty }
            guard filled.count >= 3, text.contains("::") || groups.count == 8 else { return false }
            // Timecodes and hardware addresses: every group two characters or fewer.
            return filled.contains { $0.count > 2 }
        }
        return v4 + v6
    }

    static func phones(in line: String) -> [SensitiveMatch] {
        let international = matches(of: Pattern.internationalPhone, in: line, kind: .phone) { text, _ in
            (8...15).contains(text.filter(\.isNumber).count) && wellSeparated(text)
        }
        let northAmerican = matches(of: Pattern.northAmericanPhone, in: line, kind: .phone) { _, range in
            !afterCurrency(line, range)
        }
        let trunk = matches(of: Pattern.trunkPhone, in: line, kind: .phone) { text, range in
            (10...11).contains(text.filter(\.isNumber).count) && !afterCurrency(line, range)
        }
        let labelled = matches(of: Pattern.labelledPhone, in: line, kind: .phone, group: 1) { text, _ in
            (6...15).contains(text.filter(\.isNumber).count) && wellSeparated(text)
        }
        return international + northAmerican + trunk + labelled
    }

    /// A long run of letters and digits that nothing a person typed looks like.
    ///
    /// Base64 and base62 keys come out of a random generator, so they mix upper case, lower
    /// case and digits all the way along and rarely repeat a character. Names and file
    /// paths are words glued together: long runs of letters, digits in one place, and the
    /// separators between the words. Hex on its own is left alone — commit hashes,
    /// checksums and ids are hex, fill every developer's screen, and give nothing away; a
    /// hex key gets found by its label instead.
    static func randomTokens(in line: String) -> [SensitiveMatch] {
        matches(of: Pattern.token, in: line, kind: .secret) { text, _ in
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "="))
            guard trimmed.count >= 24 else { return false }
            if trimmed.range(of: #"^[0-9a-fA-F-]+$"#, options: .regularExpression) != nil { return false }
            let segments = trimmed.split(whereSeparator: { "_-/+".contains($0) })
            guard let longest = segments.max(by: { $0.count < $1.count }), longest.count >= 16 else { return false }
            guard longest.contains(where: \.isUppercase), longest.contains(where: \.isLowercase),
                  longest.filter(\.isNumber).count >= 2 else { return false }
            var switches = 0
            var previous: Bool?
            for character in longest where character.isLetter || character.isNumber {
                let isDigit = character.isNumber
                if let previous, previous != isDigit { switches += 1 }
                previous = isDigit
            }
            return switches >= 4 && entropy(trimmed) >= 3.8
        }
    }

    // MARK: - Helpers

    private static func matches(of pattern: NSRegularExpression?, in line: String, kind: SensitiveKind,
                                group: Int = 0,
                                accept: (String, Range<String.Index>) -> Bool = { _, _ in true }) -> [SensitiveMatch] {
        guard let pattern else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return pattern.matches(in: line, range: range).compactMap { match in
            guard let found = Range(match.range(at: group), in: line) else { return nil }
            let text = String(line[found])
            guard accept(text, found) else { return nil }
            return SensitiveMatch(kind: kind, range: found, text: text)
        }
    }

    /// Straight after `$`, `€`, `£` or `¥`: a price.
    private static func afterCurrency(_ line: String, _ range: Range<String.Index>) -> Bool {
        let before = line[..<range.lowerBound].last { !$0.isWhitespace }
        return before.map { "$€£¥₹".contains($0) } ?? false
    }

    /// Single separators between groups of digits, as a number is written — not a list of
    /// numbers run together with commas and double spaces.
    private static func wellSeparated(_ text: String) -> Bool {
        text.range(of: #"[ .\-]{2,}"#, options: .regularExpression) == nil
    }

    private static func index(afterAlphanumerics count: Int, in line: String, from start: String.Index) -> String.Index? {
        var remaining = count
        var index = start
        while index < line.endIndex {
            if line[index].isLetter || line[index].isNumber {
                remaining -= 1
                if remaining == 0 { return line.index(after: index) }
            } else if line[index] != " " {
                return nil
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// The first digits a real card issuer uses: a sixteen-digit order number that happens
    /// to pass Luhn (one in ten do) almost never also starts like a card.
    static func hasCardIssuer(_ digits: String) -> Bool {
        func prefix(_ n: Int) -> Int { Int(digits.prefix(n)) ?? -1 }
        let length = digits.count
        switch digits.first {
        case "4": return [13, 16, 19].contains(length) // Visa
        case "3":
            if [34, 37].contains(prefix(2)) { return length == 15 } // American Express
            if (3528...3589).contains(prefix(4)) { return (16...19).contains(length) } // JCB
            if [36, 38, 39].contains(prefix(2)) || (300...305).contains(prefix(3)) { return (14...19).contains(length) } // Diners
            return false
        case "5":
            if (51...55).contains(prefix(2)) { return length == 16 } // Mastercard
            return [50, 56, 57, 58].contains(prefix(2)) && (12...19).contains(length) // Maestro
        case "2": return (2221...2720).contains(prefix(4)) && length == 16 // Mastercard
        case "6": return (13...19).contains(length) // Discover, UnionPay, Maestro, RuPay
        default: return false
        }
    }

    /// What a label says the value after it is.
    private static func labelKind(_ label: String) -> SensitiveKind? {
        let word = label.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        if ["password", "passwd", "pwd", "pass", "passcode", "passphrase", "pin"].contains(word) { return .password }
        if word == "iban" || word.hasPrefix("account") || word == "acct" { return .account }
        return .secret
    }

    /// Whether what follows a label could be the value it labels. A password is anything
    /// that is not a word of the interface — `Password: Required`, `Password  Change…` —
    /// so a capitalised plain word is taken for a button or a note.
    private static func isPlausibleValue(_ value: String, for kind: SensitiveKind) -> Bool {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard value.count >= 4, !value.contains(" ") || kind == .account else { return false }
        if value.hasSuffix("…") || value.hasSuffix("...") { return false }
        switch kind {
        case .password:
            let first = value.first
            let rest = value.dropFirst()
            let interfaceWord = first?.isUppercase == true && rest.allSatisfy(\.isLowercase)
            return !interfaceWord
        case .account:
            return value.filter(\.isNumber).count >= 6
        default:
            // A key is not a word either: at least one digit, or long.
            return value.count >= 8 && (value.contains(where: \.isNumber) || value.count >= 16)
        }
    }

    private static func secretPrefix(of text: String) -> String? {
        let known = ["sk-proj-", "sk-ant-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "sk-",
                     "github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "glpat-", "xoxb-", "xoxp-",
                     "xoxa-", "xoxs-", "xoxr-", "xoxo-", "AKIA", "ASIA", "AIza", "SG.", "hf_", "npm_",
                     "pypi-", "eyJ", "-----BEGIN"]
        return known.first { text.hasPrefix($0) }
    }

    static let fileExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "pdf", "heic", "webp", "tiff",
                                              "swift", "js", "ts", "css", "html", "json", "txt", "md",
                                              "py", "rb", "go", "rs", "java", "mov", "mp4", "zip"]

    /// How long each country's IBAN is. A country missing from here is checked against
    /// every legal length, by its check digits alone.
    static let ibanLengths: [String: Int] = [
        "AD": 24, "AE": 23, "AL": 28, "AT": 20, "AZ": 28, "BA": 20, "BE": 16, "BG": 22, "BH": 22,
        "BR": 29, "CH": 21, "CR": 22, "CY": 28, "CZ": 24, "DE": 22, "DK": 18, "DO": 28, "EE": 20,
        "EG": 29, "ES": 24, "FI": 18, "FO": 18, "FR": 27, "GB": 22, "GE": 22, "GI": 23, "GL": 18,
        "GR": 27, "GT": 28, "HR": 21, "HU": 28, "IE": 22, "IL": 23, "IS": 26, "IT": 27, "JO": 30,
        "KW": 30, "KZ": 20, "LB": 28, "LI": 21, "LT": 20, "LU": 20, "LV": 21, "MC": 27, "MD": 24,
        "ME": 22, "MK": 19, "MR": 27, "MT": 31, "MU": 30, "NL": 18, "NO": 15, "PK": 24, "PL": 28,
        "PS": 29, "PT": 25, "QA": 29, "RO": 24, "RS": 22, "SA": 24, "SE": 24, "SI": 19, "SK": 24,
        "SM": 27, "TN": 24, "TR": 26, "UA": 29, "VG": 24, "XK": 20,
    ]

    /// Compiled once. Optional rather than forced: a pattern that does not compile finds
    /// nothing, and `SensitiveTextTests` fails on it, rather than the editor crashing.
    enum Pattern {
        static func make(_ pattern: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern)
        }

        static var all: [NSRegularExpression?] {
            [dots, prefixedSecret, bearer, labelledValue, trailingLabel, email, card, iban, account, ipv4, ipv6,
             internationalPhone, northAmericanPhone, trunkPhone, labelledPhone, token]
        }

        static let dots = make(#"[•●∙⋅◦·.]{5,}|\*{6,}"#)
        static let prefixedSecret = make(
            #"(?<![A-Za-z0-9_-])(?:"#
                + #"sk-(?:proj-|ant-(?:api\d{2}-)?|live-|test-)?[A-Za-z0-9_-]{20,}"#
                + #"|(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#
                + #"|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}"#
                + #"|(?:AKIA|ASIA|AGPA|AIDA|AROA)[A-Z0-9]{16}"#
                + #"|xox[abposr]-[A-Za-z0-9-]{10,}"#
                + #"|AIza[0-9A-Za-z_-]{35}"#
                + #"|glpat-[A-Za-z0-9_-]{20,}"#
                + #"|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#
                + #"|hf_[A-Za-z0-9]{30,}|npm_[A-Za-z0-9]{36}|pypi-[A-Za-z0-9_-]{50,}"#
                + #"|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|eyJ[A-Za-z0-9_-]{30,}"#
                + #"|-----BEGIN [A-Z ]*PRIVATE KEY-----"#
                + #")"#)
        static let bearer = make(#"(?i)\bbearer\s+([A-Za-z0-9._~+/-]{16,}=*)"#)
        static let labelWords = #"api[_ -]?key|apikey|secret(?:[_ -]?key)?|access[_ -]?token|auth[_ -]?token|refresh[_ -]?token|token|client[_ -]?secret|private[_ -]?key|password|passwd|pwd|passcode|passphrase|pass|pin"#
        static let labelledValue = make(#"(?i)\b("# + labelWords + #")\b\s*[:=]\s*["'`]?([^\s"'`,;]{4,})"#)
        static let trailingLabel = make(#"(?i)\b("# + labelWords + #"|iban|account(?: no\.?| number| #)?|acct)\s*:?\s*$"#)
        static let email = make(
            #"(?<![A-Za-z0-9._%+-])[A-Za-z0-9][A-Za-z0-9._%+-]{0,63} ?@ ?[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?"#
                + #"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)*\.[A-Za-z]{2,24}(?![A-Za-z0-9-])"#)
        static let card = make(#"(?<![\d.,+-])\d(?:[ -]?\d){12,18}(?![\d,-]|\.\d)"#)
        static let iban = make(#"(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,32}"#)
        static let account = make(#"(?i)\b(?:account|acct|a/c)\.?\s*(?:no\.?|number|#)?\s*[:#]?\s*(\d[\d -]{4,30}\d)(?![\d-])"#)
        static let ipv4 = make(#"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5}|/\d{1,2})?(?![\d.]\d)"#)
        static let ipv6 = make(#"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Za-z:])"#)
        static let internationalPhone = make(#"(?<![\w+])\+\d[\d ().-]{6,20}\d(?![\w-])"#)
        static let northAmericanPhone = make(#"(?<![\w.+-])(?:\(\d{3}\) ?|\d{3}[-. ])\d{3}[-. ]\d{4}(?![\w-]|\.\d)"#)
        static let trunkPhone = make(#"(?<![\w.+-])0\d{2,4}[ -]\d{3,4}[ -]?\d{3,4}(?![\w-]|\.\d)"#)
        static let labelledPhone = make(#"(?i)\b(?:tel|phone|mobile|mob|cell|fax|call|whatsapp)\b\.?\s*:?\s*(\+?\d[\d ().-]{4,18}\d)(?![\w-])"#)
        static let token = make(#"(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/_-]{24,}={0,2}(?![A-Za-z0-9+/=_-])"#)
    }
}
