import AVFoundation
import Foundation
import os
import Speech

/// Listens for "Hey Cue", on this Mac, while Settings › Dictation › Hey Cue is on.
///
/// The microphone is open the whole time it runs (macOS shows its orange dot), and
/// macOS's on-device recogniser hears it; nothing is recorded or kept. A recognition
/// session is not meant to run for ever, so it starts a fresh one every 50 seconds and
/// whenever one ends. The phrase is matched loosely ("hey q", "hey queue", "hey kyu"),
/// because a recogniser has never heard of Cue.
@MainActor
final class WakeWordListener {
    var onWake: () -> Void = {}
    private(set) var isListening = false

    private let engine = AVAudioEngine()
    private var recogniser: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var refresh: Timer?

    private static let sessionLength: TimeInterval = 50
    private static let phrase = #"\b(?:hey|hi|hay)[ ,]+(?:cue|q|queue|kyu|kew|cu|coo|q\.)\b"#

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
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return false }
        // The tap runs on the audio thread and only hands buffers to whichever request is
        // current; the request is swapped on the main thread between sessions.
        let feed = WakeFeed()
        self.feed = feed
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap(feeding: feed))
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            AppleDictation.log.error("Hey Cue couldn't open the microphone: \(error.localizedDescription, privacy: .public)")
            return false
        }
        isListening = true
        beginSession()
        refresh = Timer.scheduledTimer(withTimeInterval: Self.sessionLength, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginSession() }
        }
        refresh?.tolerance = 5
        return true
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        refresh?.invalidate()
        refresh = nil
        endSession()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        feed = nil
    }

    private var feed: WakeFeed?

    private func beginSession() {
        guard isListening, let recogniser else { return }
        endSession()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .search
        request.contextualStrings = ["Hey Cue"]
        self.request = request
        feed?.request = request
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
        if heard.range(of: Self.phrase, options: .regularExpression) != nil {
            AppleDictation.log.notice("Hey Cue heard")
            endSession()
            onWake()
            return
        }
        // A session the recogniser ended (silence, an error): carry on with a new one.
        if ended { beginSession() }
    }

    // The two callbacks below run on the audio and recognition threads, not the main one.
    // Made here, outside the main actor, so Swift does not take them for main-actor code
    // (and stop the app when they are called from elsewhere).

    private nonisolated static func tap(feeding feed: WakeFeed) -> AVAudioNodeTapBlock {
        { buffer, _ in feed.append(buffer) }
    }

    private nonisolated static func results(_ handle: @escaping @MainActor (String, Bool) -> Void) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let heard = result?.bestTranscription.formattedString.lowercased() ?? ""
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

/// The hand-over between the audio thread and the current recognition request.
private nonisolated final class WakeFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }
}
