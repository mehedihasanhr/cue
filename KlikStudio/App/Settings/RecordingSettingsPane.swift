import AppKit
import AVFoundation
import RecordKit
import SwiftUI

/// What a take records, and what is on screen while it does.
///
/// Anything that changes what a recording *contains* is here; what one *is* — the source,
/// the button — stays on the recorder bar.
struct RecordingSettingsPane: View {
    @Environment(StudioSettings.self) private var settings
    /// The bar's model, when the bar exists: turning the camera on goes through it, so the
    /// permission is asked for at the moment it is wanted, exactly as on the bar.
    @Environment(RecorderModel.self) private var recorderModel: RecorderModel?
    @State private var microphones: [AVCaptureDevice] = []
    @State private var cameras: [AVCaptureDevice] = []
    @State private var cameraDenied = WebcamRecorder.isDenied

    var body: some View {
        @Bindable var settings = settings
        @Bindable var recorder = settings.recorder

        SettingsPane(.recording) {
            SettingsGroup("Capture",
                          footer: "Automatic uses HEVC where this Mac has a hardware encoder — about half the file size for the same picture.") {
                SettingsRow("Countdown", subtitle: "Time to get out of the way before the take starts.") {
                    Picker("Countdown", selection: $settings.countdownSeconds) {
                        Text("Off").tag(0)
                        ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                    .fixedSize()
                }
                SettingsRow("Frame rate") {
                    Picker("Frame rate", selection: $settings.frameRate) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingsRow("Quality") {
                    Picker("Quality", selection: $settings.quality) {
                        Text("Good").tag(CaptureQuality.good)
                        Text("Better").tag(CaptureQuality.better)
                        Text("Best").tag(CaptureQuality.best)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingsRow("Encoder") {
                    Picker("Encoder", selection: $settings.codec) {
                        Text("Automatic").tag(VideoCodec.automatic)
                        Text("HEVC").tag(VideoCodec.hevc)
                        Text("H.264").tag(VideoCodec.h264)
                    }
                    .fixedSize()
                }
            }

            SettingsGroup("Pointer and input", footer: pointerFooter) {
                SettingsToggleRow("Record clicks and scrolls",
                                  subtitle: "What auto-zoom, click marks and click sounds are made from.",
                                  symbol: "cursorarrow.click.2", tint: .blue,
                                  isOn: $settings.recordsClicks)
                SettingsToggleRow("Record what has focus",
                                  subtitle: "Which window, app and field was in use, so zooms can follow your attention and not only your clicks.",
                                  symbol: "scope", tint: .teal,
                                  isOn: $settings.recordsFocus)
                SettingsToggleRow("Burn the pointer into the video",
                                  symbol: "cursorarrow.rays", tint: .gray,
                                  isOn: $settings.burnsCursorIntoVideo)
                KeyboardRecordingRows()
            }

            SettingsGroup("Sound", footer: microphoneFooter) {
                SettingsToggleRow("Record system audio",
                                  subtitle: "Everything the Mac plays — the app being demonstrated, a video, an alert. The bar\u{2019}s system audio menu can narrow it to the apps you choose.",
                                  symbol: "speaker.wave.2.fill", tint: .pink,
                                  isOn: $settings.recordsSystemAudio)
                // Only once apps have been chosen, where the choice is made from the bar: it
                // is said here too so a take that is missing the chat app's ping is not a
                // mystery, and so there is a way back to everything from Settings.
                if !settings.systemAudioAppIDs.isEmpty {
                    SettingsRow("Only these apps",
                                subtitle: settings.systemAudioAppIDs.map(SystemAudioApps.name(of:)).formatted(.list(type: .and))
                                    + ". An app that isn\u{2019}t running when a take starts isn\u{2019}t heard in it.") {
                        Button("Hear Every App") { settings.systemAudioAppIDs = [] }
                    }
                    .padding(.leading, 42)
                    .disabled(!settings.recordsSystemAudio)
                }
                SettingsToggleRow("Record microphone", symbol: "mic.fill", tint: .red, isOn: $settings.recordsMicrophone)
                // One row per microphone, ticked or not, rather than one picker: a take
                // records every microphone that is ticked, each to its own file, and each
                // arrives in the editor as a lane with its own level. Nothing ticked is the
                // system's default input, which is what somebody who turned the microphone
                // on and never came here expects.
                ForEach(microphones, id: \.uniqueID) { device in
                    SettingsToggleRow(device.localizedName, isOn: Binding(
                        get: { settings.microphoneIDs.contains(device.uniqueID) },
                        set: { settings.setMicrophone(device.uniqueID, isOn: $0) }
                    ))
                    .padding(.leading, 42)
                    .disabled(!settings.recordsMicrophone)
                }
            }

            SettingsGroup("Camera",
                          footer: "Off until you turn it on, here or on the bar. The preview is a small round picture beside the bar, mirrored like the bubble, and is never in the recording.") {
                SettingsToggleRow("Record the camera",
                                  subtitle: "A bubble of you over the recording, which you can move, resize or hide in the editor.",
                                  symbol: "video.fill", tint: .green,
                                  isOn: cameraBinding)
                if settings.recordsCamera, cameraDenied {
                    SettingsStatusRow("Klik Studio isn't allowed to use the camera",
                                      subtitle: "Turn it on under Privacy & Security › Camera.",
                                      isGood: false) {
                        Button("Open System Settings") { Self.openCameraPrivacy() }
                    }
                }
                SettingsRow("Camera") {
                    Picker("Camera", selection: $settings.cameraID) {
                        Text("System default").tag("")
                        ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        // A camera chosen before and unplugged since is still the choice; it
                        // is named as missing rather than shown as an empty box.
                        if !settings.cameraID.isEmpty, !cameras.contains(where: { $0.uniqueID == settings.cameraID }) {
                            Text("Not connected").tag(settings.cameraID)
                        }
                    }
                    .fixedSize()
                }
                .disabled(!settings.recordsCamera)
                SettingsToggleRow("Preview the camera before recording", isOn: $recorder.showsCameraPreview)
                SettingsToggleRow("Keep the preview while recording", isOn: $recorder.keepsCameraPreviewWhileRecording)
                    .disabled(!recorder.showsCameraPreview)
            }

            SettingsGroup("While recording",
                          footer: "Desktop icons are left out of display and area recordings; the Finder's own settings aren't changed. Speaker notes float over your screen and are never recorded.") {
                SettingsToggleRow("Hide desktop icons", symbol: "menubar.dock.rectangle", tint: .indigo,
                                  isOn: $recorder.hidesDesktopIcons)
                SettingsToggleRow("Show speaker notes", symbol: "note.text", tint: .yellow,
                                  isOn: $recorder.showsSpeakerNotes)
                SettingsRow("Speaker notes text size") {
                    SettingsSlider("Speaker notes text size", value: $recorder.notesFontSize,
                                   in: RecorderPreferences.notesFontSizes, step: 1) { "\(Int($0)) pt" }
                }
                SettingsRow("Ask before restarting a take",
                            subtitle: "Restart throws the take away. Shorter takes than this are started again at once.") {
                    Picker("Ask before restarting a take", selection: restartBinding) {
                        ForEach(StudioAppPreferences.restartThresholds, id: \.self) { seconds in
                            Text(Self.restartTitle(seconds)).tag(seconds)
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .task {
            microphones = MicrophoneRecorder.devices
            cameras = WebcamRecorder.devices
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings, perhaps with the camera allowed; and a device
            // plugged in meanwhile belongs in the lists.
            cameraDenied = WebcamRecorder.isDenied
            microphones = MicrophoneRecorder.devices
            cameras = WebcamRecorder.devices
        }
    }

    private var pointerFooter: String {
        settings.burnsCursorIntoVideo
            ? "With the pointer burned in, the editor can't resize it, smooth it, or zoom to follow it — there's nothing but pixels to work with."
            : "The pointer is recorded as data beside the video, which is what lets the editor smooth it, resize it and zoom to follow it."
    }

    private var microphoneFooter: String? {
        guard settings.recordsMicrophone else { return nil }
        return settings.microphoneIDs.count > 1
            ? "Each microphone is recorded to its own track, so you can set their levels separately when you edit."
            : "Tick more than one to record each to its own track. None ticked records the system's default input."
    }

    private var cameraBinding: Binding<Bool> {
        Binding {
            settings.recordsCamera
        } set: { isOn in
            if let recorderModel {
                recorderModel.setCamera(isOn)
            } else {
                settings.recordsCamera = isOn
            }
            cameraDenied = isOn && WebcamRecorder.isDenied
        }
    }

    /// The stored threshold, snapped to one of the choices so the picker never shows an
    /// empty box for a value written by hand.
    private var restartBinding: Binding<Int?> {
        Binding {
            let stored = settings.app.restartConfirmationSeconds
            return StudioAppPreferences.restartThresholds.contains(stored) ? stored : Int(TakeRestart.confirmationThreshold)
        } set: {
            settings.app.restartConfirmationSeconds = $0
        }
    }

    private static func restartTitle(_ seconds: Int?) -> String {
        switch seconds {
        case nil: "Never"
        case 0: "Always"
        case let seconds? where seconds >= 60: "Over \(seconds / 60) min"
        case let seconds?: "Over \(seconds) s"
        }
    }

    private static func openCameraPrivacy() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }
}
