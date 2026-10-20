import AppKit
import SwiftUI

/// What this build is, for a bug report.
struct AboutSettingsPane: View {
    @Environment(StudioService.self) private var service
    @State private var copied = false

    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    var body: some View {
        StudioSettingsPane(.about) {
            StudioSettingsGroup {
                StudioSettingsCell(vertical: 16) {
                    HStack(spacing: 16) {
                        StudioAppIconTile(size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Klik").font(.system(size: 14, weight: .semibold))
                            Text("Screen recording and the video editor, part of Klik.")
                                .font(StudioSettingsFont.sub)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        Text("Version \(service.version) (\(build))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .font(StudioSettingsFont.sub)
                    }
                }
                StudioSettingsRow("Version") {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("Klik \(service.version) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                                                       forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                }
                StudioSettingsRow("macOS") {
                    Text(ProcessInfo.processInfo.operatingSystemVersionString)
                        .font(StudioSettingsFont.sub)
                        .foregroundStyle(.secondary)
                }
            }

            StudioSettingsGroup {
                StudioSettingsRow("Klik", subtitle: Bundle.main.bundleURL.path(percentEncoded: false)) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                }
                StudioSettingsRow("© \(String(Calendar.current.component(.year, from: .now))) Stackrover")
            }
        }
    }
}
