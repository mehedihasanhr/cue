import AppKit
import AVFoundation
import Observation
import RecordKit

/// Everything around a take that is not the bar: the global shortcuts, the menu bar icon,
/// the speaker notes, the camera preview and the microphone meter.
///
/// One owner, told about every change it cares about — the session's state, the settings,
/// whether the bar is on screen — and working out from those what each of them should be
/// doing. Each piece then answers one question ("should I be showing?") rather than
/// watching the others.
@MainActor
final class RecorderCenter {
    let hotkeys: RecorderHotkeys
    let meter = MicrophoneMeter()

    private let studio: StudioService
    private let settings: StudioSettings
    private let bar: RecorderBarPanel
    private let notes: SpeakerNotesPanel
    private let cameraPreview = CameraPreviewPanel()
    private var isBarVisible = false

    /// What the Record menu reaches back into the app for.
    var showLibrary: () -> Void = {}
    var openSettings: () -> Void = {}
    /// Puts the bar back to the app's own rule — on screen exactly when no editor is.
    var restoreBar: () -> Void = {}
    /// The bar was brought up for a take started from elsewhere, over an editor perhaps,
    /// and goes back to the rule once the take is over.
    private var barShownForTake = false
    /// The bar was minimized while a take was under way — before it, from the island, or
    /// during it — and comes back when the take is over. A bar minimized with nothing
    /// recording stays minimized: that is where it was asked to be.
    private var minimizedForTake = false

    /// The one center, for the views that need the meter or the shortcuts' state.
    private(set) static weak var shared: RecorderCenter?

    init(studio: StudioService, settings: StudioSettings, bar: RecorderBarPanel,
         registrar: any HotkeyRegistrar = CarbonHotkeyRegistrar()) {
        self.studio = studio
        self.settings = settings
        self.bar = bar
        hotkeys = RecorderHotkeys(registrar: registrar)
        notes = SpeakerNotesPanel(preferences: settings.recorder)
        Self.shared = self

        hotkeys.perform = { [weak self] in self?.perform($0) }
        studio.cameraPlacement = { [weak self] target in
            CameraPreviewPanel.screenArea(of: target).flatMap { self?.cameraPreview.placement(in: $0) }
        }
        bar.onVisibilityChange = { [weak self] visible in
            self?.isBarVisible = visible
            self?.sync()
        }
        isBarVisible = bar.isVisible
        observe()
    }

    // MARK: - Actions

    /// A shortcut or a menu item asked for something.
    func perform(_ action: RecorderAction) {
        switch action {
        case .record:
            let wasBusy = studio.session.state.isBusy
            bar.hideTargets()
            studio.toggleRecording(target: bar.model.target)
            // A take started from another app, perhaps with an editor in front: the bar is
            // how it is seen and stopped, so it comes up with it.
            if !wasBusy { showBarForTake() }
        case .pause:
            guard studio.session.state.isTaking else { return }
            studio.togglePause()
        case .restart:
            studio.requestRestart()
            // The question is asked on the bar, so the bar has to be there to ask it.
            if studio.restartPending { showBarForTake() }
        case .marker:
            studio.addMarker()
        }
    }

    /// Records the display the pointer is on, whatever the bar has chosen — what "Record
    /// Screen" says in both menus.
    func recordScreen() {
        guard !studio.session.state.isBusy else { return }
        bar.hideTargets()
        studio.toggleRecording(target: nil)
        showBarForTake()
    }

    private func showBarForTake() {
        if !bar.isVisible { barShownForTake = true }
        bar.show()
    }

    /// A tooltip with the action's shortcut after it, for views outside the bar.
    func help(_ text: String, _ action: RecorderAction) -> String {
        settings.recorder.help(text, action)
    }

    func toggleNotes() {
        settings.recorder.showsSpeakerNotes.toggle()
    }

    // MARK: - Keeping in step

    /// Everything the pieces depend on, read in one place so that reading it is what is
    /// watched — and the pieces' own state, which they change as they follow it, is not.
    private struct Inputs {
        var state: RecordingSession.State
        var shortcuts: RecorderShortcuts
        var usesShortcuts: Bool
        var isBarMinimized: Bool
        var showsNotes: Bool
        var showsCameraPreview: Bool
        var keepsCameraPreview: Bool
        var microphoneID: String?
        var cameraID: String?
    }

    private var inputs: Inputs?

    /// Reads the inputs, acts on them, and asks to be told when any of them changes.
    private func observe() {
        inputs = withObservationTracking { [weak self] in
            self?.readInputs()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        sync()
    }

    private func readInputs() -> Inputs {
        let preferences = settings.recorder
        // Neither grant is observable, but the bar re-reads both when it asks for one and
        // when its lists refresh; reading those here is what notices a grant arriving.
        _ = bar.model.cameraDenied
        _ = bar.model.cameras.count
        _ = bar.model.microphones.count
        return Inputs(state: studio.session.state,
                      shortcuts: preferences.shortcuts,
                      usesShortcuts: preferences.usesGlobalShortcuts,
                      isBarMinimized: bar.model.isMinimized,
                      showsNotes: preferences.showsSpeakerNotes,
                      showsCameraPreview: preferences.showsCameraPreview,
                      keepsCameraPreview: preferences.keepsCameraPreviewWhileRecording,
                      microphoneID: microphoneID,
                      cameraID: cameraID)
    }

    private func sync() {
        guard let inputs else { return }
        let state = inputs.state

        // Over: back to the rule. Not on a failure, which the bar is there to explain.
        let isOver: Bool = switch state {
        case .idle, .finished: true
        case .preparing, .countdown, .recording, .paused, .finishing, .failed: false
        }
        // The live flag, not the snapshot in `inputs`: putting the bar back hides or shows
        // it, which calls straight back into here before the snapshot is read again — and
        // a stale "still minimized" there went round that loop until the stack ran out.
        if state.isBusy, bar.model.isMinimized { minimizedForTake = true }
        if isOver, barShownForTake || minimizedForTake {
            barShownForTake = false
            minimizedForTake = false
            bar.leaveMinimized()
            restoreBar()
        }

        hotkeys.update(shortcuts: inputs.shortcuts, isEnabled: inputs.usesShortcuts, state: state)

        notes.setVisible(inputs.showsNotes)

        meter.update(to: RecorderCompanions.meterSource(deviceID: inputs.microphoneID,
                                                        isBarVisible: isBarVisible,
                                                        state: state),
                     session: studio.session)

        let preview = RecorderCompanions.showsCameraPreview(isEnabled: inputs.showsCameraPreview,
                                                            keepsWhileRecording: inputs.keepsCameraPreview,
                                                            hasCamera: inputs.cameraID != nil,
                                                            isBarVisible: isBarVisible,
                                                            state: state)
        cameraPreview.show(deviceID: preview ? inputs.cameraID : nil, near: bar.window)
    }

    /// The microphone the meter may listen to: the first one chosen, or the system's
    /// default when the microphone is on and none was picked — and only once allowed.
    private var microphoneID: String? {
        guard settings.recordsMicrophone, MicrophoneRecorder.isAuthorized else { return nil }
        return settings.microphoneIDs.first ?? MicrophoneRecorder.defaultDevice?.uniqueID
    }

    /// The camera the preview may show, by the same rule the take uses to pick one.
    private var cameraID: String? {
        guard settings.recordsCamera, WebcamRecorder.isAuthorized else { return nil }
        return settings.cameraID.isEmpty ? WebcamRecorder.defaultDevice?.uniqueID : settings.cameraID
    }

    /// Lets go of every shortcut, for quitting.
    func shutDown() {
        hotkeys.removeAll()
        meter.update(to: .none, session: studio.session)
        cameraPreview.hide()
    }
}
