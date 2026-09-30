import AVFoundation
import CoreGraphics
import Foundation
import os
import ScreenCaptureKit

/// Where a take's system audio comes from, worked out before any stream is built.
///
/// ScreenCaptureKit decides whose sound a stream carries from the *same* content filter
/// that decides whose windows are in the picture: a display filter that excludes some
/// applications hears everything but them, and one that includes some applications hears
/// only them — and shows only their windows. There is no filter that says "every window,
/// but only Safari's sound". So a take that wants the whole screen and one app's audio
/// needs two streams: the screen's own, with its audio switched off, and a second one
/// whose filter includes just the chosen apps and whose picture is thrown away.
///
/// That decision is this type, and it is pure so it can be tested without a grant, a
/// display or a single running app.
public enum SystemAudioRoute: Equatable, Sendable {
    /// No system audio in this take.
    case off
    /// Everything the Mac plays, on the screen's own stream — how every take was recorded
    /// before apps could be chosen, and still the default.
    case everything
    /// Only these apps, by bundle identifier, on an audio-only stream of their own. In the
    /// order they were chosen, each once.
    case applications([String])
    /// Apps were chosen and none of them is running. ScreenCaptureKit can only include an
    /// app that exists when the filter is made, so there is nothing to listen to yet. The
    /// take still waits for one of them to launch (`listensForLaunches`); if none does, its
    /// file never gets a sample and is removed, rather than kept as a file of silence the
    /// editor would show as a sound. `recordsAudio` is false: nothing is recorded *now*.
    case nothingRunning

    /// The route for a take.
    ///
    /// - Parameters:
    ///   - systemAudio: whether the take records system audio at all.
    ///   - chosen: the apps picked in the recorder, by bundle identifier. Empty is every app.
    ///   - running: the bundle identifiers of what is running now.
    ///   - ownBundleIDs: this app and its host. Never listened to, even when chosen: the
    ///     recorder's own sounds are not part of anybody's recording.
    public static func plan(systemAudio: Bool,
                            chosen: [String],
                            running: [String],
                            ownBundleIDs: Set<String>) -> SystemAudioRoute {
        guard systemAudio else { return .off }
        guard !chosen.isEmpty else { return .everything }
        let available = Set(running).subtracting(ownBundleIDs)
        var seen: Set<String> = []
        let included = chosen.filter { available.contains($0) && seen.insert($0).inserted }
        return included.isEmpty ? .nothingRunning : .applications(included)
    }

    /// Whether an app launched during the take should be listened for: a take that hears
    /// only some apps, including one where none of them was running yet at the start.
    ///
    /// ScreenCaptureKit includes the apps that exist when a filter is made and nobody
    /// after, so Music opened a minute into a take that chose it went unheard. The take
    /// watches launches instead and rebuilds the audio stream's filter — see
    /// `RecordingSession.watchAppLaunches`.
    public var listensForLaunches: Bool {
        switch self {
        case .applications, .nothingRunning: true
        case .off, .everything: false
        }
    }

    /// Whether an app that has just launched changes whose sound this take should hear.
    ///
    /// Yes for any chosen app that is not this one — including one already in the filter,
    /// because an app that was quit and opened again is a new process, and the filter
    /// still names the old one. The filter is then rebuilt from `plan` against what is
    /// running, which puts the chosen apps back in the order they were chosen.
    public static func launchChangesFilter(launched bundleID: String?,
                                           chosen: [String],
                                           ownBundleIDs: Set<String>) -> Bool {
        guard let bundleID, !ownBundleIDs.contains(bundleID) else { return false }
        return chosen.contains(bundleID)
    }

    /// Whether the screen's own stream should carry the audio.
    public var usesScreenStream: Bool { self == .everything }

    /// Whether a file of system audio is written at all.
    public var recordsAudio: Bool {
        switch self {
        case .everything, .applications: true
        case .off, .nothingRunning: false
        }
    }
}

extension RecordingConfiguration {
    /// How the audio-only stream is set up: sound in full, and a picture as small and as
    /// rare as ScreenCaptureKit allows, because it is thrown away.
    ///
    /// ScreenCaptureKit has no audio-only stream — every stream renders a picture — so the
    /// picture is asked for at 2 × 2 once a second. `excludesCurrentProcessAudio` keeps the
    /// recorder's own sounds out, which the including filter would do anyway unless this
    /// app were chosen; it is said here as well so the promise does not rest on a list.
    public static func audioOnlyStreamConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.queueDepth = 3
        return configuration
    }
}

extension ShareableContentStore {
    /// The filter for an audio-only stream that hears exactly these apps.
    ///
    /// Built on the display being recorded, or the first display for a window: the display
    /// only decides the picture this stream throws away. Sound is not spatial, and an app
    /// is heard whichever screen its windows are on.
    public func audioFilter(including bundleIDs: [String],
                            near target: CaptureTarget,
                            in content: SCShareableContent) throws(RecordingError) -> SCContentFilter {
        let display = target.displayID.flatMap { id in content.displays.first { $0.displayID == id } }
            ?? content.displays.first
        guard let display else { throw .targetDisappeared }
        let wanted = Set(bundleIDs)
        let applications = content.applications.filter { wanted.contains($0.bundleIdentifier) }
        return SCContentFilter(display: display, including: applications, exceptingWindows: [])
    }
}

/// The chosen apps' sound, into its own file, from a stream whose picture nobody sees.
///
/// Beside `ScreenRecorder` rather than folded into it. The screen's stream is the one the
/// take lives or dies by — a window closing or a display going away ends the recording —
/// and this one is an accessory to it: if it stops on its own the take goes on, without
/// that sound, and the log says why.
///
/// Made with no filter when none of the chosen apps is running yet: it then waits, and the
/// first chosen app to launch starts it through `listen(to:)`. Its file begins with the
/// silence up to that moment, which `AudioTrackWriter` fills in, so the sound still lines
/// up with the picture; if nothing chosen ever launches, the writer has no samples and the
/// file is removed.
///
/// Driven from the main actor only — `start`, `listen(to:)` and `stop` — so `stream` and
/// `filter` are never touched from two places at once.
public final class AppAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: AudioTrackWriter
    private var filter: SCContentFilter?
    private let configuration: SCStreamConfiguration
    private var stream: SCStream?
    private var started = false

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "app-audio")

    public init(filter: SCContentFilter?, configuration: SCStreamConfiguration, writer: AudioTrackWriter) {
        self.filter = filter
        self.configuration = configuration
        self.writer = writer
        super.init()
    }

    /// Starts listening, or — with no filter yet — starts waiting for one.
    public func start() async throws(RecordingError) {
        started = true
        guard let filter else { return }
        try await open(filter)
    }

    /// Listens to the apps a new filter includes: swapped into the running stream without
    /// stopping it, or the stream opened now if it was still waiting. A refusal is logged
    /// and the old filter kept — the take goes on, as it does when this stream stops.
    public func listen(to filter: SCContentFilter) async {
        self.filter = filter
        guard started else { return }
        if let stream {
            do {
                try await stream.updateContentFilter(filter)
            } catch {
                Self.log.error("Couldn't update the app audio filter: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            do {
                try await open(filter)
            } catch {
                Self.log.error("Couldn't start listening to a launched app: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Both outputs are added: a stream with no screen output complains about every
    /// picture it has nowhere to send, and a picture a second is cheaper than a log full
    /// of that.
    private func open(_ filter: SCContentFilter) async throws(RecordingError) {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writer.queue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writer.queue)
            try await stream.startCapture()
        } catch {
            self.stream = nil
            throw .contentUnavailable(error.localizedDescription)
        }
    }

    public func stop() async {
        started = false
        try? await stream?.stopCapture()
        stream = nil
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        writer.append(buffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Self.log.error("App audio stopped: \(error.localizedDescription, privacy: .public)")
    }
}
