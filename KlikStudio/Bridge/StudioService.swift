import os
import AddOnKit
import AppKit
import AVFoundation
import Foundation
import Observation
import RecordKit

nonisolated enum StudioLog {
    private static let subsystem = "com.stackrover.klik.studio"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let bridge = Logger(subsystem: subsystem, category: "bridge")
}

/// The add-on's side of the contract.
///
/// One object answers "what can I do?" and "do this", whichever transport asked — a
/// launch URL today, the App Group Mach service once the helper exists. Keeping the
/// transport out of here is what makes that swap a change of one file.
@MainActor
@Observable
final class StudioService: StudioRecording {
    let session = RecordingSession()
    private let settings: StudioSettings

    init(settings: StudioSettings) {
        self.settings = settings
    }

    private(set) var lastRequest: RecordingRequest?
    private(set) var lastResult: RecordingResult?
    /// Set when a finished recording should be opened for editing. The window scene
    /// watches this, because opening a window is SwiftUI's job, not a service's.
    private(set) var pendingEditorURL: URL?
    /// Said out loud when Klik asked for a folder this app cannot write to.
    private(set) var destinationNote: String?

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Where finished recordings go, as Settings has it.
    var library: URL { settings.library }

    var isRecording: Bool {
        if case .recording = session.state { return true }
        return false
    }

    /// What this build can actually do.
    ///
    /// Reported honestly rather than optimistically: the host asks before it offers, so
    /// a capability claimed here becomes a menu item that fails. GIF export and captions
    /// are still false — they arrive with their own milestones.
    nonisolated func capabilities() async -> StudioCapabilities {
        await MainActor.run {
            StudioCapabilities(version: version,
                               canRecordDisplay: true,
                               canRecordWindow: true,
                               canRecordArea: true,
                               canRecordSystemAudio: true,
                               canRecordMicrophone: MicrophoneRecorder.isAuthorized,
                               canRecordWebcam: false,
                               canEdit: true,
                               canExportGIF: false,
                               canCaption: false)
        }
    }

    nonisolated func beginRecording(_ request: RecordingRequest) async throws -> RecordingResult {
        await MainActor.run { start(request) }
        return RecordingResult(correlationID: request.correlationID, outcome: .finished)
    }

    nonisolated func cancelRecording(_ correlationID: UUID) async {
        await MainActor.run { Task { await session.cancel() } }
    }

    // MARK: - Recording

    /// Starts recording what a request asked for.
    ///
    /// A request that says "ask me" records the display the pointer is on. That is the
    /// right default for a menu-bar command and it is what the source picker will
    /// pre-select when there is one.
    func start(_ request: RecordingRequest) {
        lastRequest = request
        StudioLog.bridge.notice("Request \(request.correlationID.uuidString, privacy: .public) received")

        guard !session.state.isBusy else {
            finish(request, outcome: .failed, message: RecordingError.alreadyRecording.localizedDescription)
            return
        }

        let target = CaptureTarget(request.target) ?? .display(Self.displayUnderPointer())
        // Settings say *how* to record — frame rate, quality, encoder, what the pointer
        // does. The request says *what* to record and what to do afterwards. A request
        // can switch a track off, never on: turning on a microphone the user did not ask
        // this app to use is not something another app gets to decide.
        var configuration = settings.configuration(target: target,
                                                   name: Self.name(for: Date.now),
                                                   destination: writableDestination(for: request))
        configuration.systemAudio = configuration.systemAudio && request.systemAudio
        if !request.microphone { configuration.microphoneID = nil }

        Task {
            if request.microphone, settings.recordsMicrophone, !MicrophoneRecorder.isAuthorized {
                _ = await MicrophoneRecorder.requestAccess()
                configuration.microphoneID = MicrophoneRecorder.isAuthorized ? MicrophoneRecorder.defaultDevice?.uniqueID : nil
            }
            await session.start(configuration, countdown: max(0, request.countdownSeconds))
            if case .failed(let error) = session.state {
                finish(request, outcome: .failed, message: error.localizedDescription)
            }
        }
    }

    /// Records what the recorder window has selected, with this app's own settings.
    func record(target: CaptureTarget) {
        var request = RecordingRequest(microphone: settings.recordsMicrophone,
                                       systemAudio: settings.recordsSystemAudio,
                                       countdownSeconds: settings.countdownSeconds,
                                       opensEditorWhenFinished: settings.opensEditorAfterRecording)
        switch target {
        case .display(let id): request.target = .display(id)
        case .window(let id): request.target = .window(id)
        case .area(let display, let rect): request.target = .area(display: display, rect: rect)
        }
        start(request)
    }

    /// Holds a recording, or lets it carry on.
    func togglePause() {
        session.isPaused ? session.resume() : session.pause()
    }

    /// Stops the recording and records where it landed.
    func stop() {
        guard case .recording = session.state, let request = lastRequest else { return }
        Task {
            switch await session.stop() {
            case .success(let url):
                finish(request, outcome: .finished, project: url)
                if request.opensEditorWhenFinished { pendingEditorURL = url }
            case .failure(let error):
                finish(request, outcome: .failed, message: error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard let request = lastRequest else { return }
        Task {
            await session.cancel()
            finish(request, outcome: .cancelled)
        }
    }

    private func finish(_ request: RecordingRequest,
                        outcome: RecordingResult.Outcome,
                        project: URL? = nil,
                        message: String? = nil) {
        lastResult = RecordingResult(correlationID: request.correlationID,
                                     outcome: outcome,
                                     project: project,
                                     message: message)
        StudioLog.bridge.notice("Request \(request.correlationID.uuidString, privacy: .public) \(outcome.rawValue, privacy: .public)")
    }

    // MARK: - Requests from Klik

    /// Reads a request the host left on disk.
    ///
    /// The path arrives in a URL, and anything on this Mac can open a URL scheme, so
    /// nothing here trusts it: the file has to be readable and decode as a request. One
    /// that is neither is dropped rather than guessed at.
    func acceptRequest(at file: URL) {
        guard file.pathExtension == "json" else {
            StudioLog.bridge.error("Ignoring a request that is not a JSON file")
            return
        }
        do {
            start(try RequestFile.read(at: file))
            try? FileManager.default.removeItem(at: file)
        } catch {
            StudioLog.bridge.error("Unreadable request at \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Handles a `klik-studio://` URL or a recording someone opened, whoever opened it.
    func open(_ url: URL) {
        // A `.klikrec` double-clicked in Finder. The app claims the document type as its
        // owner, so the file arrives here whether or not anything is ready for it, and
        // dropping it means a recording that cannot be opened by the only app that can
        // read it.
        if url.isFileURL {
            guard url.pathExtension.lowercased() == RecordingPackage.fileExtension else {
                StudioLog.bridge.error("Ignoring \(url.lastPathComponent, privacy: .public), which is not a recording")
                return
            }
            pendingEditorURL = url
            return
        }
        guard let file = RequestFile.file(from: url) else {
            StudioLog.bridge.error("Ignoring \(url.scheme ?? "a", privacy: .public) URL that is not a recording request")
            return
        }
        acceptRequest(at: file)
    }

    func editorWindowOpened() { pendingEditorURL = nil }

    // MARK: - Helpers

    /// Where this recording can actually be written.
    ///
    /// Klik can ask for a folder the user picked *in Klik*, and that grant does not
    /// cross the process boundary: both apps are sandboxed, and each one's access to a
    /// place is its own. Rather than failing at the first frame, the folder is tried now
    /// and the add-on's own library used instead, with a line saying so — the recording
    /// is the thing the user asked for, not the folder.
    private func writableDestination(for request: RecordingRequest) -> URL {
        destinationNote = nil
        guard let asked = request.destination else { return library }
        do {
            try FileManager.default.createDirectory(at: asked, withIntermediateDirectories: true)
            let probe = asked.appendingPathComponent(".klik-studio-probe")
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return asked
        } catch {
            destinationNote = "Klik Studio can\u{2019}t write to \(asked.lastPathComponent), so this went to its own library."
            StudioLog.bridge.notice("Falling back to the library: \(error.localizedDescription, privacy: .public)")
            return library
        }
    }

    /// The display the pointer is on, falling back to the main one.
    private static func displayUnderPointer() -> CGDirectDisplayID {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
    }

    /// A name a person can find again: the date and time it was taken.
    private static func name(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Recording \(formatter.string(from: date))"
    }
}
