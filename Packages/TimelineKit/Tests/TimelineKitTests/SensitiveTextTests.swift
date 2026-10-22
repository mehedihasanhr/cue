import CoreGraphics
import Testing
@testable import TimelineKit

/// What counts as sensitive in a line of text read off the screen — and, as much, what
/// does not: a review sheet full of version numbers and dates is one people stop reading.
@Suite("Sensitive text")
struct SensitiveTextTests {
    /// The kinds found in a line, and the text of each.
    private func found(_ line: String) -> [(SensitiveKind, String)] {
        SensitiveText.matches(in: line).map { ($0.kind, $0.text) }
    }

    private func kinds(_ line: String) -> [SensitiveKind] { found(line).map(\.0) }

    // Built from pieces so the file itself does not look like it leaks a key.
    private let stripeKey = "sk_" + "live_" + "4eC39HqLyjWDarjtT1zdp7dc"
    private let openAIKey = "sk-" + "proj-" + "Xk9mQ2vLp8RtW3zN7bY4cH6jD1fG5sA0"
    private let gitHubToken = "ghp_" + "R8x2Lq9Wm4Tz7Nv3Kp6Yb1Hc5Jd0Fg8Sa2Qe"
    private let awsKey = "AKIA" + "IOSFODNN7EXAMPLE"
    private let slackToken = "xoxb-" + "123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx"
    private let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0"
        + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

    // MARK: - Found

    @Test("Email addresses", arguments: [
        "jane.doe@company.com", "Contact: hunter2@example.com.", "j.smith+test@mail.example.co.uk",
        "From: Jane Doe <jane@acme.io>", "jane @ example.com",
    ])
    func emails(_ line: String) {
        #expect(kinds(line) == [.email])
    }

    @Test("The email is only the address, not the words round it")
    func emailRange() {
        #expect(found("Signed in as jane.doe@company.com today").map(\.1) == ["jane.doe@company.com"])
    }

    @Test("Card numbers that pass Luhn and start like a card", arguments: [
        "4242 4242 4242 4242", "4111-1111-1111-1111", "5555555555554444", "3782 822463 10005",
        "Card: 6011 1111 1111 1117", "2223 0031 2200 3222",
    ])
    func cards(_ line: String) {
        #expect(kinds(line) == [.card])
    }

    @Test("Phone numbers", arguments: [
        "+1 (415) 555-0132", "(415) 555-0132", "415-555-0132", "415.555.0132", "+44 20 7946 0958",
        "020 7946 0958", "Phone: 030 1234567", "+4915112345678", "Mobile 07700 900123",
    ])
    func phones(_ line: String) {
        #expect(kinds(line) == [.phone])
    }

    @Test("IBANs, by their check digits or their label", arguments: [
        "DE89 3704 0044 0532 0130 00", "GB82 WEST 1234 5698 7654 32", "FR1420041010050500013M02606",
        "IBAN: NL91 ABNA 0417 1643 00",
    ])
    func ibans(_ line: String) {
        #expect(kinds(line) == [.account])
    }

    @Test("An IBAN stops where it ends, not at the next capitals")
    func ibanEnds() {
        #expect(found("Pay to DE89 3704 0044 0532 0130 00 BANK AG").map(\.1) == ["DE89 3704 0044 0532 0130 00"])
    }

    @Test("Account numbers after a word that says so", arguments: [
        "Account number: 12345678", "Acct # 0012-3456-789", "Account 12 34 56 78",
    ])
    func accounts(_ line: String) {
        #expect(kinds(line) == [.account])
    }

    @Test("IP addresses", arguments: [
        "192.168.1.24", "Server 203.0.113.7:8080", "10.0.0.12/24", "2001:db8:85a3::8a2e:370:7334",
        "ssh root@203.0.113.9",
    ])
    func ipAddresses(_ line: String) {
        #expect(kinds(line).contains(.ipAddress))
    }

    @Test("Keys with a service's prefix")
    func prefixedKeys() {
        for key in [stripeKey, openAIKey, gitHubToken, awsKey, slackToken, jwt, "AIza" + "SyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY"] {
            #expect(found("key = \(key)").contains { $0.0 == .secret && $0.1 == key }, "\(key)")
        }
        #expect(kinds("-----BEGIN RSA PRIVATE KEY-----") == [.secret])
        #expect(found("Authorization: Bearer abcDEF123456ghiJKL789").map(\.1) == ["abcDEF123456ghiJKL789"])
    }

    @Test("A long random string with no prefix")
    func randomKey() {
        #expect(kinds("Xk9mQ2vLp8RtW3zN7bY4cH6jD1fG5sA0") == [.secret])
        #expect(kinds("token: a1B2c3D4e5F6g7H8i9J0k1L2m3N4") == [.secret])
    }

    @Test("Passwords: the dots a field shows, and a value after a label", arguments: [
        "••••••••", "●●●●●●●●●●", "**********", "Password: hunter2!", "password=correcthorse", "PIN: 4821",
        // How text recognition reads a field's bullets.
        "Password •......•", "........", "Password ........",
    ])
    func passwords(_ line: String) {
        #expect(kinds(line) == [.password])
    }

    @Test("Several things in one line are each found once")
    func several() {
        let line = "jane@acme.io · +1 (415) 555-0132 · 4242 4242 4242 4242"
        #expect(kinds(line) == [.email, .phone, .card])
    }

    // MARK: - Not found

    @Test("Ordinary words", arguments: [
        "The quick brown fox jumps over the lazy dog", "Settings", "Password", "Forgot password?",
        "Password: Required", "Change password…", "Enter your email address", "@username", "Sign in with Apple",
        "NSLayoutConstraint", "handleUserProfileUpdate", "ThisIsAVeryLongIdentifierName2024",
        "com.stackrover.cue.studio", "internationalization-and-localization",
        "Loading.....", "Introduction .......... 3", "Wait for it .....",
    ])
    func ordinaryWords(_ line: String) {
        #expect(found(line).isEmpty, "\(line)")
    }

    @Test("Version numbers", arguments: [
        "Version 10.15.7", "v1.2.3.4", "Build 2.1.0.4", "macOS 14.4.1", "1.2.3", "Swift 6.0", "Release 3.10.2.1",
    ])
    func versions(_ line: String) {
        #expect(found(line).isEmpty, "\(line)")
    }

    @Test("Dates and times", arguments: [
        "2024-09-29", "29.09.2024", "09/29/2024", "Sep 29, 2024 10:30:45", "00:01:23:12", "2024-09-29T10:30:45Z",
        "Updated 12 Mar 2024, 14:05",
    ])
    func datesAndTimes(_ line: String) {
        #expect(found(line).isEmpty, "\(line)")
    }

    @Test("Prices and quantities", arguments: [
        "$1,234.56", "Total: $129.99", "£2,500,000", "€ 4242 4242 4242 4242", "100%", "3840 × 2160", "60 fps",
        "Page 1 of 12", "1,024 MB", "$415-555-0132",
    ])
    func prices(_ line: String) {
        #expect(found(line).isEmpty, "\(line)")
    }

    @Test("Numbers that look like cards, phones or addresses but are not", arguments: [
        "4242 4242 4242 4241", "1234 5678 9012 3456", "0000 0000 0000 0000", "Order #1234567890",
        "Invoice 2024-000123", "127.0.0.1", "255.255.255.0", "0.0.0.0", "999.1.1.1", "DE89 3704 0044 0532 0130 01",
        "ISBN 978-3-16-148410-0", "a4:83:e7:12:34:56",
    ])
    func lookalikeNumbers(_ line: String) {
        #expect(found(line).isEmpty, "\(line)")
    }

    @Test("Hashes, ids, files and paths", arguments: [
        "4dd7c30", "a3f5c9e2b1d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2", "123e4567-e89b-12d3-a456-426614174000",
        "icon@2x.png", "git@github.com:stackrover/cue.git", "/Users/jane/Documents/Projects/CueStudio/Package.swift",
        "Screenshot_2024-09-29_at_10.30.45.png", "IMG_20240929_123456.jpg", "https://example.com/docs/getting-started",
        "•••• 4242", "•••• •••• •••• 4242",
    ])
    func hashesAndPaths(_ line: String) {
        #expect(found(line).isEmpty, "\(line)")
    }

    // MARK: - Labels on their own line

    @Test("A value to the right of its label is found by the label")
    func labelBeside() {
        let lines = [
            SensitiveText.Line(text: "Password", box: CGRect(x: 10, y: 100, width: 70, height: 16)),
            SensitiveText.Line(text: "hunter2", box: CGRect(x: 110, y: 101, width: 60, height: 16)),
            SensitiveText.Line(text: "API key:", box: CGRect(x: 10, y: 140, width: 60, height: 16)),
            SensitiveText.Line(text: "a1b2c3d4e5f6a7b8c9d0", box: CGRect(x: 90, y: 140, width: 180, height: 16)),
        ]
        let values = SensitiveText.labelledValues(in: lines)
        #expect(values == [SensitiveText.Value(line: 1, kind: .password), SensitiveText.Value(line: 3, kind: .secret)])
    }

    @Test("A label's neighbour is not a value when it is a word of the interface or far away")
    func labelNotBeside() {
        let lines = [
            SensitiveText.Line(text: "Password", box: CGRect(x: 10, y: 100, width: 70, height: 16)),
            SensitiveText.Line(text: "Change…", box: CGRect(x: 110, y: 100, width: 60, height: 16)),
            SensitiveText.Line(text: "Password", box: CGRect(x: 10, y: 200, width: 70, height: 16)),
            SensitiveText.Line(text: "Required", box: CGRect(x: 110, y: 200, width: 60, height: 16)),
            SensitiveText.Line(text: "Token", box: CGRect(x: 10, y: 300, width: 50, height: 16)),
            SensitiveText.Line(text: "a1b2c3d4e5f6a7b8c9d0", box: CGRect(x: 10, y: 330, width: 180, height: 16)),
            SensitiveText.Line(text: "PIN", box: CGRect(x: 10, y: 400, width: 30, height: 16)),
            SensitiveText.Line(text: "4821", box: CGRect(x: 600, y: 400, width: 40, height: 16)),
        ]
        #expect(SensitiveText.labelledValues(in: lines).isEmpty)
    }

    // MARK: - Checks

    @Test("Luhn")
    func luhn() {
        #expect(SensitiveText.luhn("4242424242424242"))
        #expect(SensitiveText.luhn("79927398713"))
        #expect(!SensitiveText.luhn("4242424242424241"))
        #expect(!SensitiveText.luhn("79927398710"))
        #expect(!SensitiveText.luhn("4242 4242"))
        #expect(!SensitiveText.luhn(""))
    }

    @Test("IBAN check digits")
    func ibanChecksum() {
        #expect(SensitiveText.ibanChecksum("DE89 3704 0044 0532 0130 00"))
        #expect(SensitiveText.ibanChecksum("gb82west12345698765432"))
        #expect(!SensitiveText.ibanChecksum("DE88 3704 0044 0532 0130 00"))
        #expect(!SensitiveText.ibanChecksum("DE89"))
    }

    @Test("Entropy")
    func entropy() {
        #expect(SensitiveText.entropy("") == 0)
        #expect(SensitiveText.entropy("aaaaaaaa") == 0)
        #expect(abs(SensitiveText.entropy("abcd") - 2) < 1e-9)
        #expect(SensitiveText.entropy("Xk9mQ2vLp8RtW3zN7bY4cH6jD1fG5sA0") > 4.5)
        #expect(SensitiveText.entropy("internationalization") < 3.5)
    }

    @Test("Every pattern compiles")
    func patternsCompile() {
        #expect(SensitiveText.Pattern.all.allSatisfy { $0 != nil })
    }

    // MARK: - Shown in the sheet

    @Test("Obscured enough to recognise, not enough to use")
    func obscured() {
        #expect(SensitiveText.obscured("jane.doe@example.com", kind: .email) == "j•••@example.com")
        #expect(SensitiveText.obscured("4242 4242 4242 4242", kind: .card) == "•••• 4242")
        #expect(SensitiveText.obscured("+1 (415) 555-0132", kind: .phone) == "+• (•••) •••-••32")
        #expect(SensitiveText.obscured("DE89 3704 0044 0532 0130 00", kind: .account) == "DE•••3000")
        #expect(SensitiveText.obscured("12345678", kind: .account) == "•••5678")
        #expect(SensitiveText.obscured(openAIKey, kind: .secret) == "sk-proj-•••A0")
        #expect(SensitiveText.obscured(awsKey, kind: .secret) == "AKIA•••LE")
        #expect(SensitiveText.obscured("192.168.1.24", kind: .ipAddress) == "192.168.•.•")
        #expect(SensitiveText.obscured("2001:db8::1", kind: .ipAddress) == "2001:•••")
        #expect(SensitiveText.obscured("hunter2", kind: .password) == "••••••••")
        // Nothing of the secret itself survives in what is shown for a short one.
        #expect(!SensitiveText.obscured("abcd1234", kind: .secret).contains("1234"))
    }
}
