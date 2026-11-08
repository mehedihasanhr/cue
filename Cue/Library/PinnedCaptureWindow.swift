import AppKit
import SwiftUI

/// A capture kept floating above every window, to work against. It opens in the
/// bottom-right corner at a handy size (fits 280 pt), each new one a step up and to
/// the left of the last, and grows or shrinks by dragging its corner grip or any
/// edge, ⌘= / ⌘- / ⌘0, or ⌥-scroll; dragging the picture itself moves it. Hover for
/// its buttons (close, edit, copy, faded = see through it to the work underneath),
/// ⎋ closes. Faded only thins the picture: the window still takes clicks, so its own
/// buttons stay there and the eye button brings it back.
final class PinnedCaptureWindow: NSPanel {
    private static var open: [PinnedCaptureWindow] = []
    private let image: NSImage
    #if DEBUG
    /// What its buttons do, for `cue://debug/pinned`.
    private var debugCopy: (() -> Void)?
    private var debugEdit: (() -> Void)?
    /// The pinned windows on screen, oldest first — `cue://debug/pinned` drives the newest.
    static var debugWindows: [PinnedCaptureWindow] { open }

    /// Runs one of the hover bar's buttons without a pointer.
    func debugRun(_ action: String) {
        switch action {
        case "copy": debugCopy?()
        case "edit": debugEdit?()
        case "ghost": toggleGhost()
        case "close": close()
        default: break
        }
    }
    #endif
    /// Faded: see-through, but still clickable — a window that took no clicks could
    /// not be brought back from the window itself.
    private var ghost = false {
        didSet { animator().alphaValue = ghost ? 0.45 : 1 }
    }

    /// Opens the image near the pointer, scaled to fit a handy 380 pt box. With an
    /// `onEdit`, an edit button joins the hover bar and closes the window as the
    /// editor takes over.
    @discardableResult
    static func pin(_ image: NSImage, onCopy: @escaping () -> Void, onEdit: (() -> Void)? = nil) -> PinnedCaptureWindow {
        let window = PinnedCaptureWindow(image: image, onCopy: onCopy, onEdit: onEdit)
        open.append(window)
        return window
    }

    /// Fading is toggled from outside too (the hover bar's eye button).
    func toggleGhost() { ghost.toggle() }

    /// Brings every faded pin back to full strength in one go (from the palette).
    static func unghostAll() { open.forEach { if $0.ghost { $0.ghost = false } } }

    /// The box a new pin fits inside, and the room it keeps from the screen's edges.
    private static let openBox: CGFloat = 280
    private static let margin: CGFloat = 24
    /// Each pin opened while others are up steps away from the corner, so one does
    /// not bury the last.
    private static let step: CGFloat = 28

    private init(image: NSImage, onCopy: @escaping () -> Void, onEdit: (() -> Void)?) {
        self.image = image
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let limit = CGSize(width: min(Self.openBox, visible.width * 0.6), height: min(Self.openBox, visible.height * 0.6))
        let scale = min(limit.width / max(image.size.width, 1), limit.height / max(image.size.height, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        // The bottom-right corner, each further pin a step up and to the left, cycling
        // back to the corner before it would leave the screen.
        let steps = CGFloat(Self.open.count % 6)
        let corner = CGPoint(x: visible.maxX - size.width - Self.margin - steps * Self.step,
                             y: visible.minY + Self.margin + steps * Self.step)
        let origin = CGPoint(x: min(max(corner.x, visible.minX), max(visible.maxX - size.width, visible.minX)),
                             y: min(max(corner.y, visible.minY), max(visible.maxY - size.height, visible.minY)))
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
                                        onEdit: onEdit.map { edit in { [weak self] in self?.close(); edit() } },
                                        onResize: { [weak self] width in self?.resize(toWidth: width) },
                                        onResizeEnded: { [weak self] in self?.resizeOrigin = nil },
                                        onMove: { [weak self] translation in self?.move(by: translation) },
                                        onMoveEnded: { [weak self] in self?.moveOrigin = nil })
        contentView = NSHostingView(rootView: content)
        #if DEBUG
        debugCopy = onCopy
        debugEdit = onEdit.map { edit in { [weak self] in self?.close(); edit() } }
        #endif
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

    /// Where the window stood when the move began; the drag's whole translation is
    /// applied to it, so the window cannot drift as the pointer is caught up with.
    private var moveOrigin: CGRect?

    /// Dragging the picture moves the window, anywhere across the displays — far
    /// enough onto one that it can always be grabbed again.
    private func move(by translation: CGSize) {
        let start = moveOrigin ?? frame
        moveOrigin = start
        // The drag's y grows downward, the screen's upward.
        var origin = CGPoint(x: start.minX + translation.width, y: start.minY - translation.height)
        let room = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        if !room.isNull {
            let edge: CGFloat = 60 // this much of the window stays reachable
            origin.x = min(max(origin.x, room.minX - start.width + edge), room.maxX - edge)
            origin.y = min(max(origin.y, room.minY - start.height + edge), room.maxY - edge)
        }
        setFrameOrigin(origin)
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
    /// Hands the shot to the editor, when there is one to hand it to.
    let onEdit: (() -> Void)?
    /// The width the corner grip is being dragged to, then that the drag ended.
    let onResize: (CGFloat) -> Void
    let onResizeEnded: () -> Void
    /// How far the picture has been dragged since the move began, and that it ended.
    let onMove: (CGSize) -> Void
    let onMoveEnded: () -> Void
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
                        if let onEdit {
                            button("pencil.tip.crop.circle", help: "Edit", action: onEdit)
                        }
                        button(copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                            onCopy()
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                        }
                        button("eye.slash", help: "Fade it, to see the work underneath; press again to bring it back", action: onGhost)
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

            // Dragging the picture moves the window. The grip and the hover buttons sit
            // above this, so they keep their own gestures.
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { onMove($0.translation) }
                    .onEnded { _ in onMoveEnded() }
            )
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
