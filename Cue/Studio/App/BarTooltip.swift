import AppKit
import SwiftUI

/// The recorder bar's own tooltips.
///
/// The bar is a non-activating panel over somebody else's work, and macOS shows a
/// view's `help` tooltip only for the app in front — so the bar's buttons, every one
/// of which has had a `help` string all along, never showed one. This draws them
/// instead: a small label in its own panel, just above whatever the pointer is on.
@MainActor
final class BarTooltip {
    private var panel: NSPanel?
    private let text = TooltipText()
    private var showTask: Task<Void, Never>?

    /// How long the pointer must rest before the label appears, as the system's own
    /// tooltips wait.
    private static let delay = Duration.milliseconds(450)
    /// The gap between the label and the control it belongs to.
    private static let gap: CGFloat = 8

    /// Shows `title` over `rect` (screen coordinates), after the usual pause. A new
    /// control while one is already showing swaps the words straight away — once the
    /// first has waited, the rest of the row is read without waiting again.
    func show(_ title: String, over rect: CGRect) {
        guard !title.isEmpty else { return hide() }
        showTask?.cancel()
        guard panel?.isVisible != true else { return place(title, over: rect) }
        showTask = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.place(title, over: rect)
        }
    }

    func hide() {
        showTask?.cancel()
        showTask = nil
        panel?.orderOut(nil)
    }

    private func place(_ title: String, over rect: CGRect) {
        let panel = panel ?? makePanel()
        self.panel = panel
        text.title = title
        // Measured from the words themselves. A hosting view with no sizing options
        // reports no size of its own — deliberately, so it can never push one up to
        // the window — so the panel works its size out here instead.
        let size = Self.size(of: title)
        let visible = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame ?? rect
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.maxY + Self.gap)
        // Kept on the screen, and under the control when there is no room over it.
        if origin.y + size.height > visible.maxY { origin.y = rect.minY - size.height - Self.gap }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// The label's size: the words in the font below, plus the padding round them.
    private static func size(of title: String) -> CGSize {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        // 8 either side inside the capsule, 6 either side for the shadow (see the view).
        return CGSize(width: ceil(width) + (8 + 6) * 2, height: ceil(font.boundingRectForFont.height) + (5 + 6) * 2)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Above the bar, which itself sits above the target overlay.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        let host = NSHostingView(rootView: TooltipLabel(text: text))
        // The panel is given the size measured above; the hosting view never pushes one
        // of its own up (see CueApplication for what that costs).
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

/// The words, kept apart from the panel so changing them redraws the label alone.
@MainActor @Observable
private final class TooltipText {
    var title = ""
}

private struct TooltipLabel: View {
    @Bindable var text: TooltipText

    var body: some View {
        Text(text.title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.82))
                    .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.14)))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            }
            .padding(6) // room for the shadow, which a borderless window clips
    }
}
