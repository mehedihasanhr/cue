import AppKit
import SwiftUI

/// Settings › Storage › Google Drive: connecting an account, and what goes up.
struct DriveSettingsGroup: View {
    @State private var confirmsDisconnect = false

    private var drive: DriveStorage { DriveStorage.shared }

    var body: some View {
        SettingsGroup("Google Drive") {
            if drive.isConnected {
                connected
            } else {
                disconnected
            }
        }
        .confirmationDialog("Disconnect Google Drive?", isPresented: $confirmsDisconnect) {
            Button("Disconnect", role: .destructive) { drive.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New recordings stop going up. Recordings already in your Drive stay there, and nothing on this Mac is removed.")
        }
    }

    @ViewBuilder private var disconnected: some View {
        SettingsRow("Back up to Google Drive", subtitle: disconnectedLine, symbol: "externaldrive.fill.badge.icloud", tint: .blue) {
            HStack(spacing: 8) {
                if drive.isConnecting { ProgressView().controlSize(.small) }
                Button("Connect\u{2026}") { drive.connect() }
                    .disabled(!drive.isConfigured || drive.isConnecting)
            }
        }
    }

    private var disconnectedLine: String {
        if !drive.isConfigured { return "Google sign-in isn\u{2019}t set up in this build (no client ID)." }
        if let error = drive.connectError { return error }
        if drive.isConnecting { return "Finish signing in in your browser." }
        return "Sign in with Google to keep a copy of your recordings in your Drive. Klik Studio only sees the files it adds."
    }

    @ViewBuilder private var connected: some View {
        SettingsRow("Connected", subtitle: drive.email, symbol: "person.crop.circle.badge.checkmark", tint: .green) {
            HStack(spacing: 8) {
                if let link = drive.rootFolderLink {
                    Button("Open in Drive") { NSWorkspace.shared.open(link) }
                }
                Button("Disconnect\u{2026}") { confirmsDisconnect = true }
            }
        }
        SettingsToggleRow("Upload new recordings automatically",
                          subtitle: "Each recording goes up once it\u{2019}s saved. The copy on this Mac stays.",
                          symbol: "icloud.and.arrow.up.fill", tint: .blue,
                          isOn: Binding(get: { drive.uploadsAutomatically }, set: { drive.uploadsAutomatically = $0 }))
        SettingsRow("Uploads", subtitle: uploadLine, symbol: uploadSymbol, tint: drive.lastFailure == nil ? .teal : .orange) {
            if let active = drive.activeUpload {
                ProgressView(value: active.progress)
                    .frame(width: 120)
                    .accessibilityLabel("Upload progress")
            } else if drive.lastFailure != nil {
                Button("Show Recordings") { StudioAppDelegate.shared?.showLibrary() }
            }
        }
    }

    private var uploadLine: String {
        if let active = drive.activeUpload {
            let waiting = drive.queue.count - 1
            let more = waiting > 0 ? ", \(waiting) more waiting" : ""
            return "Uploading \u{201C}\(active.name)\u{201D} \u{2014} \(Int(active.progress * 100))%\(more)"
        }
        if let failure = drive.lastFailure {
            return "\u{201C}\(failure.name)\u{201D} didn\u{2019}t upload: \(failure.message) Retry it from its menu in Recordings."
        }
        if !drive.queue.isEmpty { return "\(drive.queue.count) waiting" }
        return "Everything is up to date. Upload any recording from its menu in Recordings."
    }

    private var uploadSymbol: String {
        if drive.activeUpload != nil { return "arrow.up.circle.fill" }
        return drive.lastFailure == nil ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill"
    }
}
