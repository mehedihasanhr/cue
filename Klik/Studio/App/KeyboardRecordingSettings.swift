import AppKit
import ApplicationServices
import SwiftUI

/// The Accessibility grant, which is the one permission recording the keyboard needs.
///
/// Asked about here rather than in RecordKit, because RecordKit only ever *checks* it —
/// a recording is the wrong moment for a system dialog. Settings is the right one.
enum AccessibilityAccess {
    /// Whether macOS trusts this process, asked without prompting.
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to put up its prompt, and says whether the grant was already there.
    ///
    /// Under App Sandbox macOS may show nothing and add nothing to its list — the person
    /// has to add the app with the "+" button — which is why the settings row also opens
    /// the pane and says so.
    @discardableResult
    static func request() -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a C global the compiler cannot prove immutable;
        // its value is the literal below.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// System Settings, open at the Accessibility list.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The switch for recording shortcuts, and beside it the truth about whether it can.
///
/// Rows of their own rather than a toggle among the others, because this one comes with a
/// condition the others do not: it needs a grant the app cannot give itself, and a switch
/// that is on while the grant is missing records nothing. So the state is shown, not
/// implied, and there is a way to fix it from here.
struct KeyboardRecordingRows: View {
    @Environment(StudioSettings.self) private var settings

    /// Read once and again each time the app comes forward, which is when somebody has
    /// just come back from System Settings. Polling it from `body` would ask a
    /// cross-process question on every redraw.
    @State private var isGranted = AccessibilityAccess.isGranted

    var body: some View {
        Group {
            SettingsToggleRow("Record keyboard shortcuts",
                              subtitle: "Only shortcuts — a key with ⌘, ⌃ or ⌥ held, or Return, Tab, Escape, Delete and the arrows on their own. Typed text is never recorded.",
                              symbol: "keyboard.fill", tint: .purple,
                              isOn: recordsKeys)
            if settings.recordsKeys {
                if isGranted {
                    SettingsStatusRow("Klik has Accessibility access",
                                      subtitle: "Which is what lets it see the keys.",
                                      isGood: true) {
                        RevealButton(help: "Open in System Settings") { AccessibilityAccess.openSystemSettings() }
                    }
                } else {
                    SettingsStatusRow("Klik doesn't have Accessibility access yet",
                                      subtitle: "Until it does, recordings are made without shortcuts. Turn Klik on under Privacy & Security › Accessibility — if it isn't in the list, add it with the + button.",
                                      isGood: false) {
                        Button("Open System Settings") { AccessibilityAccess.openSystemSettings() }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isGranted = AccessibilityAccess.isGranted
        }
    }

    private var recordsKeys: Binding<Bool> {
        Binding {
            settings.recordsKeys
        } set: { isOn in
            settings.recordsKeys = isOn
            // Turning it on is the moment to ask: the person has just said they want
            // this, which is the one time a permission dialog is not an interruption.
            if isOn, !isGranted {
                isGranted = AccessibilityAccess.request()
            }
        }
    }
}
