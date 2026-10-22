import Observation

/// UI-facing state shared between the AppDelegate and SwiftUI windows.
@Observable
final class AppModel {
    var launchAtLogin = LaunchAtLogin.state
    var hasScreenCaptureAccess = PermissionManager.hasScreenCaptureAccess
    var hasAccessibilityAccess = PermissionManager.hasAccessibilityAccess

    func refreshPermissionState() {
        hasScreenCaptureAccess = PermissionManager.hasScreenCaptureAccess
        hasAccessibilityAccess = PermissionManager.hasAccessibilityAccess
        launchAtLogin = LaunchAtLogin.state
    }
}
