import SwiftUI
import TimelineKit

/// Saving, suggested zooms, and what a new recording looks like before anyone touches it.
///
/// Everything under "New recordings" is a starting point: each of it can be changed per
/// project in the editor, and none of it reaches back into a project already edited.
struct EditorSettingsPane: View {
    @Environment(StudioSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        @Bindable var newProjects = settings.newProjects

        SettingsPane(.editor) {
            SettingsGroup(footer: settings.savesAutomatically
                          ? "Edits are written into the recording a couple of seconds after you make them, and when the window closes. The Save button in the editor says when they are."
                          : "You are asked whether to save when you close a recording you have edited. ⌘S saves at any time.") {
                SettingsToggleRow("Save edits automatically", symbol: "externaldrive.fill.badge.checkmark", tint: .green,
                                  isOn: $settings.savesAutomatically)
            }

            SettingsGroup("Suggested zooms", footer: focusFooter) {
                SettingsToggleRow("Suggest zooms when a recording opens",
                                  subtitle: "From the recorded clicks, on a recording nobody has edited yet. The toolbar's Auto Zoom runs it again any time.",
                                  symbol: "plus.magnifyingglass", tint: .blue,
                                  isOn: $settings.suggestsZoomsOnOpen)
                // Not disabled with the switch above: the toolbar's Auto Zoom proposes
                // zooms with these too, whether or not a recording opens with them.
                SettingsRow("How far a click zooms") {
                    SettingsSlider("How far a click zooms", value: $settings.zoomScale, in: 1.2...3,
                                   format: SettingsSlider.multiple)
                }
                SettingsRow("Hold after the last click", subtitle: "How long a zoom stays in once the clicking stops.") {
                    SettingsSlider("Hold after the last click", value: $settings.zoomHoldSeconds,
                                   in: StudioSettings.zoomHoldRange, step: 0.1, format: SettingsSlider.seconds)
                }
                SettingsToggleRow("Zoom to text fields as they take the caret", isOn: $settings.zoomsOnFocus)
                SettingsToggleRow("Zoom when a window comes forward", isOn: $settings.zoomsOnWindowChange)
                    .disabled(!settings.zoomsOnFocus)
            }

            SettingsGroup("New recordings", footer: lookFooter) {
                if let look = settings.newRecordingLook {
                    SettingsRow("Look", subtitle: "Chosen with Use for New Recordings in the editor's Frame panel.",
                                symbol: "paintpalette.fill", tint: .purple) {
                        HStack(spacing: 8) {
                            Text(look.name).font(SettingsFont.sub).foregroundStyle(.secondary)
                            Button("Clear") { settings.clearNewRecordingLook() }
                                .help("New recordings start from these settings alone")
                        }
                    }
                }
                SettingsRow("Background") {
                    Picker("Background", selection: background) {
                        // A look can carry a background the five presets cannot name. While
                        // one does, the picker says so rather than showing a preset that is
                        // not what a new recording will get.
                        if settings.newRecordingLookSetsBackground, let look = settings.newRecordingLook {
                            Text("From “\(look.name)”").tag(BackgroundChoice.look)
                        }
                        ForEach(BackgroundPreset.allCases) { Text($0.title).tag(BackgroundChoice.preset($0)) }
                    }
                    .fixedSize()
                }
                percentRow("Padding", value: $settings.padding, range: 0...0.2)
                percentRow("Corners", value: $settings.cornerRadius, range: 0...0.08)
                percentRow("Shadow", value: $settings.shadowOpacity, range: 0...1)
                percentRow("Softness", value: $settings.shadowRadius, range: 0...0.08)
                percentRow("Background blur", value: $settings.backgroundBlur, range: 0...0.04)
            }

            SettingsGroup("Pointer in new recordings",
                          footer: "Applied when a recording is first opened. Change any of it per project in the editor's Pointer panel.") {
                SettingsRow("Size") {
                    SettingsSlider("Pointer size", value: $settings.cursorScale, in: 0.5...3, format: SettingsSlider.multiple)
                }
                SettingsRow("Smoothing") {
                    SettingsSlider("Pointer smoothing", value: $settings.cursorSmoothing, in: 0...1, format: SettingsSlider.percent)
                }
                SettingsToggleRow("Pointer swells on click", isOn: $settings.clickEffect)
                SettingsToggleRow("Mark where clicks happen",
                                  subtitle: "A mark on the spot each click lands — the only sign of a click in a silent video.",
                                  isOn: $newProjects.clickRing)
                SettingsRow("Click mark") {
                    Picker("Click mark", selection: $newProjects.clickStyle) {
                        ForEach(CursorStyle.ClickStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                .disabled(!newProjects.clickRing)
                SettingsToggleRow("Motion blur", subtitle: "A little blur on fast pointer moves, the way a camera would see them.",
                                  isOn: $newProjects.motionBlur)
                SettingsToggleRow("Hide the pointer when it stops",
                                  subtitle: "It fades after a moment still, and comes back as it moves.",
                                  isOn: $newProjects.hidesIdlePointer)
                SettingsToggleRow("Always show the arrow",
                                  subtitle: "Instead of the I-beam, hand or resize shape the pointer turned into.",
                                  isOn: $newProjects.alwaysArrow)
            }
        }
    }

    private func percentRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        SettingsRow(title) {
            // Shown as a share of the slider's travel, which is what the eye reads off it;
            // the stored number is a fraction of the frame and means nothing on its own.
            SettingsSlider(title, value: value, in: range) { value in
                SettingsSlider.percent((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            }
        }
    }

    private var lookFooter: String {
        if let look = settings.newRecordingLook {
            return "New recordings start from the look “\(look.name)”, with these settings for everything this window shows."
        }
        return "What a new recording's frame starts as. Every one of these can be changed per project in the editor."
    }

    /// Says what the focus toggles will actually get you, which depends on a grant the
    /// app cannot give itself. Better here than as a dialog at the moment of recording.
    private var focusFooter: String {
        guard settings.zoomsOnFocus else {
            return "Zooms are suggested from the recorded clicks alone."
        }
        // Text fields are only watched while the keyboard is — see `RecordingSession`,
        // which hands the focus tracker `capturesKeystrokes`. Saying "which Klik Studio
        // has" with the keyboard switch off promised a zoom that could never arrive.
        guard settings.recordsKeys else {
            return "Windows and apps are tracked with the permission recording already has. Text fields are only noticed while keyboard shortcuts are recorded — turn that on under Recording."
        }
        return AccessibilityAccess.isGranted
            ? "Windows and apps are tracked with the permission recording already has. Text fields need Accessibility, which Klik Studio has."
            : "Text fields need Accessibility — without it, zooms come from clicks and from windows coming forward. Turn Klik Studio on in System Settings › Privacy & Security › Accessibility."
    }

    /// What decides a new recording's background: a named preset, or the look.
    private enum BackgroundChoice: Hashable {
        case look
        case preset(BackgroundPreset)
    }

    private var background: Binding<BackgroundChoice> {
        Binding {
            settings.newRecordingLookSetsBackground ? .look : .preset(settings.backgroundPreset)
        } set: { choice in
            // Picking a preset is the most recent word on the matter, so it takes the
            // background back from the look. Picking "the look's" changes nothing: it
            // is only ever shown while that is already so.
            if case .preset(let preset) = choice { settings.chooseBackgroundPreset(preset) }
        }
    }
}
