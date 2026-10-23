import Foundation

/// The alphabet a piece of text is written in.
///
/// Cue needs this because a recogniser will happily answer in the wrong one. Vision
/// has a Devanagari model and no Bengali model, and the two scripts both hang their
/// letters from a headline stroke, so Bangla put to Vision comes back as confident
/// Devanagari. Comparing the script that was asked for against the script that came
/// back is what stops that reaching the clipboard.
///
/// The ranges below are deliberately generous — a script that borrows another's
/// letters (Korean uses hanja, Japanese uses kanji) claims both. Over-including costs
/// nothing; under-including would refuse a correct answer.
nonisolated enum OCRScript: String, Sendable, Hashable, CaseIterable {
    case latin, bengali, devanagari, arabic, hebrew, cyrillic, greek, thai
    case korean, han, japanese, tamil, telugu, gujarati, gurmukhi, kannada
    case malayalam, odia, sinhala, myanmar, khmer, ethiopic, other

    /// The script macOS infers for a BCP-47 tag: "bn-BD" and bare "bn" both resolve
    /// to Bengali.
    init(tag: String) {
        switch Locale.Language(identifier: tag).script?.identifier {
        case "Latn": self = .latin
        case "Beng": self = .bengali
        case "Deva": self = .devanagari
        case "Arab": self = .arabic
        case "Hebr": self = .hebrew
        case "Cyrl": self = .cyrillic
        case "Grek": self = .greek
        case "Thai": self = .thai
        case "Kore", "Hang": self = .korean
        case "Hans", "Hant", "Hani": self = .han
        case "Jpan", "Kana", "Hira": self = .japanese
        case "Taml": self = .tamil
        case "Telu": self = .telugu
        case "Gujr": self = .gujarati
        case "Guru": self = .gurmukhi
        case "Knda": self = .kannada
        case "Mlym": self = .malayalam
        case "Orya": self = .odia
        case "Sinh": self = .sinhala
        case "Mymr": self = .myanmar
        case "Khmr": self = .khmer
        case "Ethi": self = .ethiopic
        default: self = .other
        }
    }

    /// The script's name in the reader's own language — "Bangla", not "bn".
    var displayName: String {
        switch self {
        case .latin: "Latin"
        case .bengali: "Bangla"
        case .devanagari: "Devanagari"
        case .arabic: "Arabic"
        case .hebrew: "Hebrew"
        case .cyrillic: "Cyrillic"
        case .greek: "Greek"
        case .thai: "Thai"
        case .korean: "Korean"
        case .han: "Chinese"
        case .japanese: "Japanese"
        case .tamil: "Tamil"
        case .telugu: "Telugu"
        case .gujarati: "Gujarati"
        case .gurmukhi: "Gurmukhi"
        case .kannada: "Kannada"
        case .malayalam: "Malayalam"
        case .odia: "Odia"
        case .sinhala: "Sinhala"
        case .myanmar: "Myanmar"
        case .khmer: "Khmer"
        case .ethiopic: "Ethiopic"
        case .other: "an unknown script"
        }
    }

    /// Written right to left, so `TextLayout` must order a line's fragments the other
    /// way round and leave indentation alone.
    var isRightToLeft: Bool { self == .arabic || self == .hebrew }

    private static let cjkIdeographs: [ClosedRange<UInt32>] = [
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2A6DF,
    ]

    /// The Unicode blocks that count as this script. Digits and punctuation belonging
    /// to a script are included; shared ASCII digits and punctuation are not in any,
    /// so they drop out of the arithmetic in `share(in:)`.
    var ranges: [ClosedRange<UInt32>] {
        switch self {
        case .latin: [0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF]
        case .bengali: [0x0980...0x09FF]
        case .devanagari: [0x0900...0x097F, 0xA8E0...0xA8FF]
        case .arabic: [0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF]
        case .hebrew: [0x0590...0x05FF, 0xFB1D...0xFB4F]
        case .cyrillic: [0x0400...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F]
        case .greek: [0x0370...0x03FF, 0x1F00...0x1FFF]
        case .thai: [0x0E00...0x0E7F]
        // Korean writes hanja alongside hangul; Japanese writes kanji alongside kana.
        case .korean: [0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF] + Self.cjkIdeographs
        case .han: Self.cjkIdeographs
        case .japanese: [0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF] + Self.cjkIdeographs
        case .tamil: [0x0B80...0x0BFF]
        case .telugu: [0x0C00...0x0C7F]
        case .gujarati: [0x0A80...0x0AFF]
        case .gurmukhi: [0x0A00...0x0A7F]
        case .kannada: [0x0C80...0x0CFF]
        case .malayalam: [0x0D00...0x0D7F]
        case .odia: [0x0B00...0x0B7F]
        case .sinhala: [0x0D80...0x0DFF]
        case .myanmar: [0x1000...0x109F, 0xAA60...0xAA7F]
        case .khmer: [0x1780...0x17FF, 0x19E0...0x19FF]
        case .ethiopic: [0x1200...0x139F]
        case .other: []
        }
    }

    /// Below this share of the text, a result is treated as the wrong script and is
    /// not copied. Half is deliberately forgiving: a Bangla screen with an English
    /// button on it still passes, while Bangla answered in Devanagari does not.
    static let minimumShare: Double = 0.5

    func contains(_ scalar: Unicode.Scalar) -> Bool {
        ranges.contains { $0.contains(scalar.value) }
    }

    /// Letters only — never digits.
    ///
    /// This matters more than it looks. Bengali has its own digits, ০ to ৯, and they
    /// live in the Bengali block; so do Devanagari's. A recogniser handed a page it
    /// cannot read returns strings of digits, and counting those as evidence of a
    /// script would let exactly the wrong answers through. `isAlphabetic` also covers
    /// the Indic vowel signs, which are marks rather than letters but are certainly
    /// part of the writing.
    static func isScriptLetter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.isAlphabetic else { return false }
        return allCases.contains { $0 != .other && $0.contains(scalar) }
    }

    /// How many letters there are to judge at all.
    static func letterCount(in text: String) -> Int {
        text.unicodeScalars.count(where: isScriptLetter)
    }

    /// Below this many letters, a result is not judged: there is not enough of it to
    /// tell one alphabet from another, and a screenshot of a column of numbers is a
    /// perfectly ordinary thing to capture.
    static let minimumLettersToJudge = 4

    /// The fraction of `text`'s letters that belong to this script. Digits,
    /// punctuation and whitespace belong to no alphabet and are ignored, so "৩ items"
    /// is judged on "items" alone. Returns 0 when there is nothing to judge.
    func share(in text: String) -> Double {
        var mine = 0, total = 0
        for scalar in text.unicodeScalars where Self.isScriptLetter(scalar) {
            total += 1
            if contains(scalar) { mine += 1 }
        }
        return total > 0 ? Double(mine) / Double(total) : 0
    }

    /// The script a reader most likely *meant* when an engine answered in `found`.
    ///
    /// There is one pairing worth knowing about and it is the reason this file
    /// exists: Vision ships a Devanagari model and no Bengali one, and the two
    /// scripts share the headline stroke, so Bangla put to Vision comes back as
    /// Devanagari. When Cue was not told which language to expect, that is the one
    /// case where it is worth saying "if that should have been Bangla, say so".
    static func possiblyIntended(whenAnsweredIn found: OCRScript) -> OCRScript? {
        found == .devanagari ? .bengali : nil
    }

    /// The script most of `text` is written in, or `nil` when it has no letters at
    /// all. Ties go to the earlier case, which puts Latin first.
    static func dominant(in text: String) -> OCRScript? {
        var counts: [OCRScript: Int] = [:]
        // `isScriptLetter` would walk every script to answer, and then this loop
        // walks them again; asking for the alphabetic property directly does the
        // same job once. A scalar in no script's range simply adds to no count.
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            for script in allCases where script != .other && script.contains(scalar) {
                counts[script, default: 0] += 1
            }
        }
        guard let best = counts.values.max(), best > 0 else { return nil }
        return allCases.first { counts[$0] == best }
    }
}
