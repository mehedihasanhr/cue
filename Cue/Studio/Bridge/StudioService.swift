import os
import AppKit
import AVFoundation
import Foundation
import Observation
import RecordKit

nonisolated enum StudioLog {
    private static let subsystem = "com.stackrover.cue"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let bridge = Logger(subsystem: subsystem, category: "bridge")
}

/// Recording: the one object the bar, the menus and the shortcuts ask to start, pause and
/// stop a take, and that opens a finished one in the editor.
@MainActor
@Observable
final class StudioService {
    let session = RecordingSession()
    private let settings: StudioSettings

    init(settings: StudioSettings) {
        self.settings = settings
    }

    private(set) var lastRequest: RecordingRequest?
    /// The requests this app made for itself — the bar, the menus, the shortcuts — as
    /// against ones Cue sent. Only a take of this app's own is a draft until kept.
    @ObservationIgnored private var ownRequests: Set<UUID> = []
    private(set) var lastResult: RecordingResult?
    /// Called when a recording should be opened for editing.
    ///
    /// A call rather than a URL parked in a property for a scene to notice. The scene that
    /// used to notice is closed at launch, so a take that had just stopped — and a
    /// recording double-clicked in the Finder — frequently opened nothing at all. The app
    /// delegate owns the editor windows and sets this.
    @ObservationIgnored var openEditor: ((URL) -> Void)?
    /// Called instead of `openEditor` when a take of this app's own stops and quick share is
    /// on: the take is offered for sharing first, and the editor is one button away.
    @ObservationIgnored var showQuickShare: ((URL, AfterRecording) -> Void)?
    /// Where the camera preview was dragged to over what a take records, as
    /// `WebcamSettings.position` reads it; `nil` when it was left beside the bar.
    @ObservationIgnored var cameraPlacement: ((CaptureTarget) -> CGPoint?)?
    /// Said out loud when Cue asked for a folder this app cannot write to.
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
            // The microphones chosen in Settings, as `settings.configuration` already put
            // them — not the system's default in their place. Swapping in the default
            // meant the very first take after granting access recorded the built-in
            // microphone instead of the headset (or the two voices) somebody had picked.
            // The default only stands in where nothing could be named before the grant.
            if !MicrophoneRecorder.isAuthorized {
                configuration.microphoneIDs = []
            } else if configuration.microphoneIDs.isEmpty {
                configuration.microphoneIDs = [MicrophoneRecorder.defaultDevice?.uniqueID].compactMap { $0 }
            }
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
    /// The request is no longer part of the guard either. Reporting back to Cue is
    /// bookkeeping; ending the take and opening it is the thing the user asked for, and a
    /// missing request must not be able to cost them a recording. Without one, the app's
    /// own preference decides whether the editor comes up, because that is what a take
    /// nobody asked for by name is: this app's own.
    func stop() {
        guard session.state.isTaking else { return }
        clearRestart()
        let request = lastRequest
        // Read now, while the preview is still where it was during the take.
        let placement = lastTarget.flatMap { cameraPlacement?($0) }
        Task {
            switch await session.stop() {
            case .success(let url):
                if let placement { settings.placeCamera(at: placement, in: url) }
                if let request { finish(request, outcome: .finished, project: url) }
                let isOwn = request.map { ownRequests.contains($0.correlationID) } ?? true
                if isOwn, settings.afterRecording != .editor, let showQuickShare {
                    // Kept, not a draft: a take that is shared and never opened in the
                    // editor is still a take somebody wanted.
                    showQuickShare(url, settings.afterRecording)
                } else if request?.opensEditorWhenFinished ?? (settings.afterRecording == .editor || settings.opensEditorAfterRecording) {
                    // This app's own take is a draft until it is kept — see
                    // `RecordingKeep`. One Cue asked for is Cue's, and already reported.
                    if request.map({ ownRequests.contains($0.correlationID) }) ?? true {
                        RecordingKeep.markUnsaved(url)
                    }
                    openEditor?(url)
                }
                // After the draft marker, so a take that opens as a draft waits to be kept.
                DriveStorage.shared.recordingFinished(url)
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
                // Queued, not sent: the upload carries on at the next launch.
                DriveStorage.shared.recordingFinished(url)
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
    /// Counts as the same request. Cue asked for one recording and will be told about
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
        ownRequests.insert(request.correlationID)
        return request
    }

    private static func requestTarget(for target: CaptureTarget) -> RecordingRequest.Target {
        switch target {
        case .display(let id): .display(id)
        case .window(let id): .window(id)
        case .area(let display, let rect): .area(display: display, rect: rect)
        case .device(let id): .device(uniqueID: id)
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

    // MARK: - Opening recordings

    /// Opens a recording someone double-clicked, or dropped on Cue.
    func open(_ url: URL) {
        // A `.cuerec` double-clicked in Finder. The app claims the document type as its
        // owner, so the file arrives here whether or not anything is ready for it, and
        // dropping it means a recording that cannot be opened by the only app that can
        // read it.
        guard url.isFileURL, url.pathExtension.lowercased() == RecordingPackage.fileExtension else {
            StudioLog.bridge.error("Ignoring \(url.lastPathComponent, privacy: .public), which is not a recording")
            return
        }
        openEditor?(url)
    }

    // MARK: - Helpers

    /// Where this recording can actually be written.
    ///
    /// Cue can ask for a folder the user picked *in Cue*, and that grant does not
    /// cross the process boundary: both apps are sandboxed, and each one's access to a
    /// place is its own. Rather than failing at the first frame, the folder is tried now
    /// and the add-on's own library used instead, with a line saying so — the recording
    /// is the thing the user asked for, not the folder.
    private func writableDestination(for request: RecordingRequest) -> URL {
        destinationNote = nil
        guard let asked = request.destination else { return library }
        do {
            try FileManager.default.createDirectory(at: asked, withIntermediateDirectories: true)
            let probe = asked.appendingPathComponent(".cue-studio-probe")
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return asked
        } catch {
            destinationNote = "Cue can\u{2019}t write to \(asked.lastPathComponent), so this went to its own library."
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
