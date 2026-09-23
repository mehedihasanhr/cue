import Foundation

/// Which language Capture Text should read.
nonisolated enum OCRLanguageSelection: Hashable, Sendable {
    /// Let Vision decide, which is what Klik has always done. Kept as the default so
    /// nobody's behaviour changes under them — but see `OCRService`, which now says
    /// something when the answer comes back in a surprising alphabet.
    case automatic
    /// Ordered; the first decides which engine runs.
    case languages([OCRLanguage])

    var primary: OCRLanguage? {
        if case .languages(let languages) = self { return languages.first }
        return nil
    }

    var languages: [OCRLanguage] {
        if case .languages(let languages) = self { return languages }
        return []
    }
}

/// A recognition service outside this Mac. Never used unless it is switched on by
/// hand and given a key.
nonisolated struct CloudOCRConfiguration: Sendable, Equatable {
    enum Provider: String, Sendable, CaseIterable, Codable {
        case google, model

        var title: String {
            switch self {
            case .google: "Google Cloud Vision"
            case .model: "Vision model (Claude, GPT…)"
            }
        }

        var keyPrompt: String {
            switch self {
            case .google: "Google Cloud API key"
            case .model: "API key"
            }
        }
    }

    var provider: Provider
    var secret: String
    /// Only the `model` provider needs these.
    var endpoint: String = ""
    var model: String = ""

    var isUsable: Bool {
        guard !secret.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch provider {
        case .google:
            return true
        case .model:
            return !endpoint.trimmingCharacters(in: .whitespaces).isEmpty
                && !model.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

/// Everything recognition needs, copied out of the preferences so a capture running
/// on a background executor can carry it.
nonisolated struct OCRSettings: Sendable, Equatable {
    var selection: OCRLanguageSelection = .automatic
    /// `nil` unless the cloud is both enabled and configured.
    var cloud: CloudOCRConfiguration?
    /// Send even the languages this Mac can read to the cloud.
    var preferCloud = false
    /// Refuse a result written in an alphabet other than the one asked for.
    var checksScript = true

    /// The variant the library's background search index uses: the same languages,
    /// but never the cloud and never a download, and it falls back to letting Vision
    /// guess rather than refusing.
    ///
    /// The rule about not answering in the wrong alphabet governs what Klik *pastes*.
    /// The index is never shown to anyone — a wrong word there costs a missed search
    /// hit, whereas refusing would quietly stop library search working at all.
    var forIndexing: OCRSettings {
        var copy = self
        copy.cloud = nil
        copy.preferCloud = false
        copy.checksScript = false
        return copy
    }
}

/// Translates between how the preferences store this and what it means.
///
/// `AppPreferences` hardcodes `UserDefaults.standard` and writes secrets from its
/// `didSet`, so it cannot be unit-tested. This is the seam that can.
nonisolated enum OCRPreferenceCodec {
    /// An empty list means automatic — which is both the default and what every
    /// existing install has, since the key has never been written.
    static func selection(fromTags tags: [String]) -> OCRLanguageSelection {
        let languages = tags.compactMap(OCRLanguageCatalog.language(for:))
        return languages.isEmpty ? .automatic : .languages(languages)
    }

    static func tags(for selection: OCRLanguageSelection) -> [String] {
        selection.languages.map(\.tag)
    }

    static func cloud(enabled: Bool, provider: String, secret: String, endpoint: String, model: String) -> CloudOCRConfiguration? {
        guard enabled else { return nil }
        let configuration = CloudOCRConfiguration(
            provider: CloudOCRConfiguration.Provider(rawValue: provider) ?? .google,
            secret: secret, endpoint: endpoint, model: model
        )
        return configuration.isUsable ? configuration : nil
    }
}
