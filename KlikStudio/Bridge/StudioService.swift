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
    /// Called when a recording should be opened for editing.
    ///
    /// A call rather than a URL parked in a property for a scene to notice. The scene that
    /// used to notice is closed at launch, so a take that had just stopped — and a
    /// recording double-clicked in the Finder — frequently opened nothing at all. The app
    /// delegate owns the editor windows and sets this.
    @ObservationIgnored var openEditor: ((URL) -> Void)?
    /// Said out loud when Klik asked for a folder this app cannot write to.
    private(set) var destinationNote: String?

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Where finished recordings go, as Settings has it.
    var library: URL { settings.library }

    /// Whether a take is under way, as the host asks it.
    ///
    /// `isTaking` rather than a match on `.recording`: a take on hold is still a take, and
    /// a host told "nothing is recording" would offer to start a second one.
    var isRecording: Bool { session.state.isTaking }

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
                               // True now that there is a recorder and a renderer behind it.
                               // Reported on the grant rather than unconditionally, like the
                               // microphone: a host that offers "record with camera" and then
                               // hits a permission wall has been told the wrong thing.
                               canRecordWebcam: WebcamRecorder.isAuthorized,
                               canEdit: true,
                               canExportGIF: true,
                               canCaption: true)
        }
    }

    nonisolated func beginRecording(_ request: RecordingRequest) async throws -> RecordingResult {
        await MainActor.run { start(request) }
        return RecordingResult(correlationID: request.correlationID, outcome: .finished)
    }

    nonisolated func cancelRecording(_ correlationID: UUID) async {
        await session.cancel()
    }

    // MARK: - Recording

    /// Starts recording what a request asked for.
    ///
    /// A request that says "ask me" records the display the pointer is on. That is the
    /// right default for a menu-bar command and it is what the source picker will
    /// pre-select when there is one.
    func start(_ request: RecordingRequest) {
        guard let configuration = accept(request) else { return }
        Task { await begin(request, configuration: configuration) }
    }

    /// Everything `start` decides before anything waits: the target, the settings, the
    /// name. `nil` when a take is already under way, which has been reported.
    ///
    /// Split from the waiting half so Restart can run both back to back in one task —
    /// with a `Task` between them, the bar would be idle for a frame and flash the setup
    /// layout between the take thrown away and the one starting.
    private func accept(_ request: RecordingRequest) -> RecordingConfiguration? {
        lastRequest = request
        StudioLog.bridge.notice("Request \(request.correlationID.uuidString, privacy: .public) received")

        guard !session.state.isBusy else {
            finish(request, outcome: .failed, message: RecordingError.alreadyRecording.localizedDescription)
            return nil
        }

        let target = CaptureTarget(request.target) ?? .display(Self.displayUnderPointer())
        lastTarget = target
        // A question left over from a take that ended on its own — a closed window, a full
        // disk — must not be asked over the next one.
        clearRestart()
        // Settings say *how* to record — frame rate, quality, encoder, what the pointer
        // does. The request says *what* to record and what to do afterwards. A request
        // can switch a track off, never on: turning on a microphone the user did not ask
        // this app to use is not something another app gets to decide.
        var configuration = settings.configuration(target: target,
                                                   name: Self.name(for: Date.now),
                                                   destination: writableDestination(for: request))
        configuration.systemAudio = configuration.systemAudio && request.systemAudio
        if !request.microphone { configuration.microphoneIDs = [] }
        // The same rule, and it matters most here: a request can switch the camera off but
        // never on. `settings.configuration` only set a `webcamID` if this app's own camera
        // toggle is on, and no other app gets to decide that a face is being filmed. There
        // is deliberately no branch that asks for camera permission on a host's behalf.
        if !request.webcam { configuration.webcamID = nil }
        return configuration
    }

    /// The half of starting that waits: the microphone grant, then the session's own
    /// preparing and countdown.
    private func begin(_ request: RecordingRequest, configuration: RecordingConfiguration) async {
        var configuration = configuration
        if request.microphone, settings.recordsMicrophone, !MicrophoneRecorder.isAuthorized {
            _ = await MicrophoneRecorder.requestAccess()
            configuration.microphoneIDs = MicrophoneRecorder.isAuthorized
                ? [MicrophoneRecorder.defaultDevice?.uniqueID].compactMap { $0 }
                : []
        }
        await session.start(configuration, countdown: max(0, request.countdownSeconds))
        if case .failed(let error) = session.state {
            finish(request, outcome: .failed, message: error.localizedDescription)
        }
    }

    /// Records what the recorder window has selected, with this app's own settings.
    func record(target: CaptureTarget) {
        start(request(for: target))
    }

    /// Holds a recording, or lets it carry on.
    ///
    /// While Restart is asking, resuming is the answer "keep it": the take was paused to
    /// ask, and carrying on is carrying on with this one.
    func togglePause() {
        if restartPending {
            keepTake()
            return
        }
        session.isPaused ? session.resume() : session.pause()
    }

    /// Stops the recording and records where it landed.
    ///
    /// The guard is `isTaking`, which is the property the bar's Stop button is enabled by:
    /// it used to be `case .recording`, so stopping a paused take fell through here in
    /// silence and the only thing left that worked was Discard.
    ///
    /// The request is no longer part of the guard either. Reporting back to Klik is
    /// bookkeeping; ending the take and opening it is the thing the user asked for, and a
    /// missing request must not be able to cost them a recording. Without one, the app's
    /// own preference decides whether the editor comes up, because that is what a take
    /// nobody asked for by name is: this app's own.
    func stop() {
        guard session.state.isTaking else { return }
        clearRestart()
        let request = lastRequest
        Task {
            switch await session.stop() {
            case .success(let url):
                if let request { finish(request, outcome: .finished, project: url) }
                if request?.opensEditorWhenFinished ?? settings.opensEditorAfterRecording {
                    openEditor?(url)
                }
            case .failure(let error):
                if let request { finish(request, outcome: .failed, message: error.localizedDescription) }
            }
        }
    }

    /// Throws the take away — a cancelled countdown, or one the user does not want kept.
    ///
    /// Same reasoning as `stop()`: discarding is what was asked for, and the report is a
    /// consequence of it rather than a precondition for it.
    func cancel() {
        clearRestart()
        let request = lastRequest
        Task {
            await session.cancel()
            if let request { finish(request, outcome: .cancelled) }
        }
    }

    /// Ends what is under way because the app is quitting.
    ///
    /// A take is stopped and saved — and not opened, since the app is leaving. A countdown
    /// is called off: nothing has been recorded yet. A stop already in progress is waited
    /// for, so the file is closed before the process goes.
    func finishBeforeQuitting() async {
        let request = lastRequest
        if session.state.isTaking {
            switch await session.stop() {
            case .success(let url):
                if let request { finish(request, outcome: .finished, project: url) }
            case .failure(let error):
                if let request { finish(request, outcome: .failed, message: error.localizedDescription) }
            }
        } else if session.state.isStarting {
            await session.cancel()
            if let request { finish(request, outcome: .cancelled) }
        }
        while session.state == .finishing {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Puts a reported failure away, so the bar can go back to offering a take.
    func dismissFailure() {
        session.acknowledgeFailure()
    }

    // MARK: - Restart, markers, and starting from anywhere

    /// The target the take under way was started with, already resolved — so a restart
    /// records the same display, window or area even when the request said "ask me".
    private var lastTarget: CaptureTarget?

    /// Restart has been asked for and is waiting to be confirmed. The take is paused
    /// meanwhile, so the seconds spent deciding are not in it if it is kept.
    private(set) var restartPending = false
    /// Whether it was this that paused the take, so "keep it" resumes only what it held.
    private var pausedForRestart = false

    /// Restart, as the button, the shortcut and the menu ask for it: at once for a take of
    /// ten seconds or less, which is a false start; asked about for anything longer — or
    /// whatever length Settings › Recording says instead. Asked
    /// twice — the shortcut pressed again while the bar is asking — is the answer yes.
    func requestRestart() {
        guard session.state.isTaking else { return }
        if restartPending {
            restart()
            return
        }
        guard settings.app.restartNeedsConfirmation(recordedSeconds: session.state.recordedSeconds(at: .now)) else {
            restart()
            return
        }
        if !session.isPaused {
            session.pause()
            pausedForRestart = true
        }
        restartPending = true
    }

    /// Carries on with the take after all.
    func keepTake() {
        let resume = pausedForRestart
        clearRestart()
        if resume, session.isPaused { session.resume() }
    }

    private func clearRestart() {
        restartPending = false
        pausedForRestart = false
    }

    /// Throws the take away and starts again: same target, same settings, same countdown.
    ///
    /// Counts as the same request. Klik asked for one recording and will be told about
    /// the one that is kept, not about the false start before it.
    func restart() {
        guard session.state.isTaking, let target = lastTarget else { return }
        clearRestart()
        var request = lastRequest ?? request(for: target)
        request.target = Self.requestTarget(for: target)
        let discarded = session.packageURL
        Task {
            await session.cancel()
            // The session deletes the package itself; this is the check that it did,
            // marker and all, so the library never offers the false start as interrupted.
            if !TakeRestart.removeLeftovers(of: discarded) {
                StudioLog.app.error("A restarted take was left on disk: \(discarded?.lastPathComponent ?? "?", privacy: .public)")
            }
            guard let configuration = accept(request) else { return }
            await begin(request, configuration: configuration)
        }
    }

    /// Drops a marker at this moment of the take.
    func addMarker() {
        session.addMarker()
    }

    /// Starts or stops, as the global shortcut and the menu bar icon mean it: stop a take,
    /// call off a countdown, or start one of `target` — the display the pointer is on when
    /// nothing has been chosen.
    func toggleRecording(target: CaptureTarget?) {
        let state = session.state
        if state.isTaking {
            stop()
        } else if state.isStarting {
            cancel()
        } else if !state.isBusy {
            if case .failed = state { dismissFailure() }
            record(target: target ?? .display(Self.displayUnderPointer()))
        }
    }

    /// The request the recorder window makes for a target, with this app's own settings.
    private func request(for target: CaptureTarget) -> RecordingRequest {
        var request = RecordingRequest(microphone: settings.recordsMicrophone,
                                       systemAudio: settings.recordsSystemAudio,
                                       webcam: settings.recordsCamera,
                                       countdownSeconds: settings.countdownSeconds,
                                       opensEditorWhenFinished: settings.opensEditorAfterRecording)
        request.target = Self.requestTarget(for: target)
        return request
    }

    private static func requestTarget(for target: CaptureTarget) -> RecordingRequest.Target {
        switch target {
        case .display(let id): .display(id)
        case .window(let id): .window(id)
        case .area(let display, let rect): .area(display: display, rect: rect)
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
            openEditor?(url)
            return
        }
        guard let file = RequestFile.file(from: url) else {
            StudioLog.bridge.error("Ignoring \(url.scheme ?? "a", privacy: .public) URL that is not a recording request")
            return
        }
        acceptRequest(at: file)
    }

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
