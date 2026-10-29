import AVFoundation
import Foundation
import os
import Speech

/// Listens for "Hey Cue", on this Mac, while Settings › Dictation › Hey Cue is on, and
/// then for what is said after it.
///
/// The microphone is open the whole time it runs (macOS shows its orange dot), and
/// macOS's on-device recogniser hears it; nothing is recorded or kept. The phrase is
/// matched loosely ("hey q", "hey queue", "hey kyu"), because a recogniser has never
/// heard of Cue.
///
/// After the phrase the same stream carries on, so words said in the same breath ("Hey
/// Cue, the meeting is at three") are not lost while anything else starts up: everything
/// after the phrase is reported to `onSpeech` until `endCapture()`. A recognition session
/// is not meant to run for ever, so between captures a fresh one starts every 50 seconds
/// and whenever one ends.
@MainActor
final class WakeWordListener {
    /// "Hey Cue" was heard; what followed it so far.
    var onWake: (String) -> Void = { _ in }
    /// After the phrase: everything said since it, and whether the recogniser has finished
    /// (a long silence, or an error).
    var onSpeech: (String, Bool) -> Void = { _, _ in }
    private(set) var isListening = false
    private(set) var isCapturing = false

    private let engine = AVAudioEngine()
    private var recogniser: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var refresh: Timer?
    private var watchdog: Timer?
    private var configurationObserver: NSObjectProtocol?
    private var feed: WakeFeed?
    private var sessionStart = Date.now
    /// The current session's words so far (for the debug log of what was missed).
    private var lastHeard = ""

    private static let sessionLength: TimeInterval = 50
    /// "Hey Cue" as the recogniser writes it, which is rarely "Cue": it has never heard of
    /// it, so it reaches for the nearest word it knows.
    private static let phrase = #"(?i)\b(?:hey|hi|hay|heh)[ ,]+(?:cue|cues|q|queue|kyu|kew|cu|coo|cute|kiu|que|qu)\b[.,!?]?|\b(?:hey|hay)(?:cue|q|kew)\b[.,!?]?"#
    /// How long the voice has to have been quiet before a session may be replaced, so the
    /// replacing never cuts through someone saying "Hey Cue".
    private static let quietBeforeRefresh: TimeInterval = 1.5

    /// How loud the microphone is, 0…1.
    var level: Double { feed?.level ?? 0 }

    /// Starts listening. False when speech recognition or the microphone is not allowed,
    /// or macOS cannot recognise English on this Mac.
    @discardableResult
    func start() async -> Bool {
        guard !isListening else { return true }
        guard await Self.speechAllowed(), await AVCaptureDevice.requestAccess(for: .audio) else { return false }
        guard let recogniser = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recogniser.supportsOnDeviceRecognition else {
            return false
        }
        self.recogniser = recogniser
        // The tap runs on the audio thread and only hands buffers to whichever request is
        // current; the request is swapped on the main thread between sessions.
        self.feed = WakeFeed()
        guard startEngine() else { return false }
        isListening = true
        beginSession()
        // A fresh session now and then, but only between words.
        refresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isCapturing,
                      Date.now.timeIntervalSince(self.sessionStart) >= Self.sessionLength,
                      Date.now.timeIntervalSince(self.feed?.lastVoice ?? .distantPast) >= Self.quietBeforeRefresh else { return }
                self.beginSession()
            }
        }
        refresh?.tolerance = 0.5
        // The microphone changed (headphones in or out, another input chosen, the Mac woke):
        // the engine stops by itself, and Hey Cue would go deaf until Cue was restarted.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine(because: "the microphone changed") }
        }
        // And in case it stopped some other way.
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isListening, !self.engine.isRunning else { return }
                self.restartEngine(because: "it had stopped")
            }
        }
        watchdog?.tolerance = 2
        return true
    }

    /// The tap on the microphone, and the engine running it. False when it cannot start.
    private func startEngine() -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let feed else { return false }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap(feeding: feed))
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            input.removeTap(onBus: 0)
            AppleDictation.log.error("Hey Cue couldn't open the microphone: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func restartEngine(because reason: String) {
        guard isListening else { return }
        AppleDictation.log.notice("Hey Cue restarting the microphone: \(reason, privacy: .public)")
        engine.stop()
        if startEngine() {
            // What was being said before the change is gone; a new session hears what follows.
            if !isCapturing { beginSession() }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        isCapturing = false
        refresh?.invalidate()
        refresh = nil
        watchdog?.invalidate()
        watchdog = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        endSession()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        feed = nil
    }

    /// Back to waiting for "Hey Cue", with a fresh session that has not heard any of it.
    func endCapture() {
        isCapturing = false
        beginSession()
    }

    private func beginSession() {
        guard isListening, let recogniser else { return }
        #if DEBUG
        // What the session being replaced heard, for telling why "Hey Cue" was missed.
        if !lastHeard.isEmpty {
            AppleDictation.log.debug("Hey Cue session heard: \(self.lastHeard.suffix(80), privacy: .public)")
        }
        #endif
        lastHeard = ""
        endSession()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = ["Hey Cue"]
        self.request = request
        feed?.request = request
        sessionStart = .now
        task = recogniser.recognitionTask(with: request, resultHandler: Self.results { [weak self] heard, ended in
            self?.handle(heard: heard, ended: ended)
        })
    }

    private func endSession() {
        feed?.request = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private func handle(heard: String, ended: Bool) {
        guard isListening else { return }
        if isCapturing {
            onSpeech(Self.after(heard) ?? "", ended)
            return
        }
        if let after = Self.after(heard) {
            AppleDictation.log.notice("Hey Cue heard")
            isCapturing = true
            onWake(after)
            if ended { onSpeech(after, true) }
            return
        }
        lastHeard = heard
        // A session the recogniser ended (silence, an error): carry on with a new one.
        if ended { beginSession() }
    }

    /// What was said after the first "Hey Cue" in `heard`; nil when it has none.
    static func after(_ heard: String) -> String? {
        guard let range = heard.range(of: phrase, options: .regularExpression) else { return nil }
        return String(heard[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The two callbacks below run on the audio and recognition threads, not the main one.
    // Made here, outside the main actor, so Swift does not take them for main-actor code
    // (and stop the app when they are called from elsewhere).

    private nonisolated static func tap(feeding feed: WakeFeed) -> AVAudioNodeTapBlock {
        { buffer, _ in feed.append(buffer) }
    }

    private nonisolated static func results(_ handle: @escaping @MainActor (String, Bool) -> Void) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let heard = result?.bestTranscription.formattedString ?? ""
            let ended = error != nil || result?.isFinal == true
            Task { @MainActor in handle(heard, ended) }
        }
    }

    private static func speechAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        @unknown default: return false
        }
    }
}

/// The hand-over between the audio thread and the current recognition request, and how
/// loud the last buffer was.
private nonisolated final class WakeFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var _level: Double = 0
    private var _lastVoice = Date.distantPast

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }

    var level: Double { lock.withLock { _level } }
    /// When the microphone last heard something louder than a quiet room.
    var lastVoice: Date { lock.withLock { _lastVoice } }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // -50 dB and below is silence; 0 dB is as loud as it goes (as the dictation meter).
        let decibels = 20 * log10(max(Double(rms), 1e-6))
        let level = max(0, min(1, (decibels + 50) / 50))
        lock.withLock {
            _level = level
            if level > 0.3 { _lastVoice = .now }
        }
    }
}
