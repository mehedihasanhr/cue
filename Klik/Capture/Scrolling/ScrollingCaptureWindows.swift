import AppKit
import Observation
import SwiftUI

// MARK: - Dim overlay (click-through)

/// Dims everything except the capture region and frames it. Ignores mouse events, so
/// the user can keep scrolling the app underneath.
final class ScrollingDimWindow: NSWindow {
    init(screen: NSScreen, region: CGRect) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let local = region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        contentView = DimView(frame: CGRect(origin: .zero, size: screen.frame.size), hole: local)
    }

    private final class DimView: NSView {
        let hole: CGRect

        init(frame: CGRect, hole: CGRect) {
            self.hole = hole
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            context.fill(bounds)
            context.clear(hole)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(1)
            context.stroke(hole.insetBy(dx: -1.5, dy: -1.5))
            context.setStrokeColor(NSColor.white.cgColor)
            context.stroke(hole.insetBy(dx: -0.5, dy: -0.5))
        }
    }
}

// MARK: - Status + control bar

@Observable
final class ScrollingStatus {
    var frames = 0
    var autoScroll = true
    var reachedEnd = false

    var text: String {
        if !autoScroll {
            return frames <= 1 ? "Scroll down to capture · Done when finished" : "\(frames) frames captured · keep scrolling"
        }
        if reachedEnd {
            return "Reached the end · \(frames) frames"
        }
        return frames <= 1 ? "Scrolling…" : "Scrolling… \(frames) frames"
    }
}

struct ScrollingControlBar: View {
    let status: ScrollingStatus
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Label("Cancel", systemImage: "xmark")
                    .font(.system(size: 13, weight: .semibold))
            }
            .glassButton()
            .help("Cancel (esc)")

            Button(action: onDone) {
                Label("Done", systemImage: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 2)
            }
            .glassButton(prominent: true)
            .tint(.brand)
            .help("Finish (↩)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .klikGlass(cornerRadius: 16)
        .padding(20)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

/// Floating, non-activating panel hosting the control bar, pinned to the region's bottom edge.
final class ScrollingControlPanel {
    private let panel: NSPanel

    init(status: ScrollingStatus, onCancel: @escaping () -> Void, onDone: @escaping () -> Void) {
        panel = Self.makePanel()
        let host = NSHostingView(rootView: ScrollingControlBar(status: status, onCancel: onCancel, onDone: onDone))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    func show(below region: CGRect, on screen: NSScreen) {
        let size = panel.frame.size
        let visible = screen.visibleFrame
        // Centred just below the region (the pill itself sits ~8pt under the edge thanks to
        // the 20pt shadow padding); falls back to overlapping the edge near the screen bottom.
        var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - size.height + 12)
        if origin.y < visible.minY {
            origin.y = region.minY - size.height / 2
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func close() { panel.close() }

    static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}

// MARK: - Live preview

/// Floating panel showing the stitched result so far, beside the region.
final class ScrollingPreviewPanel {
    private let panel = ScrollingControlPanel.makePanel()
    private let imageView = NSImageView()
    private let region: CGRect
    private let screen: NSScreen
    private let width: CGFloat

    init(region: CGRect, screen: NSScreen) {
        self.region = region
        self.screen = screen
        width = min(max(region.width * 0.28, 150), 260)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor

        let container = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 10))
        container.wantsLayer = true
        container.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = CGSize(width: 0, height: -6)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            return shadow
        }()
        imageView.frame = container.bounds
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)
        panel.contentView = container

        // On screen (invisibly) from the start, so it exists when the capture filter is
        // built and is excluded from the frames like Klik's other windows.
        panel.alphaValue = 0
        if let frame = frame(for: CGSize(width: width, height: 24)) {
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
        }
    }

    /// Where the panel fits *outside* the region — left, right, above or below it — or
    /// `nil` when the region fills the screen. It must never overlap the region: it would
    /// be captured in every frame and, changing after each stitch, unsettle the matcher.
    private func frame(for size: CGSize) -> CGRect? {
        let visible = screen.visibleFrame
        let gap: CGFloat = 24
        let candidates = [
            CGRect(x: region.minX - gap - size.width, y: region.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: region.maxX + gap, y: region.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: region.minX, y: region.maxY + gap, width: size.width, height: size.height),
            CGRect(x: region.minX, y: region.minY - gap - 44 - size.height, width: size.width, height: size.height), // under the control pill
        ]
        return candidates.first { visible.insetBy(dx: 8, dy: 8).contains($0) && !$0.intersects(region) }
    }

    func update(image: CGImage) {
        let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
        let visible = screen.visibleFrame
        let maxHeight = region.maxY - (visible.minY + 16)
        var size = CGSize(width: width, height: (width * aspect).rounded())
        if size.height > maxHeight {
            size = CGSize(width: (maxHeight / aspect).rounded(), height: maxHeight)
        }
        size.height = max(size.height, 24)

        // Try the full size, then shrink until it fits somewhere outside the region.
        var frame = self.frame(for: size)
        while frame == nil, size.width > 80 {
            size = CGSize(width: (size.width * 0.8).rounded(), height: (size.width * 0.8 * aspect).rounded())
            frame = self.frame(for: size)
        }
        guard let frame else {
            panel.alphaValue = 0 // no room: the pill's frame count is the feedback
            return
        }
        imageView.image = NSImage(cgImage: image, size: frame.size)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func close() { panel.close() }
}
