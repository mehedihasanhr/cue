import os
import ServiceManagement

/// Login-item registration via `SMAppService` (macOS 13+, sandbox-safe).
enum LaunchAtLogin {
    enum State {
        case enabled
        case disabled
        /// The user must approve Klik in System Settings › General › Login Items.
        case requiresApproval
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        Log.app.info("Launch at login set to \(enabled)")
    }
}
