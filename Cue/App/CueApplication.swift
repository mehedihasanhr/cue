import AppKit
import os

/// Cue's `NSApplication`, named as the principal class in Info.plist.
///
/// It exists for one reason: an exception raised deep in AppKit's drawing — the
/// window layout ones a SwiftUI hosting view can provoke — used to end the app
/// outright, with a crash report that carried a trap address and no reason. With
/// `NSApplicationCrashOnExceptions` off, AppKit hands those here instead, where the
/// name, the reason and the stack are written to the log and Cue carries on. A HUD
/// drawn a pixel wrong is worth far more than an app that closes while a capture is
/// being taken.
@objc(CueApplication)
final class CueApplication: NSApplication {
    /// Makes this class the shared application, and tells AppKit not to end the app
    /// over an exception it raises itself. Both have to happen before SwiftUI reaches
    /// for `NSApplication.shared`, so `CueApp.init` calls this first.
    ///
    /// `NSApplicationCrashOnExceptions` is a user default, not an Info.plist key —
    /// registering it here is what actually turns the behaviour off.
    static func install() {
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": false])
        _ = CueApplication.shared
    }

    override func reportException(_ exception: NSException) {
        let stack = exception.callStackSymbols.prefix(24).joined(separator: "\n")
        Log.app.fault("""
        Caught \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "no reason", privacy: .public)
        \(stack, privacy: .public)
        """)
        super.reportException(exception)
    }
}
