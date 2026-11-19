import SwiftUI

/// Settings › Organization: connect an organization (Sensory OS), what to bring in from
/// it, and how the connection is going.
struct OrganizationSettingsView: View {
    @Environment(SensoryOS.self) private var sensoryOS: SensoryOS?

    var body: some View {
        SettingsPane(.organization) {
            if let sensoryOS {
                SensoryOSSettingsGroup(sensoryOS: sensoryOS)
            }
        }
    }
}

/// The organization's connection: Connect, then what comes in and how it is going.
struct SensoryOSSettingsGroup: View {
    @Bindable var sensoryOS: SensoryOS
    @State private var showsServer = false

    var body: some View {
        SettingsGroup("Sensory OS", footer: footer) {
            SettingsRow(title, subtitle: subtitle, symbol: "building.2", tint: .indigo) {
                HStack(spacing: 8) {
                    switch sensoryOS.phase {
                    case .disconnected:
                        Button("Connect Organization") { Task { await sensoryOS.connect() } }
                            .keyboardShortcut(.defaultAction)
                    case .connecting:
                        ProgressView().controlSize(.small)
                        Button("Cancel") { sensoryOS.cancelSignIn() }
                    case .connected:
                        Button("Sync Now") { Task { await sensoryOS.run() } }
                            .disabled(sensoryOS.busy)
                        Button("Disconnect") { sensoryOS.disconnect() }
                    }
                }
            }

            if sensoryOS.phase == .connected {
                SettingsRow("Tasks", subtitle: "Which of the website's tasks show in Cue, under Organization in the task list. Only the tasks there are sent to the website.") {
                    Picker("", selection: $sensoryOS.scope) {
                        Text("Mine").tag("mine")
                        Text("Every board I can see").tag("all")
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                SettingsRow("Notifications", subtitle: "Sensory OS notifications on the island and in Notification Center, while Cue is running.") {
                    Toggle("", isOn: $sensoryOS.notificationsEnabled).labelsHidden().toggleStyle(.switch)
                }
            }

            if sensoryOS.phase != .connected || showsServer {
                SettingsRow("Server", subtitle: "The Sensory OS site to connect to. Change it only to try a staging or local server.") {
                    TextField("Server", text: $sensoryOS.serverText, prompt: Text(SOSServer.production.absoluteString))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .disabled(sensoryOS.phase != .disconnected)
                }
            }
        }
    }

    private var title: String {
        switch sensoryOS.phase {
        case .disconnected: "Not connected"
        case .connecting: "Waiting for you to sign in…"
        case .connected: sensoryOS.me.map { "Connected as \($0.user.email)" } ?? "Connected"
        }
    }

    private var subtitle: String {
        "Your Sensory OS tasks in Cue's task list, the tasks you add there sent to the website, and its notifications on the island."
    }

    private var footer: String? {
        if let error = sensoryOS.lastError { return error }
        guard sensoryOS.phase == .connected else {
            return "Cue opens Sensory OS's sign-in. Your password never reaches Cue; it keeps a sign-in token in your Keychain."
        }
        var parts: [String] = []
        let names = sensoryOS.agencies.map(\.name)
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        if sensoryOS.busy {
            parts.append("Syncing…")
        } else if let last = sensoryOS.lastSync {
            parts.append("Synced \(last.formatted(.relative(presentation: .named)))")
        }
        parts.append(sensoryOS.isLive ? "Live" : "Checks every minute")
        let unsent = sensoryOS.unsent
        if unsent > 0 { parts.append(unsent == 1 ? "1 change not sent yet" : "\(unsent) changes not sent yet") }
        return parts.joined(separator: " · ")
    }
}
