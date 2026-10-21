import os
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

enum PermissionKind {
    case screenRecording
    case accessibility
}

/// TCC permission handling for Screen Recording and Accessibility.
///
/// There is no usage-description key for either on macOS; the system prompt appears
/// on the first request call. A Screen Recording grant only takes effect after the
/// app is relaunched; Accessibility applies immediately.
enum PermissionManager {
    // MARK: Screen Recording

    static var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt (once per install) and adds Klik to the
    /// Screen Recording list in System Settings. Returns the current state,
    /// which stays `false` until the app is relaunched after granting.
    @discardableResult
    static func requestScreenCaptureAccess() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        Log.permission.info("Screen capture access requested; granted=\(granted)")
        return granted
    }

    // MARK: Accessibility

    static var hasAccessibilityAccess: Bool {
        AXIsProcessTrusted()
    }

    /// Asks for Accessibility access. Note that under App Sandbox macOS neither shows a
    /// prompt nor adds the app to the list — the user has to add it with the "+" button
    /// (or drag the app in), so callers pair this with `revealAppInFinder()`.
    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        // kAXTrustedCheckOptionPrompt is a C global the compiler can't prove immutable; the literal is "AXTrustedCheckOptionPrompt".
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Log.permission.info("Accessibility access requested; trusted=\(trusted)")
        return trusted
    }

    /// Selects Klik.app in Finder so it can be dragged into a System Settings list.
    static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func has(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .screenRecording: hasScreenCaptureAccess
        case .accessibility: hasAccessibilityAccess
        }
    }

    // MARK: System Settings deep links

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    /// Asks for the microphone or camera the first time; once the user has answered,
    /// only System Settings can change it, so that is opened instead.
    static func requestCaptureDevice(_ type: AVMediaType, orOpen settings: @escaping () -> Void) {
        guard AVCaptureDevice.authorizationStatus(for: type) == .notDetermined else {
            settings()
            return
        }
        Task { _ = await AVCaptureDevice.requestAccess(for: type) }
    }

    static func openKeyboardShortcutSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")
    }

    static func openLoginItemsSettings() {
        open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    /// Launches a fresh instance of this bundle, then terminates the current one.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                Log.permission.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
