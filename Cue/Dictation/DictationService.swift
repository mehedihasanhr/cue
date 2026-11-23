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
    /// Downloaded models being loaded once from where they now live, so Core ML prepares
    /// them for this Mac then rather than in the middle of the first dictation.
    private(set) var preparing: Set<String> = []
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
    /// Called once when the speaker stops talking (or never starts), for a dictation that
    /// ends on a pause rather than on a button.
    @ObservationIgnored private var onPause: (() -> Void)?
    @ObservationIgnored private var heardSpeech = false
    @ObservationIgnored private var quietSince: Date?
    @ObservationIgnored private var startedAt = Date.now
    /// The loudest the microphone got in this dictation, 0…1.
    @ObservationIgnored private var peak: Double = 0
    /// Every reading of this dictation's meter, for `cue://debug/dictation`.
    @ObservationIgnored private var readings: [Double] = []
    /// The room with nobody talking: the meter followed down quickly and up slowly, so a
    /// voice barely moves it.
    @ObservationIgnored private var floor: Double?
    /// The microphone is being opened; a second start waits its turn rather than racing it.
    @ObservationIgnored private var starting = false
    /// Counts dictations. A dictation that was cancelled while its words were worked out
    /// finds the count moved on, and neither answers nor tidies up after the next one.
    @ObservationIgnored private var session = 0
    /// How the last dictation ended, for `cue://debug/dictation`.
    @ObservationIgnored private var lastOutcome = "none"
    #if DEBUG
    /// `cue://debug/dictate?action=stop&clip=…`: this file is heard in place of the recording.
    @ObservationIgnored var debugClip: URL?
    #endif

    /// How long a pause after speaking ends a dictation that ends on one.
    static let pauseLength: TimeInterval = 1.5
    /// How long such a dictation waits for the first word before giving up.
    static let waitForSpeech: TimeInterval = 8
    /// Louder than this is a voice (about -32 dB); quieter than `quietLevel`, a pause. Both
    /// rise with a noisy room (`floor`): a fan or a café is neither talk nor a pause.
    static let speechLevel = 0.35
    static let quietLevel = 0.2

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

    /// What the recogniser is set to and whether it can run, for `cue://debug/dictation`.
    var debugSummary: String {
        let engine = preferences?.dictationEngine
        let model = chosenWhisperModel
        return """
        state: \(String(describing: state))
        engine: \(engine.map(\.rawValue) ?? "unset")
        whisper model: \(preferences?.dictationWhisperModel ?? "none")  on disk: \(model != nil)
        microphone authorization: \(String(describing: AVCaptureDevice.authorizationStatus(for: .audio).rawValue))
        installed: \(WhisperModel.all.filter { store.installation(of: $0) != nil }.map(\.id))
        downloads in flight: \(downloads)  model errors: \(modelErrors)
        last dictation: \(lastOutcome)
        """
    }

    /// Starts recording for the button `id`. False when it cannot (the microphone is not
    /// allowed, or another dictation is going); the reason has been shown.
    /// With `onPause`, it is called once the speaker pauses after talking (or has said
    /// nothing for a while); the caller then finishes the dictation.
    @discardableResult
    func start(for id: UUID, onPause: (() -> Void)? = nil) async -> Bool {
        guard state == .idle, !starting else { return false }
        // The permission check can wait on macOS's prompt; meanwhile this is the start.
        starting = true
        defer { starting = false }
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
            self.onPause = onPause
            session += 1
            if preferences?.dictationAutoFormat ?? true, preferences?.dictationSmartFormat ?? true { VoiceFormatter.prewarm() }
            // The Whisper model loads while the speaker is still talking. It is let go
            // of again after a minute idle, so most dictations used to begin with a
            // cold load of several hundred megabytes — with the pill sitting on
            // "writing" throughout, which is exactly what it looked like: nothing.
            prewarmWhisper()
            heardSpeech = false
            quietSince = nil
            startedAt = .now
            peak = 0
            readings = []
            floor = nil
            startMeter()
            return true
        } catch {
            AppleDictation.log.error("Couldn't start dictation: \(error.localizedDescription, privacy: .public)")
            FeedbackHUD.show("Couldn't start dictation", symbol: "mic.slash", subtitle: error.localizedDescription)
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    /// From now on the dictation `id` ends at the next pause (`onPause` is called), as one
    /// started hands-free does; for a held key let go too soon to have meant holding it.
    func endOnPause(for id: UUID, _ onPause: @escaping () -> Void) {
        guard isListening(id) else { return }
        self.onPause = onPause
        // The wait for a first word starts again, from now.
        if !heardSpeech { startedAt = .now }
    }

    /// Stops recording and returns what was said; nil when nothing was heard, it failed
    /// (the reason has been shown), or it was cancelled while the words were worked out.
    func finish(for id: UUID) async -> String? {
        guard owner == id, state == .listening, let recorder, let clip else { return nil }
        recorder.stop()
        self.recorder = nil
        onPause = nil
        var spoke = heardSpeech
        var heard = clip
        #if DEBUG
        if let debugClip {
            heard = debugClip
            spoke = true
            self.debugClip = nil
        }
        #endif
        stopMeter()
        state = .transcribing
        let session = session
        // Only this dictation's own leftovers: after a cancel, the next may be running.
        defer {
            try? FileManager.default.removeItem(at: clip)
            if session == self.session {
                self.clip = nil
                owner = nil
                state = .idle
            }
        }
        // Nothing louder than the room: no recogniser hears it, because Whisper given
        // silence or a fan makes words up ("Thank you.") and they would be typed.
        guard spoke else {
            lastOutcome = "silent (\(levels))"
            FeedbackHUD.show("Nothing heard", symbol: "mic")
            return nil
        }
        // The first load of a model on this Mac (or after a macOS update) has Core ML prepare
        // it for the Neural Engine: a minute or two for the larger ones, with nothing to show
        // for it but "Writing". Say so, rather than look stuck.
        let slowLoad = Task { [weak self, transcriber] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.session == session, self.state == .transcribing,
                  self.preferences?.dictationEngine == .whisper, await !transcriber.isLoaded else { return }
            FeedbackHUD.show("Getting Whisper ready", symbol: "hourglass", duration: .seconds(6),
                             subtitle: "The first time on this Mac takes a minute or two.")
        }
        defer { slowLoad.cancel() }
        do {
            let started = Date.now
            var text = try await transcribe(heard)
            AppleDictation.log.info("Transcribed in \(Int(Date.now.timeIntervalSince(started) * 1000), privacy: .public) ms, \(text.count, privacy: .public) characters")
            guard session == self.session else { lastOutcome = "cancelled while writing"; return nil }
            if !text.isEmpty, preferences?.dictationAutoFormat ?? true {
                text = await VoiceFormatter.format(text, smart: preferences?.dictationSmartFormat ?? true)
            }
            guard session == self.session else { lastOutcome = "cancelled while writing"; return nil }
            lastOutcome = "text (\(levels), \(Int(Date.now.timeIntervalSince(started) * 1000)) ms): \(text)"
            if text.isEmpty { FeedbackHUD.show("Nothing heard", symbol: "mic") }
            return text.isEmpty ? nil : text
        } catch {
            AppleDictation.log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
            lastOutcome = "failed: \(error.localizedDescription)"
            guard session == self.session else { return nil }
            FeedbackHUD.show("Couldn't turn speech into text", symbol: "mic.slash", subtitle: error.localizedDescription)
            return nil
        }
    }

    /// Stops recording and throws the clip away; while the words are being worked out,
    /// drops them when they come.
    func cancel() {
        session += 1
        onPause = nil
        recorder?.stop()
        recorder = nil
        stopMeter()
        // A clip being transcribed is deleted by `finish` once the recogniser is done with it.
        if state == .listening, let clip { try? FileManager.default.removeItem(at: clip) }
        if state == .listening { lastOutcome = "cancelled (\(levels))" } else if state != .idle { lastOutcome = "cancelled" }
        clip = nil
        owner = nil
        state = .idle
    }

    /// The meter's readings in short, for `cue://debug/dictation`.
    private var levels: String {
        let sorted = readings.sorted()
        func at(_ fraction: Double) -> String {
            sorted.isEmpty ? "-" : String(format: "%.2f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))])
        }
        return "levels p10 \(at(0.1)) p50 \(at(0.5)) p90 \(at(0.9)) peak \(String(format: "%.2f", peak)) room \(String(format: "%.2f", floor ?? 0)), \(readings.count) readings, voice: \(heardSpeech)"
    }

    /// Starts loading the Whisper model, if that is the engine, without waiting for it.
    private func prewarmWhisper() {
        guard preferences?.dictationEngine == .whisper, let model = chosenWhisperModel else { return }
        let transcriber = transcriber
        Task.detached(priority: .userInitiated) {
            let started = Date.now
            await transcriber.prewarm(model)
            AppleDictation.log.info("Whisper \(model.id, privacy: .public) ready in \(Int(Date.now.timeIntervalSince(started) * 1000), privacy: .public) ms")
        }
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
        let meter = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                // -50 dB and below is silence; 0 dB is as loud as it goes.
                self.level = max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
                self.peak = max(self.peak, self.level)
                self.readings.append(self.level)
                self.listen()
            }
        }
        // In the common modes, so the meter (and the pause that ends a hands-free
        // dictation) keeps going while a menu is open or something is being dragged.
        RunLoop.main.add(meter, forMode: .common)
        self.meter = meter
    }

    /// Tells a voice from the room, and fires `onPause` once the voice has gone quiet
    /// after speaking, or never came.
    private func listen() {
        let now = Date.now
        // The room is taken to be quiet at first (the speaker may start at once, and the
        // meter reads nothing for its first moments), and found out as the dictation goes.
        if level > 0 {
            let floor = floor ?? min(level, Self.quietLevel)
            self.floor = level < floor ? (floor + level) / 2 : floor + (level - floor) * 0.005
        }
        let room = floor ?? 0
        if level > max(Self.speechLevel, room + 0.2) {
            heardSpeech = true
            quietSince = nil
        } else if level < max(Self.quietLevel, room + 0.08) {
            quietSince = quietSince ?? now
        }
        guard let onPause else { return }
        let paused = heardSpeech && quietSince.map { now.timeIntervalSince($0) >= Self.pauseLength } == true
        let silent = !heardSpeech && now.timeIntervalSince(startedAt) >= Self.waitForSpeech
        guard paused || silent else { return }
        self.onPause = nil
        onPause()
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
                // Loaded once more from its own folder, so the first dictation does not
                // wait for Core ML to prepare it.
                downloads[id] = nil
                changes += 1
                preparing.insert(id)
                await transcriber.prewarm(model)
                preparing.remove(id)
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
