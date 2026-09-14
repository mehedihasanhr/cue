import AppKit
import SwiftUI

/// A small glass toast ("Text copied", "No text detected") near the bottom of the
/// screen that fades out by itself. Non-activating, so the user's app keeps focus.
@MainActor
enum FeedbackHUD {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(_ message: String, symbol: String, duration: Duration = .seconds(1.6)) {
        dismissTask?.cancel()
        panel?.close()

        let host = NSHostingView(rootView: FeedbackToast(message: message, symbol: symbol))
        let size = host.fittingSize
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.contentView = host

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 80))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        dismissTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    panel.close()
                    if Self.panel === panel { Self.panel = nil }
                }
            })
        }
    }
}

private struct FeedbackToast: View {
    let message: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .klikGlass(cornerRadius: 14)
        .padding(20) // room for the shadow
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}
