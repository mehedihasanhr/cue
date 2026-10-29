import Foundation

/// One Whisper model Cue offers to download: a folder in Argmax's Core ML repository on
/// Hugging Face, and what to tell a person about it before they spend the disk on it.
///
/// A short list on purpose. The repository holds two dozen variants, most of them the same
/// model at another size or English-only; four cover the choice that matters, from
/// "fast and small" to "as good as it gets on a Mac".
public struct WhisperModel: Identifiable, Hashable, Sendable {
    /// The folder's name in the repository, which is also the name of its folder here.
    public let id: String
    public let title: String
    public let detail: String
    /// Roughly what the download weighs, for before the repository has been asked; the
    /// real size comes from `WhisperModelStore.remoteInfo(of:)`.
    public let approximateBytes: Int64

    public static let repository = "argmaxinc/whisperkit-coreml"

    public static let all: [WhisperModel] = [
        WhisperModel(id: "openai_whisper-tiny", title: "Tiny",
                     detail: "Fastest, least accurate. Fine for short, clear notes.",
                     approximateBytes: 77_000_000),
        WhisperModel(id: "openai_whisper-base", title: "Base",
                     detail: "Quick, and good with clear speech.",
                     approximateBytes: 147_000_000),
        WhisperModel(id: "openai_whisper-small_216MB", title: "Small",
                     detail: "Accurate for everyday dictation; the usual choice.",
                     approximateBytes: 217_000_000),
        WhisperModel(id: "openai_whisper-large-v3-v20240930_turbo_632MB", title: "Large v3 Turbo",
                     detail: "Most accurate, best with accents and mixed languages. Slower to load.",
                     approximateBytes: 646_000_000),
    ]

    public static func named(_ id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }
}
