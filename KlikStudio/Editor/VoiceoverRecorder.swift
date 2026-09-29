// `@preconcurrency`: `AVCaptureSession` is not marked `Sendable`, and starting one off the
// main thread is what Apple's own documentation says to do.
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Observation
import os
import RecordKit

/// The microphone, against the edit: narration recorded while the preview plays.
///
/// **Why not `MicrophoneRecorder`.** That one exists for the other half of the app, and it
/// is right for what it does: screen recording needs microphone audio as
/// `CMSampleBuffer`s on the writer's queue, interleaved with screen audio into one file by
/// one clock. A voiceover needs none of that. It is a file at a time, on its own, and the
/// only thing that has to be true of it is that it starts where the playhead was. So this
/// takes the same `AVCaptureSession` route — which is what gives us the user's chosen
/// input device for free, an `AVAudioRecorder` cannot pick one, and an `AVAudioEngine`
/// would mean reaching through to the input unit's HAL device to do it — and hands the
/// session an `AVCaptureAudioFileOutput`, which writes the file itself. No writer, no
/// second clock, no encoder settings to keep in step with the exporter.
///
/// **How the punch-in is guaranteed.** Not by noting the time a button was pressed. The
/// order is: arm the device, count in while nothing moves, ask the file output to start,
/// and only when it reports back that the file is open does the transport roll — from the
/// playhead, through `PreviewAudio.play(from:)`, which is the clock the playhead follows
/// while playing. So the first sample in the file and timeline time `punchIn` are the same
/// instant by construction, rather than by two clocks being compared afterwards. The
/// remaining error is the input device's own latency, which is a couple of milliseconds
/// and is not something a screen recording is cut against.
@MainActor
@Observable
final class VoiceoverRecorder {
    /// Where a take has got to.
    ///
    /// One enum rather than a handful of booleans, because "counting in" and "recording"
    /// and "waiting for the file to open" are mutually exclusive, and a UI that could show
    /// two of them at once would be showing a state this cannot be in.
    enum State: Equatable {
        case idle
        /// Armed, device warm, nothing being written yet.
        case countingIn(remaining: Int)
        /// The file output has been asked to start; waiting for it to say it has.
        case opening
        case recording(since: Date)
        /// Stopping, and waiting for the file to be closed and flushed.
        case finishing

        var isBusy: Bool { self != .idle }
    }

    private(set) var state: State = .idle

    /// Called the moment the file is open, with the take's punch-in point left to the
    /// caller: it owns the playhead, and it is what starts the transport.
    private let onPunchIn: () -> Void
    /// Called with the finished file, or with why there isn't one. The file is somewhere
    /// temporary; the caller decides whether it belongs in the project.
    private let onFinish: (Result<URL, Error>) -> Void

    private let deviceID: String?
    private let countIn: Int

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var delegate: FileOutputBridge?
    private var ticker: Timer?
    private var fileURL: URL?

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "voiceover")

    /// `deviceID` is `StudioSettings.microphoneID` — empty means whatever the system calls
    /// the default input, which is also what happens when the named device has been
    /// unplugged since it was chosen.
    init(deviceID: String?,
         countIn: Int,
         onPunchIn: @escaping () -> Void,
         onFinish: @escaping (Result<URL, Error>) -> Void) {
        self.deviceID = deviceID
        self.countIn = max(0, countIn)
        self.onPunchIn = onPunchIn
        self.onFinish = onFinish
    }

    // MARK: - Permission

    /// Asks for the microphone, honestly: it returns what the user said rather than
    /// carrying on and producing a silent file.
    ///
    /// Asking is separate from arming because only the caller knows whether now is a
    /// reasonable moment for a system dialog — the same division `MicrophoneRecorder`
    /// already makes, and the same authorization state, so granting it once covers both.
    static func requestAccess() async throws(RecordingError) {
        if MicrophoneRecorder.isAuthorized { return }
        guard await MicrophoneRecorder.requestAccess() else { throw .microphoneDenied }
    }

    // MARK: - Arming

    /// Warms the device up, then counts in.
    ///
    /// Everything slow happens before the count-in and during it — finding the device,
    /// building the session, `startRunning` blocking while the input warms up — for the
    /// same reason the screen recorder's countdown does: by the time the number reaches
    /// zero there is nothing left to do but open the file, so "0" and the first word are
    /// the same moment rather than a device warm-up apart.
    func arm() throws(RecordingError) {
        guard !state.isBusy else { throw .alreadyRecording }

        let device = Self.device(matching: deviceID)
        guard let device else { throw .deviceLost("The microphone") }

        let session = AVCaptureSession()
        let output = AVCaptureAudioFileOutput()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw .deviceLost(device.localizedName)
        }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw .deviceLost(device.localizedName)
        }
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        self.session = session
        self.output = output
        delegate = FileOutputBridge(
            didStart: { [weak self] in Task { @MainActor in self?.punchedIn() } },
            didFinish: { [weak self] url, error in Task { @MainActor in self?.closed(url, error: error) } }
        )

        // `startRunning` blocks while the device comes up. Off the main thread, so a slow
        // USB interface cannot freeze the editor at the very moment it is showing a
        // count-in — and reported back, because a session that is not yet running answers
        // a request to write a file with an error rather than with a recording.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            session.startRunning()
            Task { @MainActor in self?.deviceIsWarm() }
        }

        guard countIn > 0 else {
            state = .opening
            open()
            return
        }
        state = .countingIn(remaining: countIn)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard case .countingIn(let remaining) = state else { return }
        if remaining > 1 {
            state = .countingIn(remaining: remaining - 1)
        } else {
            stopTicker()
            state = .opening
            open()
        }
    }

    /// The device is up. With a count-in this has almost always happened long before the
    /// number reaches zero; with the count-in turned off it usually has not, which is the
    /// case this exists for.
    private func deviceIsWarm() {
        isWarm = true
        guard opensWhenWarm else { return }
        opensWhenWarm = false
        open()
    }

    private var isWarm = false
    private var opensWhenWarm = false

    private func open() {
        guard let output, let delegate else { return }
        guard isWarm else {
            opensWhenWarm = true
            return
        }
        // A fresh file per take, in the temporary directory rather than in the package:
        // a take that is abandoned, or that turns out to have no room on the timeline,
        // must not leave anything behind in somebody's project.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceover-\(UUID().uuidString).m4a")
        fileURL = url
        output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: delegate)
    }

    /// The file is open. This is the instant the take begins, and the only instant the
    /// punch-in point may be read at.
    private func punchedIn() {
        guard state == .opening else { return }
        state = .recording(since: .now)
        onPunchIn()
    }

    // MARK: - Stopping

    /// Ends the take. Safe to call from anywhere and more than once — the transport calls
    /// it when the playhead reaches the end of the edit, the inspector calls it from the
    /// same button that started it, and a window closing calls it too.
    func stop() {
        switch state {
        case .idle, .finishing:
            return
        case .countingIn:
            // Nothing has been written, so there is nothing to keep and nothing to say.
            cancel()
        case .opening where opensWhenWarm:
            // Asked to open, but the device has not finished warming up and the file
            // output has not been given the job yet. Nothing has been written, and waiting
            // for a callback that will never come would leave the panel saying "Saving the
            // take…" for ever.
            cancel()
        case .opening, .recording:
            state = .finishing
            output?.stopRecording()
        }
    }

    /// Gives up without producing a take: a count-in someone thought better of, a window
    /// on its way out.
    func cancel() {
        let wasBusy = state.isBusy
        stopTicker()
        teardown()
        state = .idle
        if wasBusy { onFinish(.failure(RecordingError.cancelled)) }
    }

    private func closed(_ url: URL, error: Error?) {
        stopTicker()
        teardown()
        state = .idle

        // `AVCaptureFileOutput` reports an error *and* leaves a usable file behind in some
        // cases — it says so through `AVErrorRecordingSuccessfullyFinishedKey`. A take
        // that is on disk and playable is a take, and throwing it away because the device
        // vanished a moment after the last word would be losing something the user said.
        let salvageable = (error as NSError?)?
            .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
        if let error, !salvageable {
            Self.log.error("Voiceover failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            onFinish(.failure(error))
        } else {
            onFinish(.success(url))
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func teardown() {
        let session = session
        self.session = nil
        output = nil
        delegate = nil
        fileURL = nil
        isWarm = false
        opensWhenWarm = false
        // Off the main thread for the same reason as `startRunning`: stopping a capture
        // session waits for the device to let go.
        if let session { DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() } }
    }

    // MARK: - Devices

    /// The chosen input, or the system's default when nothing was chosen or the chosen
    /// one is no longer here. Falling back beats refusing to record: an unplugged
    /// interface is not a reason to be unable to narrate.
    private static func device(matching id: String?) -> AVCaptureDevice? {
        guard let id, !id.isEmpty else { return MicrophoneRecorder.defaultDevice }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                      mediaType: .audio,
                                                      position: .unspecified).devices
        return devices.first { $0.uniqueID == id } ?? MicrophoneRecorder.defaultDevice
    }
}

/// The delegate, kept off the recorder.
///
/// `AVCaptureFileOutputRecordingDelegate` is called on a queue of AVFoundation's choosing,
/// which cannot be the main actor, so the callbacks arrive somewhere the recorder's state
/// may not be touched. This object exists to take them there: it carries nothing but two
/// `@Sendable` closures, which hop to the main actor and let the recorder do the thinking.
private final class FileOutputBridge: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let didStart: @Sendable () -> Void
    private let didFinish: @Sendable (URL, Error?) -> Void

    init(didStart: @escaping @Sendable () -> Void,
         didFinish: @escaping @Sendable (URL, Error?) -> Void) {
        self.didStart = didStart
        self.didFinish = didFinish
        super.init()
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        didStart()
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        didFinish(outputFileURL, error)
    }
}
