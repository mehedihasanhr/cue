import SwiftUI

/// The tour's last stop before the send-off: what Cue asks macOS for and why, each
/// with its state, checked again every second so a grant shows as it happens.
struct WelcomePermissions: View {
    let onBack: () -> Void
    let onNext: () -> Void

    @State private var screen = PermissionManager.hasScreenCaptureAccess
    @State private var accessibility = PermissionManager.hasAccessibilityAccess
    @State private var login = LaunchAtLogin.state

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(0..<3) { ring in
                    Circle()
                        .strokeBorder(.white.opacity(0.06 - Double(ring) * 0.015), lineWidth: 1)
                        .frame(width: 70 + CGFloat(ring) * 30, height: 70 + CGFloat(ring) * 30)
                }
                GlossyDisc(symbol: "lock.open.fill", tint: Color(red: 0.95, green: 0.62, blue: 0.3), size: 54)
            }
            .frame(height: 140)
            .padding(.top, 34)
            Text("Allow a few permissions.")
                .font(.system(size: 26, weight: .bold))
            Text("Each one turns on a feature. Grant them now, or later in Settings › Permissions.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 8)
            VStack(spacing: 8) {
                row("Screen Recording", "Captures, recordings and the text in them.", symbol: "rectangle.dashed",
                    tint: Color(red: 0.4, green: 0.55, blue: 1), granted: screen) {
                    if !PermissionManager.requestScreenCaptureAccess() { PermissionManager.openScreenRecordingSettings() }
                }
                row("Accessibility", "Notifications in the island, pasting and snippets.", symbol: "accessibility",
                    tint: Color(red: 0.6, green: 0.45, blue: 1), granted: accessibility) {
                    if !PermissionManager.requestAccessibilityAccess() { PermissionManager.openAccessibilitySettings() }
                }
                row("Open at login", "Cue starts with your Mac, so the island is always there.", symbol: "power",
                    tint: Color(red: 0.36, green: 0.82, blue: 0.48), granted: login == .enabled,
                    grantTitle: login == .requiresApproval ? "Approve…" : "Turn On") {
                    if login == .requiresApproval {
                        PermissionManager.openLoginItemsSettings()
                    } else {
                        try? LaunchAtLogin.setEnabled(true)
                        login = LaunchAtLogin.state
                    }
                }
            }
            .frame(width: 520)
            .padding(.top, 26)
            Spacer(minLength: 0)
            HStack {
                Button("Back", action: onBack)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                WelcomeButton("Continue", prominent: true, compact: true, action: onNext)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 26)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                screen = PermissionManager.hasScreenCaptureAccess
                accessibility = PermissionManager.hasAccessibilityAccess
                login = LaunchAtLogin.state
            }
        }
    }

    private func row(_ title: String, _ detail: String, symbol: String, tint: Color, granted: Bool,
                     grantTitle: String = "Allow…", grant: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            GlossyDisc(symbol: symbol, tint: tint, size: 34, lit: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 8)
            if granted {
                HStack(spacing: 5) {
                    Icon("checkmark.circle.fill", size: 15, weight: .semibold)
                    Text("On").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color(red: 0.36, green: 0.82, blue: 0.48))
                .transition(.scale.combined(with: .opacity))
            } else {
                WelcomeButton(grantTitle, compact: true, action: grant)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1))
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: granted)
    }
}
