import Foundation
import Speech

/// The languages captions can be listened for, in the words the user reads.
///
/// A language is a locale identifier, and the empty one is "whatever this Mac is set to"
/// — which is a choice of its own rather than a copy of today's answer, so that somebody
/// who changes their Mac's language is not left with captions in the old one.
enum CaptionLanguages {
    /// The system's language, then every language the recogniser knows, by name.
    static let all: [String] = {
        let names = Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        return [""] + names.sorted {
            title(for: $0).localizedCaseInsensitiveCompare(title(for: $1)) == .orderedAscending
        }
    }()

    static func title(for identifier: String) -> String {
        guard !identifier.isEmpty else {
            return "This Mac's language"
        }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// The choice that is stored, corrected to one that is on offer.
    ///
    /// The recogniser spells its locales its own way ("en-US"), and a preference written
    /// by an older build or by hand may spell the same language another ("en_US").
    static func resolved(_ identifier: String) -> String {
        guard !identifier.isEmpty else { return "" }
        if all.contains(identifier) { return identifier }
        let wanted = Locale(identifier: identifier).identifier(.bcp47)
        return all.first { !$0.isEmpty && Locale(identifier: $0).identifier(.bcp47) == wanted } ?? ""
    }
}
