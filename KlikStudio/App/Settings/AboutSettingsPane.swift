import AddOnKit
import AppKit
import SwiftUI

/// What this build is, and how it is getting on with Klik.
struct AboutSettingsPane: View {
    @Environment(StudioService.self) private var service
    @State private var copied = false
    @State private var showsConnection = false

    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    var body: some View {
        SettingsPane(.about) {
            SettingsGroup {
                SettingsCell(vertical: 16) {
                    HStack(spacing: 16) {
                        AppIconTile(size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Klik Studio").font(.system(size: 14, weight: .semibold))
                            Text("The recording add-on for Klik. It installs, updates and uninstalls on its own, and Klik works without it.")
                                .font(SettingsFont.sub)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        Text("Version \(service.version) (\(build))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .font(SettingsFont.sub)
                    }
                }
                SettingsRow("Version", subtitle: "Contract \(StudioCapabilities.currentContract) with Klik.") {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("Klik Studio \(service.version) (\(build)) · contract \(StudioCapabilities.currentContract) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                                                       forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                }
                SettingsRow("macOS") {
                    Text(ProcessInfo.processInfo.operatingSystemVersionString)
                        .font(SettingsFont.sub)
                        .foregroundStyle(.secondary)
                }
            }

            // Folded away because almost nobody needs it, and open in one click when Klik
            // says the add-on is there and nothing happens.
            SettingsGroup("Connection with Klik") {
                SettingsRow("Details", symbol: "link", tint: .blue) {
                    Button(showsConnection ? "Hide" : "Show") { showsConnection.toggle() }
                }
                if showsConnection {
                    SettingsCell {
                        BridgeStatusView()
                    }
                }
            }

            SettingsGroup {
                SettingsRow("Klik Studio", subtitle: Bundle.main.bundleURL.path(percentEncoded: false)) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                }
                SettingsRow("© \(String(Calendar.current.component(.year, from: .now))) Stackrover")
            }
        }
    }
}
