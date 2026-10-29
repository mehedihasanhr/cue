import Accelerate
import AppKit
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
/// The recogniser is the costly part, so it only runs while somebody is talking: in a
/// quiet room only the microphone's loudness is measured. The first sound over a quiet
/// room starts a session, handed the second and a half before it so the "Hey" that woke
/// it is not lost; a few seconds of quiet end it again. While the Mac sleeps, its
/// screens are off or it is locked, the microphone is closed altogether.
///
/// After the phrase the same stream carries on, so words said in the same breath ("Hey
/// Cue, the meeting is at three") are not lost while anything else starts up: everything
/// after the phrase is reported to `onSpeech` until `endCapture()`. A recognition session
/// is not meant to run for ever, so one that has heard talk for 50 seconds is replaced
/// at the next pause.
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
    private var sleepObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The Mac is asleep, its screens are off, or it is locked: the microphone is closed.
    private var suspended = false
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
    /// How long a quiet room keeps a session before the recogniser is let go.
    private static let quietBeforeRest: TimeInterval = 4

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
        let feed = WakeFeed(onVoice: Self.wakeUp { [weak self] in self?.voiceHeard() })
        self.feed = feed
        guard startEngine() else { return false }
        isListening = true
        // No session yet: the first sound starts one (`voiceHeard`).
        refresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tidySession() }
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
                guard let self, self.isListening, !self.suspended, !self.engine.isRunning else { return }
                self.restartEngine(because: "it had stopped")
            }
        }
        watchdog?.tolerance = 2
        observeSleep()
        return true
    }

    /// A session, while there is talk: let go after a quiet spell, replaced after a long one.
    private func tidySession() {
        guard isListening, !isCapturing, task != nil else { return }
        let quiet = Date.now.timeIntervalSince(feed?.lastVoice ?? .distantPast)
        if quiet >= Self.quietBeforeRest {
            rest()
        } else if Date.now.timeIntervalSince(sessionStart) >= Self.sessionLength, quiet >= Self.quietBeforeRefresh {
            beginSession()
        }
    }

    /// Something louder than the room: start hearing it.
    private func voiceHeard() {
        guard isListening, !suspended, task == nil else { return }
        beginSession()
    }

    /// Back to measuring loudness only.
    private func rest() {
        #if DEBUG
        if !lastHeard.isEmpty {
            AppleDictation.log.debug("Hey Cue session heard: \(self.lastHeard.suffix(80), privacy: .public)")
        }
        #endif
        lastHeard = ""
        endSession()
    }

    // MARK: Sleep, screens off, locked

    private func observeSleep() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pause: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification), (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification), (distributed, Notification.Name("com.apple.screenIsLocked")),
        ]
        let resume: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification), (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification), (distributed, Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in pause {
            sleepObservers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            }))
        }
        for (center, name) in resume {
            sleepObservers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }))
        }
    }

    private func suspend() {
        guard isListening, !suspended else { return }
        suspended = true
        isCapturing = false
        rest()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Screens on and unlocked again (a wake alone may still show the lock screen, and
    /// then the unlock follows).
    private func resume() {
        guard isListening, suspended, !Self.screenLocked else { return }
        suspended = false
        _ = startEngine()
    }

    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
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
        guard isListening, !suspended else { return }
        AppleDictation.log.notice("Hey Cue restarting the microphone: \(reason, privacy: .public)")
        engine.stop()
        // What was being said before the change is gone; the next sound starts afresh.
        if startEngine(), !isCapturing { rest() }
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
        for (center, observer) in sleepObservers { center.removeObserver(observer) }
        sleepObservers = []
        suspended = false
        endSession()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        feed = nil
    }

    /// Back to waiting for "Hey Cue"; the next sound starts a session that has heard none of it.
    func endCapture() {
        isCapturing = false
        rest()
    }

    private func beginSession() {
        guard isListening, !suspended, let recogniser else { return }
        // What the session being replaced heard, for telling why "Hey Cue" was missed.
        rest()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = ["Hey Cue"]
        self.request = request
        sessionStart = .now
        task = recogniser.recognitionTask(with: request, resultHandler: Self.results { [weak self] heard, ended in
            self?.handle(heard: heard, ended: ended)
        })
        // After the task, so the second before (the "Hey" that woke it) is heard first.
        feed?.attach(request)
    }

    private func endSession() {
        feed?.detach()
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
        // A session the recogniser ended (silence, an error): carry on while there is
        // talk, otherwise rest until the next sound.
        guard ended else { return }
        if Date.now.timeIntervalSince(feed?.lastVoice ?? .distantPast) < Self.quietBeforeRefresh {
            beginSession()
        } else {
            rest()
        }
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

    private nonisolated static func wakeUp(_ handle: @escaping @MainActor () -> Void) -> @Sendable () -> Void {
        { Task { @MainActor in handle() } }
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
/// loud the last buffer was. With no request, the last second and a half is kept, and the
/// first loud buffer calls `onVoice`; the kept audio goes to the request that follows.
private nonisolated final class WakeFeed: @unchecked Sendable {
    private let lock = NSLock()
    private let onVoice: @Sendable () -> Void
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var _level: Double = 0
    private var _lastVoice = Date.distantPast
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFrameCount = 0
    /// `onVoice` has been called and no request has come yet.
    private var waking = false

    private static let preRollSeconds = 1.5
    /// Louder than a quiet room (about -35 dB).
    private static let voiceLevel = 0.3

    init(onVoice: @escaping @Sendable () -> Void) {
        self.onVoice = onVoice
    }

    var level: Double { lock.withLock { _level } }
    /// When the microphone last heard something louder than a quiet room.
    var lastVoice: Date { lock.withLock { _lastVoice } }

    /// From now on buffers go to `request`, starting with the ones kept.
    func attach(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.withLock {
            for buffer in preRoll { request.append(buffer) }
            preRoll = []
            preRollFrames = 0
            waking = false
            _request = request
        }
    }

    func detach() {
        lock.withLock {
            _request = nil
            waking = false
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let level = Self.level(of: buffer)
        let voice = level > Self.voiceLevel
        var wake = false
        let request: SFSpeechAudioBufferRecognitionRequest? = lock.withLock {
            _level = level
            if voice { _lastVoice = .now }
            if let request = _request { return request }
            keep(buffer)
            if voice, !waking {
                waking = true
                wake = true
            }
            return nil
        }
        request?.append(buffer)
        if wake { onVoice() }
    }

    /// A copy (the engine may reuse the buffer), and the oldest let go past the limit.
    private func keep(_ buffer: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let from = buffer.floatChannelData, let to = copy.floatChannelData else { return }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            to[channel].update(from: from[channel], count: Int(buffer.frameLength))
        }
        preRoll.append(copy)
        preRollFrames += copy.frameLength
        let limit = AVAudioFrameCount(buffer.format.sampleRate * Self.preRollSeconds)
        while preRollFrames > limit, let first = preRoll.first {
            preRollFrames -= first.frameLength
            preRoll.removeFirst()
        }
    }

    /// -50 dB and below is silence; 0 dB is as loud as it goes (as the dictation meter).
    private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(Double(rms), 1e-6))
        return max(0, min(1, (decibels + 50) / 50))
    }
}
