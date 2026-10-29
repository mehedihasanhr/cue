import AVFoundation
import DictationKit
import Foundation
import Observation
import os

/// Dictation for Cue's text fields, and the Whisper models it can use.
///
/// A dictation is a short clip: the microphone is recorded while the button is held on,
/// then the clip is turned into text in one go and deleted. Nothing listens before the
/// button is pressed, and no recogniser stays loaded after it answers (a Whisper model
/// stays a minute, so the next dictation does not wait for it again). This is lighter
/// than recognising live, and the text comes out the same.
///
/// One shared instance, because the buttons sit in many windows with no common parent.
/// It is made the first time a button or Settings › Dictation needs it.
@MainActor
@Observable
final class DictationService {
    static let shared = DictationService()

    enum State: Equatable { case idle, listening, transcribing }

    private(set) var state: State = .idle
    /// The button the current dictation belongs to; the others wait.
    private(set) var owner: UUID?
    /// How loud the microphone is, 0…1, while listening.
    private(set) var level: Double = 0

    /// Downloads and updates in progress, by model id: the fraction done.
    private(set) var downloads: [String: Double] = [:]
    /// Installed models with a newer version in the repository.
    private(set) var updates: Set<String> = []
    private(set) var checkingForUpdates = false
    /// Why the last download, update, removal or update check of a model failed.
    private(set) var modelErrors: [String: String] = [:]
    /// Bumped whenever the models on disk change, so views reading them look again.
    private(set) var changes = 0
    /// Each model's real download size, as the repository reports it; asked for when
    /// Settings › Dictation opens.
    private(set) var downloadSizes: [String: Int64] = [:]

    /// Handed over by the app at launch; static, so doing so does not create the service.
    static weak var preferences: AppPreferences?
    private var preferences: AppPreferences? { Self.preferences }
    @ObservationIgnored let store: WhisperModelStore
    @ObservationIgnored private let transcriber: WhisperTranscriber
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var clip: URL?
    @ObservationIgnored private var meter: Timer?
    @ObservationIgnored private var installs: [String: Task<Void, Never>] = [:]

    /// The longest one dictation records, so a button left on does not fill the disk.
    private static let longest: TimeInterval = 10 * 60

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = WhisperModelStore(root: support.appending(path: "Cue/Dictation/Whisper", directoryHint: .isDirectory))
        transcriber = WhisperTranscriber(store: store)
        // A download Cue quit in the middle of, or an old copy an update never deleted.
        store.cleanUpLeftovers()
    }

    func isListening(_ id: UUID) -> Bool { owner == id && state == .listening }
    func isTranscribing(_ id: UUID) -> Bool { owner == id && state == .transcribing }

    // MARK: Dictating

    /// Starts recording for the button `id`. False when it cannot (the microphone is not
    /// allowed, or another dictation is going); the reason has been shown.
    @discardableResult
    func start(for id: UUID) async -> Bool {
        guard state == .idle else { return false }
        guard await microphoneAllowed() else {
            FeedbackHUD.show("Microphone not allowed", symbol: "mic.slash",
                             subtitle: "Allow Cue in System Settings › Privacy & Security › Microphone.")
            return false
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "Dictation-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000, // what both recognisers listen at
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.longest) else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            clip = url
            owner = id
            state = .listening
            startMeter()
            return true
        } catch {
            AppleDictation.log.error("Couldn't start dictation: \(error.localizedDescription, privacy: .public)")
            FeedbackHUD.show("Couldn't start dictation", symbol: "mic.slash", subtitle: error.localizedDescription)
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    /// Stops recording and returns what was said; nil when nothing was heard or it failed
    /// (the reason has been shown).
    func finish(for id: UUID) async -> String? {
        guard owner == id, state == .listening, let recorder, let clip else { return nil }
        recorder.stop()
        self.recorder = nil
        stopMeter()
        state = .transcribing
        defer {
            try? FileManager.default.removeItem(at: clip)
            self.clip = nil
            owner = nil
            state = .idle
        }
        do {
            let text = try await transcribe(clip)
            if text.isEmpty { FeedbackHUD.show("Nothing heard", symbol: "mic") }
            return text.isEmpty ? nil : text
        } catch {
            AppleDictation.log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
            FeedbackHUD.show("Couldn't turn speech into text", symbol: "mic.slash", subtitle: error.localizedDescription)
            return nil
        }
    }

    /// Stops recording and throws the clip away.
    func cancel() {
        recorder?.stop()
        recorder = nil
        stopMeter()
        if let clip { try? FileManager.default.removeItem(at: clip) }
        clip = nil
        owner = nil
        state = .idle
    }

    /// The chosen Whisper model when it is downloaded; otherwise macOS's recogniser.
    private func transcribe(_ clip: URL) async throws -> String {
        let language = preferences?.dictationLanguage ?? ""
        if preferences?.dictationEngine == .whisper {
            if let model = chosenWhisperModel {
                return try await transcriber.transcribe(fileAt: clip, with: model, language: language.isEmpty ? nil : language)
            }
            FeedbackHUD.show("No Whisper model downloaded", symbol: "arrow.down.circle",
                             subtitle: "Using macOS dictation. Download a model in Settings › Dictation.")
        }
        return try await AppleDictation.text(in: clip, locale: language.isEmpty ? .current : Locale(identifier: language))
    }

    /// The Whisper model dictation would use: the chosen one, if it is downloaded.
    var chosenWhisperModel: WhisperModel? {
        guard let id = preferences?.dictationWhisperModel, let model = WhisperModel.named(id),
              installation(of: model) != nil else { return nil }
        return model
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    private func startMeter() {
        meter = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                // -50 dB and below is silence; 0 dB is as loud as it goes.
                self.level = max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
            }
        }
    }

    private func stopMeter() {
        meter?.invalidate()
        meter = nil
        level = 0
    }

    // MARK: Whisper models

    func installation(of model: WhisperModel) -> WhisperModelStore.Installation? {
        _ = changes
        return store.installation(of: model)
    }

    var totalBytes: Int64 {
        _ = changes
        return store.totalBytes
    }

    /// Downloads `model`, or updates it when it is already here: the new files replace the
    /// old ones only once they load, and the old ones are deleted.
    func download(_ model: WhisperModel) {
        guard installs[model.id] == nil else { return }
        let id = model.id
        modelErrors[id] = nil
        downloads[id] = 0
        installs[id] = Task { [weak self] in
            guard let self else { return }
            // An update replaces the files a loaded model reads from.
            if store.installation(of: model) != nil { await transcriber.unload() }
            do {
                try await store.install(model) { fraction in
                    Task { @MainActor in DictationService.shared.report(fraction, for: id) }
                }
                updates.remove(id)
                // The first model downloaded is the one used.
                if preferences?.dictationWhisperModel == nil { preferences?.dictationWhisperModel = id }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { modelErrors[id] = error.localizedDescription }
            }
            downloads[id] = nil
            installs[id] = nil
            changes += 1
        }
    }

    private func report(_ fraction: Double, for id: String) {
        // Late reports must not bring back a finished download's bar.
        if downloads[id] != nil { downloads[id] = fraction }
    }

    func cancelDownload(_ model: WhisperModel) {
        installs[model.id]?.cancel()
    }

    /// Deletes `model` and everything of it.
    func remove(_ model: WhisperModel) async {
        installs[model.id]?.cancel()
        await transcriber.unload()
        do {
            try store.remove(model)
            modelErrors[model.id] = nil
        } catch {
            modelErrors[model.id] = error.localizedDescription
        }
        updates.remove(model.id)
        if preferences?.dictationWhisperModel == model.id {
            preferences?.dictationWhisperModel = WhisperModel.all.first { store.installation(of: $0) != nil }?.id
        }
        changes += 1
    }

    /// Deletes every model and the folder that held them.
    func removeAll() async {
        installs.values.forEach { $0.cancel() }
        await transcriber.unload()
        do { try store.removeAll() } catch {
            AppleDictation.log.error("Couldn't remove the Whisper models: \(error.localizedDescription, privacy: .public)")
        }
        updates.removeAll()
        modelErrors.removeAll()
        preferences?.dictationWhisperModel = nil
        changes += 1
    }

    /// Asks the repository how big each model really is (once per run; it changes rarely).
    func loadDownloadSizes() async {
        for model in WhisperModel.all where downloadSizes[model.id] == nil {
            if let info = try? await store.remoteInfo(of: model) { downloadSizes[model.id] = info.bytes }
        }
    }

    /// Asks the repository whether any installed model has changed.
    func checkForUpdates() async {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        defer { checkingForUpdates = false }
        for model in WhisperModel.all where store.installation(of: model) != nil {
            do {
                if try await store.updateAvailable(for: model) { updates.insert(model.id) } else { updates.remove(model.id) }
                modelErrors[model.id] = nil
            } catch {
                modelErrors[model.id] = "Couldn't check for an update: \(error.localizedDescription)"
            }
        }
    }
}
