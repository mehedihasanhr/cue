import SwiftUI

/// Shown when a permission is missing. Polls the permission so the UI flips to
/// "granted" without the user having to do anything else.
struct OnboardingView: View {
    let kind: PermissionKind
    /// Called when the permission is granted and no relaunch is needed.
    var onGranted: (() -> Void)?

    @State private var hasAccess: Bool

    init(kind: PermissionKind, onGranted: (() -> Void)? = nil) {
        self.kind = kind
        self.onGranted = onGranted
        _hasAccess = State(initialValue: PermissionManager.has(kind))
    }

    private var needsRelaunch: Bool { kind == .screenRecording }

    var body: some View {
        VStack(spacing: 20) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                Image(systemName: hasAccess ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white, hasAccess ? Color.green : Color.accentColor)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-3))
                    .offset(x: 6, y: 6)
                    .contentTransition(.symbolEffect(.replace))
            }

            VStack(spacing: 6) {
                Text(hasAccess ? "\(name) access granted" : "Klik needs \(name) access")
                    .font(.title2.weight(.semibold))
                Text(hasAccess ? grantedText : explanation)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !hasAccess {
                VStack(alignment: .leading, spacing: 10) {
                    switch kind {
                    case .screenRecording:
                        step(1, "Click **Request Access**. A system prompt appears.")
                        step(2, "Choose **Open System Settings** and turn on **Klik** under \(settingsPane).")
                        step(3, "Come back here and click **Relaunch Klik**.")
                    case .accessibility:
                        step(1, "Click **Add Klik to Accessibility**. System Settings and a Finder window with Klik open side by side.")
                        step(2, "Drag **Klik** from Finder into the Accessibility list (or click **+** and choose it), then turn it on.")
                        step(3, "Come back here — Klik picks it up automatically.")
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 12) {
                if hasAccess {
                    if needsRelaunch {
                        Button("Relaunch Klik") { PermissionManager.relaunch() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Continue") { onGranted?() }
                            .keyboardShortcut(.defaultAction)
                    }
                } else if kind == .accessibility {
                    Button("Add Klik to Accessibility") {
                        request()
                        openSettings()
                        PermissionManager.revealAppInFinder()
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("Reveal Klik in Finder") { PermissionManager.revealAppInFinder() }
                } else {
                    Button("Request Access", action: request)
                        .keyboardShortcut(.defaultAction)
                    Button("Open System Settings", action: openSettings)
                    Button("Relaunch Klik") { PermissionManager.relaunch() }
                }
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 460)
        .task {
            // Poll: the TCC database updates as soon as the user flips the switch.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let current = PermissionManager.has(kind)
                if current != hasAccess {
                    withAnimation { hasAccess = current }
                }
            }
        }
    }

    // MARK: - Copy

    private var name: String {
        switch kind {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }

    private var icon: String {
        switch kind {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        }
    }

    private var explanation: String {
        switch kind {
        case .screenRecording:
            "macOS requires this permission for any app that captures the screen. Klik never records or uploads anything on its own."
        case .accessibility:
            "Scrolling capture scrolls the window for you and needs permission to send scroll events to other apps. macOS doesn't show a prompt for this one — Klik has to be added to the list by hand."
        }
    }

    private var grantedText: String {
        switch kind {
        case .screenRecording: "macOS applies this permission on the next launch. Relaunch Klik to start capturing."
        case .accessibility: "You can start a scrolling capture now."
        }
    }

    private var settingsPane: String {
        switch kind {
        case .screenRecording: "Screen & System Audio Recording"
        case .accessibility: "Accessibility"
        }
    }

    private func request() {
        switch kind {
        case .screenRecording: PermissionManager.requestScreenCaptureAccess()
        case .accessibility: PermissionManager.requestAccessibilityAccess()
        }
    }

    private func openSettings() {
        switch kind {
        case .screenRecording: PermissionManager.openScreenRecordingSettings()
        case .accessibility: PermissionManager.openAccessibilitySettings()
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tint))
                .foregroundStyle(.white)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Screen Recording") {
    OnboardingView(kind: .screenRecording)
}

#Preview("Accessibility") {
    OnboardingView(kind: .accessibility)
}
