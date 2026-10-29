import Foundation
import WhisperKit

public enum WhisperDictationError: LocalizedError, Equatable {
    case notInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let title): "The \(title) model isn't downloaded. Download it in Settings › Dictation."
        }
    }
}

/// Turns a recorded clip into text with a downloaded Whisper model.
///
/// The model is loaded when it is first needed and let go a minute after the last clip,
/// so several dictations in a row do not each wait for it to load, and a Cue that is not
/// dictating holds none of it. Loading takes a few seconds (longer the first time, while
/// Core ML prepares the model for this Mac).
public actor WhisperTranscriber {
    private let store: WhisperModelStore
    private let idleUnload: Duration
    private var loaded: (id: String, kit: WhisperKit)?
    private var unloadTask: Task<Void, Never>?

    public init(store: WhisperModelStore, idleUnload: Duration = .seconds(60)) {
        self.store = store
        self.idleUnload = idleUnload
    }

    /// The words in the clip at `url`. `language` is a code such as "en" or "bn", or nil
    /// to let the model tell which language it hears.
    public func transcribe(fileAt url: URL, with model: WhisperModel, language: String? = nil) async throws -> String {
        unloadTask?.cancel()
        defer { scheduleUnload() }
        let kit = try await kit(for: model)
        let options = DecodingOptions(language: language,
                                      detectLanguage: language == nil,
                                      skipSpecialTokens: true,
                                      withoutTimestamps: true,
                                      chunkingStrategy: .vad)
        let results = try await kit.transcribe(audioPath: url.path(percentEncoded: false), decodeOptions: options)
        return Self.clean(results.map(\.text).joined(separator: " "))
    }

    /// Lets go of the model now (it is about to be removed or replaced, or Cue is quitting).
    public func unload() async {
        unloadTask?.cancel()
        unloadTask = nil
        if let kit = loaded?.kit { await kit.unloadModels() }
        loaded = nil
    }

    public var isLoaded: Bool { loaded != nil }

    private func kit(for model: WhisperModel) async throws -> WhisperKit {
        if let loaded, loaded.id == model.id { return loaded.kit }
        await unload()
        guard let folder = store.modelFolder(for: model) else { throw WhisperDictationError.notInstalled(model.title) }
        let config = WhisperKitConfig(modelFolder: folder.path(percentEncoded: false), tokenizerFolder: store.folder(for: model),
                                      verbose: false, load: true, download: false)
        let kit = try await WhisperKit(config)
        loaded = (model.id, kit)
        return kit
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        let delay = idleUnload
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    /// Whisper's text as a person would type it: no "[BLANK_AUDIO]" or "(music)" markers,
    /// no doubled spaces.
    static func clean(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
