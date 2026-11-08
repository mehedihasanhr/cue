import AppKit
import SwiftUI

/// Puts the quick wheel on screen round the pointer and does what is chosen.
///
/// It opens on a three-finger tap (`ThreeFingerTap`) or its shortcut, and closes on
/// the next click, Escape, or a second tap. The pointer is followed while it is up, so
/// moving out onto a segment lights it the way the convert wheel's does; clicking the
/// lit segment runs it.
@MainActor
final class QuickWheelController {
    private let preferences: AppPreferences
    private let model = QuickWheelModel()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var hideTask: Task<Void, Never>?
    /// Where the ring was put, in screen coordinates: the pointer's place at the tap.
    private var centre: CGPoint = .zero
    /// Set by the app: what each segment does.
    var run: (QuickAction) -> Void = { _ in }

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    var isShown: Bool { panel?.isVisible == true && model.shown }

    /// Starts listening for the gesture. Without Accessibility the gesture can't be
    /// read, and the wheel is left to its shortcut; the caller is told so it can say.
    @discardableResult
    func start() -> Bool {
        ThreeFingerTap.active = preferences.quickWheelEnabled
        return ThreeFingerTap.start { [weak self] in self?.toggle() }
    }

    /// Settings turned the gesture on or off.
    func applyPreference() {
        ThreeFingerTap.active = preferences.quickWheelEnabled
        if !preferences.quickWheelEnabled { hide() }
    }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        guard !isShown else { return }
        hideTask?.cancel()
        let pointer = NSEvent.mouseLocation
        centre = Self.centre(for: pointer)
        let panel = panel ?? makePanel()
        self.panel = panel
        model.hovered = nil
        panel.setFrame(CGRect(x: centre.x - WheelGeometry.window.width / 2, y: centre.y - WheelGeometry.window.height / 2,
                              width: WheelGeometry.window.width, height: WheelGeometry.window.height), display: false)
        panel.orderFrontRegardless()
        model.shown = true
        listen()
    }

    func hide() {
        hideTask?.cancel()
        stopListening()
        guard let panel, panel.isVisible else { return }
        model.shown = false
        model.hovered = nil
        hideTask = Task { [weak self] in
            // Once it has animated itself away, not before: pulled out
            // early, the last of the wheel vanishes mid-fade.
            try? await Task.sleep(for: .milliseconds(WheelGeometry.fadeOut))
            guard let self, !model.shown else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// The pointer, a click and Escape, while the ring is up. The panel never takes
    /// focus, so these are watched from here rather than inside it.
    private func listen() {
        guard monitors.isEmpty else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in self?.follow() }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in self?.follow(); return event }) { monitors.append(local) }
        // Only clicks away from the ring are watched here: one on the ring belongs to
        // the panel, which takes it itself so it never reaches the window behind.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in self?.clickedAway() }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            self?.clickedAway()
            return event
        }) { monitors.append(local) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, isShown, event.keyCode == 53 else { return event }
            hide()
            return nil
        }) { monitors.append(keys) }
        // Escape while another app is in front; it needs Accessibility, and clicking
        // away closes the ring whether or not Cue has it.
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            self?.hide()
        }) { monitors.append(keys) }
    }

    private func stopListening() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    /// Which segment the pointer is over, if any.
    private func follow() {
        guard isShown else { return }
        let pointer = NSEvent.mouseLocation
        let index = WheelGeometry.index(at: CGPoint(x: pointer.x - centre.x, y: pointer.y - centre.y), count: model.actions.count)
        let action = index.map { model.actions[$0] }
        if model.hovered != action { model.hovered = action }
    }

    /// A click anywhere but the disc puts the ring away, choosing nothing. The disc,
    /// not the window: its bare corners are not part of the ring (see the hit view).
    private func clickedAway() {
        guard isShown else { return }
        let pointer = NSEvent.mouseLocation
        let reach = WheelGeometry.outer + WheelGeometry.rim
        guard hypot(pointer.x - centre.x, pointer.y - centre.y) > reach else { return }
        hide()
    }

    /// A click on the ring: a segment runs it, the middle just closes.
    private func chose() {
        guard isShown else { return }
        follow()
        let action = model.hovered
        hide()
        guard let action else { return }
        // After the ring has gone, so a capture never catches it on screen.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.run(action)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: WheelGeometry.window), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // The ring takes its own clicks, so choosing a segment never also clicks
        // whatever happens to be under it.
        let content = QuickWheelHitView(frame: CGRect(origin: .zero, size: WheelGeometry.window))
        content.onClick = { [weak self] in self?.chose() }
        let host = NSHostingView(rootView: QuickWheelView(model: model))
        host.sizingOptions = []
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        panel.contentView = content
        return panel
    }

    /// The ring sits on the pointer, pulled back far enough from the screen's edges
    /// that neither a segment nor the shadow round it falls off.
    private static func centre(for pointer: CGPoint) -> CGPoint {
        let visible = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let reach = WheelGeometry.window.width / 2
        guard !visible.isEmpty else { return pointer }
        return CGPoint(x: min(max(pointer.x, visible.minX + reach), visible.maxX - reach),
                       y: min(max(pointer.y, visible.minY + reach), visible.maxY - reach))
    }

    /// For diagnostics: the ring at the pointer, with one segment lit.
    func debugShow(hovered: QuickAction?) {
        show()
        model.hovered = hovered
    }

    /// For diagnostics: where the ring is, in screen coordinates.
    var debugFrame: CGRect { panel?.frame ?? .zero }
}

/// The ring's window content: takes the clicks on it so they go no further, and
/// lets the ones outside the disc through to put it away.
private final class QuickWheelHitView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the disc itself: a click on the window's bare corners is a click away.
        let centred = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
        let reach = WheelGeometry.outer + WheelGeometry.rim
        return hypot(centred.x, centred.y) <= reach ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func otherMouseDown(with event: NSEvent) { onClick?() }
}
