import AVFoundation
import CoreMedia
import Foundation
import os
import Speech
import TimelineKit

/// Turns the recorded speech into lines of text on the timeline.
///
/// On-device recognition, insisted on rather than merely preferred: a screen recording
/// is very often of something not meant to leave the machine, and quietly uploading its
/// audio to a server to save a second of processing is not a trade this app gets to make
/// on someone's behalf. Where a language has no on-device model the answer is to say so,
/// not to fall back to the network.
///
/// Times come back in the *recording's* clock and are mapped onto the edit before they
/// become cues, so captions still line up after a trim, a reorder or a speed change.
enum CaptionGenerator {
    enum Failure: Error, Equatable {
        case notAuthorised
        case noRecogniser(String)
        case unavailableOffline(String)
        case noSpeechFound
        case failed(String)

        var message: String {
            switch self {
            case .notAuthorised:
                "Klik Studio needs permission to use speech recognition. Turn it on in System Settings › Privacy & Security › Speech Recognition."
            case .noRecogniser(let language):
                "macOS has no speech recogniser for \(language)."
            case .unavailableOffline(let language):
                "The \(language) speech model isn't on this Mac yet. Add the language in System Settings › General › Language & Region, then try again."
            case .noSpeechFound:
                "No speech was found in this recording."
            case .failed(let detail):
                "Captions couldn't be generated. \(detail)"
            }
        }
    }

    /// How long a single caption may run before it is broken in two.
    ///
    /// Short: a subtitle is read in a glance, and a ten-second line means the viewer is
    /// reading the beginning of a sentence while hearing the end of it.
    private static let maximumCueDuration: Double = 3.5
    /// A pause longer than this ends the line, whatever its length — it is where the
    /// speaker themselves stopped.
    private static let sentenceGap: Double = 0.55
    private static let maximumWordsPerCue = 12

    /// One recognised word, as plain data.
    ///
    /// `SFTranscriptionSegment` is a class and is not `Sendable`, so it must not leave
    /// the recogniser's callback — the three numbers that matter are copied out there
    /// and everything downstream works on values.
    struct Word: Sendable, Equatable {
        var text: String
        var start: Double
        var duration: Double

        var end: Double { start + duration }
    }

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "captions")

    /// Asks the system, once, whether we may listen to the recording at all.
    static func authorise() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }

    /// Recognises the speech in a recording and returns it as cues on `timeline`.
    static func cues(for videoURL: URL,
                     timeline: Timeline,
                     locale: Locale = .current) async throws(Failure) -> [CaptionCue] {
        guard await authorise() else { throw Failure.notAuthorised }

        let language = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        guard let recogniser = SFSpeechRecognizer(locale: locale) else {
            throw Failure.noRecogniser(language)
        }
        guard recogniser.isAvailable else { throw Failure.failed("The recogniser isn't available right now.") }
        guard recogniser.supportsOnDeviceRecognition else {
            throw Failure.unavailableOffline(language)
        }

        let request = SFSpeechURLRecognitionRequest(url: videoURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        let words: [Word]
        do {
            words = try await recognise(request, with: recogniser)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        guard !words.isEmpty else { throw Failure.noSpeechFound }

        let cues = group(words, on: timeline)
        guard !cues.isEmpty else { throw Failure.noSpeechFound }
        Self.log.notice("Recognised \(words.count) words as \(cues.count) captions")
        return cues
    }

    /// The callback API, awaited once.
    ///
    /// `shouldReportPartialResults` is off, so exactly one final result arrives — but
    /// the continuation is guarded anyway: a recogniser that calls back twice would
    /// otherwise crash the app rather than produce a bad caption.
    private static func recognise(_ request: SFSpeechURLRecognitionRequest,
                                  with recogniser: SFSpeechRecognizer) async throws -> [Word] {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            recogniser.recognitionTask(with: request) { result, error in
                let alreadyResumed = resumed.withLock { done -> Bool in
                    if done { return true }
                    if error != nil || result?.isFinal == true { done = true; return false }
                    return true
                }
                guard !alreadyResumed else { return }

                if let error {
                    continuation.resume(throwing: error)
                } else {
                    // Copied to values here, inside the callback, so nothing the
                    // recogniser owns crosses back to the caller.
                    let words = (result?.bestTranscription.segments ?? []).map {
                        Word(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    }
                    continuation.resume(returning: words)
                }
            }
        }
    }

    /// Words into lines.
    ///
    /// Broken at the speaker's own pauses first, and only then at a length limit: a
    /// caption that ends where the sentence does reads as writing, one that ends after
    /// exactly twelve words reads as a machine.
    static func group(_ recognised: [Word], on timeline: Timeline) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var words: [String] = []
        var start: Double?
        var end: Double = 0

        func flush() {
            defer { words.removeAll(); start = nil }
            guard let start, !words.isEmpty else { return }
            // Source times onto the edit. A word spoken in footage that was cut has
            // nowhere to go, and is dropped rather than shown at the wrong moment.
            guard let from = timeline.timelineTime(atSource: CMTime(seconds: start, preferredTimescale: 600)),
                  let to = timeline.timelineTime(atSource: CMTime(seconds: end, preferredTimescale: 600)),
                  to > from else { return }
            cues.append(CaptionCue(start: from, duration: to - from, text: words.joined(separator: " ")))
        }

        for word in recognised {
            if let first = start {
                let gap = word.start - end
                if gap > sentenceGap
                    || word.end - first > maximumCueDuration
                    || words.count >= maximumWordsPerCue {
                    flush()
                }
            }
            if start == nil { start = word.start }
            words.append(word.text)
            end = word.end
        }
        flush()

        // Overlaps would put two lines on screen at once; the renderer shows only the
        // later one, so trimming here is what keeps what is drawn and what is stored the
        // same thing.
        for index in cues.indices.dropLast() where cues[index].end > cues[index + 1].start {
            cues[index].duration = cues[index + 1].start - cues[index].start
        }
        return cues.filter { $0.duration.seconds > 0.1 }
    }
}
