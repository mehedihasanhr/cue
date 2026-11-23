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
///
/// One load at a time: a clip that arrives while the model is still loading (dictation
/// warms it the moment listening starts, so a short clip usually does) waits for that
/// load rather than starting a second copy beside it. And a model is never let go of
/// while a clip is being transcribed with it: one unloaded then (an update, a removal) is
/// only marked, and goes once that clip is done.
public actor WhisperTranscriber {
    /// A loaded model, and how many clips are being transcribed with it right now.
    private final class Loaded {
        let id: String
        let kit: WhisperKit
        var users = 0
        /// Let go of while in use; unloaded when the last user is done.
        var retired = false
        var unloaded = false

        init(id: String, kit: WhisperKit) {
            self.id = id
            self.kit = kit
        }
    }

    /// A loaded model handed out of the task that loaded it. WhisperKit is not `Sendable`;
    /// each instance is only ever used from this actor.
    private final class Kit: @unchecked Sendable {
        let kit: WhisperKit
        init(_ kit: WhisperKit) { self.kit = kit }
    }

    private let store: WhisperModelStore
    private let idleUnload: Duration
    private var loaded: Loaded?
    /// The load in progress, if any.
    private var loading: (id: String, task: Task<Kit, Error>)?
    /// Moves on with every unload, so a load that finishes after one is not kept.
    private var generation = 0
    /// How many times a model has been loaded, for tests.
    private(set) var loads = 0
    private var unloadTask: Task<Void, Never>?

    public init(store: WhisperModelStore, idleUnload: Duration = .seconds(60)) {
        self.store = store
        self.idleUnload = idleUnload
    }

    /// The words in the clip at `url`. `language` is a code such as "en" or "bn", or nil
    /// to let the model tell which language it hears.
    public func transcribe(fileAt url: URL, with model: WhisperModel, language: String? = nil) async throws -> String {
        unloadTask?.cancel()
        let entry: Loaded
        do {
            entry = try await self.entry(for: model)
        } catch {
            scheduleUnload()
            throw error
        }
        entry.users += 1
        let options = DecodingOptions(language: language,
                                      detectLanguage: language == nil,
                                      skipSpecialTokens: true,
                                      withoutTimestamps: true,
                                      chunkingStrategy: .vad)
        let outcome: Result<[TranscriptionResult], Error>
        do {
            outcome = .success(try await entry.kit.transcribe(audioPath: url.path(percentEncoded: false), decodeOptions: options))
        } catch {
            outcome = .failure(error)
        }
        entry.users -= 1
        await release(entry)
        scheduleUnload()
        // Whisper's own test for a stretch that holds no speech, whose words it made up.
        let heard = try outcome.get().flatMap { result in
            result.segments.isEmpty ? [result.text]
                : result.segments.filter { !($0.noSpeechProb > 0.6 && $0.avgLogprob < -1) }.map(\.text)
        }
        return Self.clean(heard.joined(separator: " "))
    }

    /// Loads the model and keeps it, without transcribing anything — called the moment
    /// dictation starts listening, so the wait for a cold model happens while the
    /// speaker is still talking rather than after they stop.
    public func prewarm(_ model: WhisperModel) async {
        unloadTask?.cancel()
        if let entry = try? await entry(for: model) { await release(entry) }
        scheduleUnload()
    }

    /// Lets go of the model now (it is about to be removed or replaced, or Cue is
    /// quitting); one being used by a clip goes as soon as that clip is done.
    public func unload() async {
        unloadTask?.cancel()
        unloadTask = nil
        generation += 1
        loading = nil
        guard let entry = loaded else { return }
        loaded = nil
        entry.retired = true
        await release(entry)
    }

    public var isLoaded: Bool { loaded != nil }

    /// Clips being transcribed with the loaded model right now, for tests.
    var clipsInProgress: Int { loaded?.users ?? 0 }

    /// The model, loaded: the one already in memory, the load already under way, or a new one.
    private func entry(for model: WhisperModel) async throws -> Loaded {
        if let loaded, loaded.id == model.id { return loaded }
        let task: Task<Kit, Error>
        if let loading, loading.id == model.id {
            task = loading.task
        } else {
            await unload()
            guard let folder = store.modelFolder(for: model) else { throw WhisperDictationError.notInstalled(model.title) }
            let config = WhisperKitConfig(modelFolder: folder.path(percentEncoded: false), tokenizerFolder: store.folder(for: model),
                                          verbose: false, load: true, download: false)
            loads += 1
            task = Task { Kit(try await WhisperKit(config)) }
            loading = (model.id, task)
        }
        let started = generation
        let kit: WhisperKit
        do {
            kit = try await task.value.kit
        } catch {
            if started == generation, loading?.id == model.id { loading = nil }
            throw error
        }
        // Whoever was waiting on the same load finds it already kept.
        if let loaded, loaded.kit === kit { return loaded }
        let entry = Loaded(id: model.id, kit: kit)
        if started == generation {
            loading = nil
            loaded = entry
        } else {
            // Unloaded while it loaded: used for this one clip, then let go.
            entry.retired = true
        }
        return entry
    }

    /// Unloads a model that has been let go of, once nothing is using it.
    private func release(_ entry: Loaded) async {
        guard entry.retired, entry.users == 0, !entry.unloaded else { return }
        entry.unloaded = true
        await entry.kit.unloadModels()
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        let delay = idleUnload
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    /// The idle timer's unload: never in the middle of a clip (that clip schedules another).
    private func unloadIfIdle() async {
        guard loaded?.users ?? 0 == 0, loading == nil else { return }
        await unload()
    }

    /// Whisper's text as a person would type it: no "[BLANK_AUDIO]" or "(music)" markers,
    /// no doubled spaces.
    static func clean(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
