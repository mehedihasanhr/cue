import AppKit
import SwiftUI

/// A capture kept floating above every window, to work against. It opens at a
/// handy size (fits 380 pt), and grows or shrinks by dragging its corner grip or
/// any edge, ⌘= / ⌘- / ⌘0, or ⌥-scroll; drag anywhere else to move it. Hover for
/// its buttons (ghost = half see-through and click-through, copy, close),
/// double-click to toggle ghost, ⎋ closes.
final class PinnedCaptureWindow: NSPanel {
    private static var open: [PinnedCaptureWindow] = []
    private let image: NSImage
    private var ghost = false {
        didSet {
            ignoresMouseEvents = ghost
            animator().alphaValue = ghost ? 0.5 : 1
        }
    }

    /// Opens the image near the pointer, scaled to fit a handy 380 pt box.
    @discardableResult
    static func pin(_ image: NSImage, onCopy: @escaping () -> Void) -> PinnedCaptureWindow {
        let window = PinnedCaptureWindow(image: image, onCopy: onCopy)
        open.append(window)
        return window
    }

    /// Ghost mode is toggled from outside too (the hover bar and a double-click).
    func toggleGhost() { ghost.toggle() }

    /// Unghosts every pinned window (⌥⇧U from the palette, say) — the way back once
    /// they no longer take clicks.
    static func unghostAll() { open.forEach { if $0.ghost { $0.ghost = false } } }

    private init(image: NSImage, onCopy: @escaping () -> Void) {
        self.image = image
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let limit = CGSize(width: min(380, visible.width * 0.6), height: min(380, visible.height * 0.6))
        let scale = min(limit.width / max(image.size.width, 1), limit.height / max(image.size.height, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let pointer = NSEvent.mouseLocation
        let origin = CGPoint(x: min(max(pointer.x - size.width / 2, visible.minX), visible.maxX - size.width),
                             y: min(max(pointer.y - size.height / 2, visible.minY), visible.maxY - size.height))
        super.init(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
        contentAspectRatio = image.size
        minSize = CGSize(width: 80, height: 80 * image.size.height / max(image.size.width, 1))

        let content = PinnedCaptureView(image: image, onClose: { [weak self] in self?.close() },
                                        onGhost: { [weak self] in self?.toggleGhost() }, onCopy: onCopy,
                                        onResize: { [weak self] width in self?.resize(toWidth: width) },
                                        onResizeEnded: { [weak self] in self?.resizeOrigin = nil })
        contentView = NSHostingView(rootView: content)
        makeKeyAndOrderFront(nil)
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        Self.open.removeAll { $0 === self }
        super.close()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoom(by: 1.15)
        case "-": zoom(by: 1 / 1.15)
        case "0": zoom(to: 1)
        case "w": close()
        default: super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else { super.scrollWheel(with: event); return }
        zoom(by: 1 + max(-0.5, min(0.5, event.scrollingDeltaY / 100)))
    }

    /// The corner grip: the top-left corner stays put, the width follows the drag.
    private var resizeOrigin: CGRect?

    private func resize(toWidth width: CGFloat) {
        let start = resizeOrigin ?? frame
        resizeOrigin = start
        let visible = screen?.visibleFrame ?? start
        let ratio = image.size.height / max(image.size.width, 1)
        let clampedWidth = max(minSize.width, min(width, visible.maxX - start.minX, (start.maxY - visible.minY) / ratio))
        let size = CGSize(width: clampedWidth.rounded(), height: (clampedWidth * ratio).rounded())
        setFrame(CGRect(x: start.minX, y: start.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// Scales around the centre, never below the minimum nor beyond the screen.
    private func zoom(by factor: CGFloat) {
        zoom(to: frame.width / max(image.size.width, 1) * factor)
    }

    private func zoom(to scale: CGFloat) {
        let visible = screen?.visibleFrame ?? frame
        let maxScale = min(visible.width / max(image.size.width, 1), visible.height / max(image.size.height, 1))
        let clamped = max(minSize.width / max(image.size.width, 1), min(scale, maxScale))
        let size = CGSize(width: image.size.width * clamped, height: image.size.height * clamped)
        var rect = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, visible.minY), visible.maxY - rect.height)
        setFrame(rect, display: true, animate: true)
    }
}

private struct PinnedCaptureView: View {
    let image: NSImage
    let onClose: () -> Void
    let onGhost: () -> Void
    let onCopy: () -> Void
    /// The width the corner grip is being dragged to, then that the drag ended.
    let onResize: (CGFloat) -> Void
    let onResizeEnded: () -> Void
    @State private var hovering = false
    @State private var copied = false
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .overlay(alignment: .top) {
                if hovering {
                    HStack(spacing: 6) {
                        button("xmark", help: "Close (⎋)", action: onClose)
                        Spacer(minLength: 0)
                        button(copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                            onCopy()
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                        }
                        button("eye.slash", help: "Ghost: half see-through and click-through (double-click to toggle back)", action: onGhost)
                    }
                    .padding(6)
                    .background(LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // The resize grip: three short diagonal lines, always there faintly,
                // solid under the pointer; dragging it scales the window from its top-left.
                GeometryReader { proxy in
                    Color.clear
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(.black.opacity(hovering ? 0.7 : 0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .padding(5)
                                .contentShape(Rectangle())
                                .onHover { over in if over { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                                .gesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                        .onChanged { value in
                                            if dragStartWidth == nil { dragStartWidth = proxy.size.width }
                                            onResize((dragStartWidth ?? proxy.size.width) + value.translation.width)
                                        }
                                        .onEnded { _ in dragStartWidth = nil; onResizeEnded() }
                                )
                                .help("Drag to resize (⌘= / ⌘- / ⌘0 too)")
                                .accessibilityLabel("Resize")
                        }
                }
            }
            .onHover { over in withAnimation(.easeOut(duration: 0.12)) { hovering = over } }
            .onTapGesture(count: 2, perform: onGhost)
            .accessibilityLabel("Pinned screenshot")
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.7), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
