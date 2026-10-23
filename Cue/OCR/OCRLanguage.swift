import os
import Foundation
import Vision

/// A language Cue can be asked to read, named the way Vision names it: a BCP-47 tag
/// such as `en-US`, `hi-IN` or `bn-BD`.
///
/// A tag rather than a Cue enum on purpose. Vision's repertoire is a property of the
/// installed macOS, not of this app — it grew from 8 languages to 33 over a few
/// releases — so the list is asked for at runtime and anything Apple adds later shows
/// up without a code change.
nonisolated struct OCRLanguage: Hashable, Sendable, Codable, Identifiable, Comparable {
    let tag: String

    init(_ tag: String) { self.tag = tag }

    var id: String { tag }

    /// `bn` from `bn-BD` — the subtag the Tesseract table is keyed by, so `bn-BD` and
    /// `bn-IN` both find the same pack.
    var base: String { OCRLanguageNaming.naming(for: tag).base }

    /// "Bangla" — the language's name in the reader's own language, without the
    /// region, because the region is noise in a list of scripts. Falls back to the
    /// tag itself for anything macOS cannot name.
    var displayName: String { OCRLanguageNaming.naming(for: tag).display }

    /// "বাংলা" — the name in the language itself, so a Bangla reader can find the row
    /// without reading English.
    var nativeName: String { OCRLanguageNaming.naming(for: tag).native }

    var script: OCRScript { OCRLanguageNaming.naming(for: tag).script }

    /// Tesseract's three-letter code, when Cue knows of a pack for this language.
    var tesseractCode: String? { TesseractLanguagePacks.code(forBase: base) }

    static func < (a: Self, b: Self) -> Bool {
        let byName = a.displayName.localizedStandardCompare(b.displayName)
        return byName == .orderedSame ? a.tag < b.tag : byName == .orderedAscending
    }
}

/// Which languages each engine can read, and where a given language can be read.
nonisolated enum OCRLanguageCatalog {
    /// What Vision on *this* Mac can recognise. Asked of the OS once and cached,
    /// never hardcoded — see the note on `OCRLanguage`.
    ///
    /// On macOS 27 this is 33 languages whose only Indic scripts are Devanagari
    /// (`hi-IN`, `mr-IN`). There is no Bengali model, which is the whole reason the
    /// other engines exist.
    /// The raw tags, kept separately because the naming table is built from them and
    /// `all` sorts by a name that table provides.
    static let visionTags: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard let tags = try? request.supportedRecognitionLanguages(), !tags.isEmpty else {
            Log.ocr.error("Vision reported no recognition languages; falling back to English")
            return ["en-US"]
        }
        return tags
    }()

    static let vision: [OCRLanguage] = visionTags.map(OCRLanguage.init)

    private static let visionTagSet = Set(visionTags)

    /// The languages Cue has a Tesseract pack for.
    static let tesseract: [OCRLanguage] = TesseractLanguagePacks.all.map { OCRLanguage($0.tag) }

    /// Everything offerable, deduplicated by tag and sorted for a menu. A language
    /// both engines can read appears once; Vision's spelling of the tag wins.
    static let all: [OCRLanguage] = {
        var seen = Set<String>()
        var result: [OCRLanguage] = []
        for language in vision + tesseract where seen.insert(language.tag).inserted {
            result.append(language)
        }
        return result.sorted()
    }()

    private static let byTag: [String: OCRLanguage] = Dictionary(uniqueKeysWithValues: all.map { ($0.tag, $0) })

    static func language(for tag: String) -> OCRLanguage? {
        if let known = byTag[tag] { return known }
        // A tag outside the catalogue is still usable if a pack covers its language.
        return TesseractLanguagePacks.code(forBase: OCRLanguage(tag).base) != nil ? OCRLanguage(tag) : nil
    }

    static func isVisionSupported(_ language: OCRLanguage) -> Bool {
        visionTagSet.contains(language.tag)
    }

    /// Every engine that could in principle read this language, ignoring whether it
    /// is set up. The cloud is listed for everything: a general recogniser will
    /// attempt any script.
    static func engines(for language: OCRLanguage) -> Set<OCREngineID> {
        var engines: Set<OCREngineID> = [.cloud]
        if isVisionSupported(language) { engines.insert(.vision) }
        if language.tesseractCode != nil { engines.insert(.tesseract) }
        return engines
    }
}

/// What each language is called, worked out once.
///
/// Asking `Locale` to name a language is not cheap — around 0.4 ms per language for
/// the pair of names the picker shows — and the picker asks for every row every time
/// SwiftUI rebuilds the list, which is on every keystroke in its search field. Forty
/// rows came to 17 ms a render, enough to drop frames while typing. The answers never
/// change while the app runs, so they are computed once for every language Cue can
/// offer and looked up thereafter.
nonisolated enum OCRLanguageNaming {
    struct Naming: Sendable {
        let base: String
        let display: String
        let native: String
        let script: OCRScript
    }

    /// Built from the raw tags rather than from `OCRLanguageCatalog.all`, which sorts
    /// by display name and would otherwise need this table to exist first.
    private static let table: [String: Naming] = {
        var tags = Set(OCRLanguageCatalog.visionTags)
        tags.formUnion(TesseractLanguagePacks.all.map(\.tag))
        return Dictionary(uniqueKeysWithValues: tags.map { ($0, compute($0)) })
    }()

    /// A tag outside the catalogue — one left in the preferences by an older version,
    /// say — is worked out on the spot rather than cached, because there is no list to
    /// bound the cache with.
    static func naming(for tag: String) -> Naming { table[tag] ?? compute(tag) }

    private static func compute(_ tag: String) -> Naming {
        let language = Locale.Language(identifier: tag)
        let base = language.languageCode?.identifier
            ?? tag.split(separator: "-").first.map(String.init)
            ?? tag
        let display = Locale.current.localizedString(forLanguageCode: base)?.localizedCapitalized ?? tag
        let native = Locale(identifier: tag).localizedString(forLanguageCode: base)?.localizedCapitalized ?? display
        return Naming(base: base, display: display, native: native, script: OCRScript(tag: tag))
    }
}
