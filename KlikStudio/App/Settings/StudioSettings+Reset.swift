import Foundation

/// Reset All Settings, from Settings › Storage.
extension StudioSettings {
    /// The key families this app's settings are stored under. Anything else in the app's
    /// defaults — the library's bookmark, which takes offered at launch, the Settings
    /// pane last open (`settings.section`) — is state, not a setting, and a reset must not
    /// touch it.
    ///
    /// `preview.` is the preview's safe-zone guides (`SafeZonePreference`): a preference
    /// like any other, and once missed here, so a reset left the guides showing. A new
    /// family of keys belongs in this list the day it is added.
    private static let settingPrefixes = ["recording.", "editor.", "recorder.", "export.", "app.", "captions.",
                                          "audio.", "preview."]

    /// Keys inside those families that are the user's *content* or a window's layout
    /// rather than a preference: the speaker notes someone typed, how wide they dragged
    /// the editor's panel.
    private static let keptKeys: Set<String> = ["recorder.notes", "editor.settingsWidth"]

    /// Puts every setting back to what a fresh install has, and leaves the recordings
    /// folder, the speaker notes and every recording alone.
    ///
    /// The values in memory are copied from a `StudioSettings` built after the stored ones
    /// are gone — which is, by definition, what a fresh install reads — rather than from a
    /// second table of defaults here that would disagree with `init` within a release.
    func resetToDefaults() {
        let defaults = UserDefaults.standard
        Self.forgetStoredSettings(in: defaults)

        let fresh = StudioSettings()
        recordsKeys = fresh.recordsKeys
        countdownSeconds = fresh.countdownSeconds
        frameRate = fresh.frameRate
        quality = fresh.quality
        codec = fresh.codec
        recordsSystemAudio = fresh.recordsSystemAudio
        recordsMicrophone = fresh.recordsMicrophone
        recordsCamera = fresh.recordsCamera
        microphoneIDs = fresh.microphoneIDs
        systemAudioAppIDs = fresh.systemAudioAppIDs
        cameraID = fresh.cameraID
        recordsClicks = fresh.recordsClicks
        recordsFocus = fresh.recordsFocus
        burnsCursorIntoVideo = fresh.burnsCursorIntoVideo
        opensEditorAfterRecording = fresh.opensEditorAfterRecording
        suggestsZoomsOnOpen = fresh.suggestsZoomsOnOpen
        zoomsOnFocus = fresh.zoomsOnFocus
        zoomsOnWindowChange = fresh.zoomsOnWindowChange
        zoomScale = fresh.zoomScale
        zoomHoldSeconds = fresh.zoomHoldSeconds
        backgroundPreset = fresh.backgroundPreset
        padding = fresh.padding
        cornerRadius = fresh.cornerRadius
        shadowOpacity = fresh.shadowOpacity
        shadowRadius = fresh.shadowRadius
        backgroundBlur = fresh.backgroundBlur
        cursorScale = fresh.cursorScale
        cursorSmoothing = fresh.cursorSmoothing
        clickEffect = fresh.clickEffect
        newRecordingLook = fresh.newRecordingLook
        previewVolume = fresh.previewVolume
        previewIsMuted = fresh.previewIsMuted
        voiceoverCountInSeconds = fresh.voiceoverCountInSeconds
        captionLanguage = fresh.captionLanguage
        savesAutomatically = fresh.savesAutomatically

        let recorderDefaults = fresh.recorder
        recorder.usesGlobalShortcuts = recorderDefaults.usesGlobalShortcuts
        recorder.shortcuts = recorderDefaults.shortcuts
        recorder.showsMenuBarIcon = recorderDefaults.showsMenuBarIcon
        recorder.showsSpeakerNotes = recorderDefaults.showsSpeakerNotes
        recorder.notesFontSize = recorderDefaults.notesFontSize
        recorder.hidesDesktopIcons = recorderDefaults.hidesDesktopIcons
        recorder.showsCameraPreview = recorderDefaults.showsCameraPreview
        recorder.keepsCameraPreviewWhileRecording = recorderDefaults.keepsCameraPreviewWhileRecording
        editorShortcuts.shortcuts = fresh.editorShortcuts.shortcuts

        // Each assignment above wrote its value back. Taken away again, so the file is
        // left as a fresh install's — empty — and a later build's defaults still apply.
        Self.forgetStoredSettings(in: defaults)

        app.load()
        newProjects.load()
        SafeZonePreference.shared.load()
    }

    private static func forgetStoredSettings(in defaults: UserDefaults) {
        guard let domain = Bundle.main.bundleIdentifier,
              let stored = defaults.persistentDomain(forName: domain) else { return }
        for key in stored.keys
        where !keptKeys.contains(key) && settingPrefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
    }
}
