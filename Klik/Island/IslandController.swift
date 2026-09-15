import os
import AppKit
import SwiftUI

/// Owns the Dynamic Island: places it on the notch (or as a pill on a plain display),
/// opens the captures panel when the pointer rests on it, closes it when the pointer
/// leaves, and flashes each new capture.
@MainActor
final class IslandController {
    private let window = IslandWindow()
    private let model = IslandModel()
    private let preferences: AppPreferences

    private var closeTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var shadowTask: Task<Void, Never>?
    /// Menus (layout picker, context menus) take the pointer away without leaving.
    private var menusTracking = 0
    /// Hidden while a capture flow runs; a capture that lands meanwhile flashes after.
    private var hidden = false
    private var pendingFlash: CaptureItem?
    private var observers: [any NSObjectProtocol] = []

    private static let closeDelay: Duration = .milliseconds(250)
    private static let flashDuration: Duration = .seconds(1.8)
    private static let collapseAnimation: Duration = .milliseconds(380)

    init(library: CaptureLibrary, actions: HistoryActions, preferences: AppPreferences) {
        self.preferences = preferences

        let content = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        let host = NSHostingView(rootView: IslandView(model: model, library: library, actions: actions))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = content.bounds
        content.addSubview(host)
        window.contentView = content
        window.onEscape = { [weak self] in self?.collapse() }
        model.onTap = { [weak self] in self?.expand() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menusTracking += 1 }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menusTracking = max(0, (self?.menusTracking ?? 1) - 1) }
        })
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        installPointerMonitors()
        place()
    }

    private var wakeObserver: (any NSObjectProtocol)?
    private var pointerMonitors: [Any] = []
    private var pointerInside = false

    /// The window server sends no tracking-area events for a window on the notch, so
    /// the island watches mouse-moved events instead: the global monitor covers the
    /// pointer over other apps, the local one the island itself. The handler is a
    /// single rect test, and nothing runs while the pointer is still.
    private func installPointerMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        })
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        })
        pointerMonitors = [global, local].compactMap { $0 }
    }

    private func pointerMoved() {
        guard let geometry = model.geometry, !hidden, window.isVisible else { return }
        let location = NSEvent.mouseLocation
        // The drawn shape, not the (mostly transparent) window. The pointer stops at
        // the very top edge (y == maxY), which must count as inside.
        let frame = geometry.rect(for: model.phase.geometryPhase)
        let inside = location.x >= frame.minX && location.x <= frame.maxX
            && location.y >= frame.minY && location.y <= frame.maxY
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside { pointerEntered() } else { pointerExited() }
    }

    /// Removes the island; the controller is dropped afterwards.
    func tearDown() {
        closeTask?.cancel()
        flashTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        pointerMonitors.forEach { NSEvent.removeMonitor($0) }
        pointerMonitors.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        window.orderOut(nil)
        window.close()
    }

    // MARK: - Placement

    /// The notched screen if there is one, otherwise the primary display (unless the
    /// pill is turned off for plain displays).
    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notched }
        return preferences.dynamicIslandOnPlainDisplays ? screens.first : nil
    }

    func place() {
        guard let screen = targetScreen() else {
            model.geometry = nil
            window.orderOut(nil)
            Log.app.info("Dynamic Island: no eligible display")
            return
        }
        let metrics = ScreenMetrics(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        )
        let geometry = IslandGeometry(screen: metrics, panelSize: IslandPanel.size)
        model.geometry = geometry
        setPhase(.collapsed, animated: false)
        window.setFrame(geometry.windowRect, display: true)
        if !hidden { window.orderFrontRegardless() }
        Log.app.info("Dynamic Island on \(screen.localizedName, privacy: .public) notch=\(metrics.hasNotch) rect=\(String(describing: geometry.collapsed), privacy: .public)")
    }

    /// Hidden for the duration of a capture flow so the selection overlay can't open it.
    func setHidden(_ hidden: Bool) {
        guard self.hidden != hidden else { return }
        self.hidden = hidden
        if hidden {
            collapse(animated: false)
            window.orderOut(nil)
        } else if model.geometry != nil {
            window.orderFrontRegardless()
            if let item = pendingFlash {
                pendingFlash = nil
                flash(item)
            }
        }
    }

    // MARK: - Phases

    func expand() {
        guard model.geometry != nil, !hidden, model.phase != .expanded else { return }
        closeTask?.cancel()
        flashTask?.cancel()
        window.orderFrontRegardless()
        setPhase(.expanded, animated: true)
        scheduleShadow()
    }

    /// The window server draws the shadow (free per frame, unlike a SwiftUI shadow on
    /// an animating shape); it is switched on once the shape has settled and off before
    /// it shrinks, so the notch itself never gets one.
    private func scheduleShadow() {
        shadowTask?.cancel()
        shadowTask = Task { [weak self] in
            try? await Task.sleep(for: Self.collapseAnimation)
            guard !Task.isCancelled, let self, model.phase != .collapsed else { return }
            window.hasShadow = true
            window.invalidateShadow()
        }
    }

    func collapse(animated: Bool = true) {
        flashTask?.cancel()
        closeTask?.cancel()
        guard model.phase != .collapsed else { return }
        shadowTask?.cancel()
        window.hasShadow = false
        setPhase(.collapsed, animated: animated)
        if animated {
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: Self.collapseAnimation)
                guard !Task.isCancelled else { return }
                self?.didCollapse()
            }
        } else {
            didCollapse()
        }
    }

    /// Show the capture that was just taken for a moment; hovering it meanwhile opens
    /// the full panel instead.
    func flash(_ item: CaptureItem) {
        if hidden {
            pendingFlash = item
            return
        }
        guard model.geometry != nil, model.phase != .expanded else { return }
        flashTask?.cancel()
        closeTask?.cancel()
        window.orderFrontRegardless()
        setPhase(.flash(item), animated: true)
        scheduleShadow()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flashDuration)
            guard !Task.isCancelled, let self, case .flash = model.phase else { return }
            collapse()
        }
    }

    private func setPhase(_ phase: IslandModel.Phase, animated: Bool) {
        if animated {
            let animation = phase == .collapsed ? IslandView.closeAnimation : IslandView.openAnimation
            withAnimation(animation) { model.phase = phase }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.phase = phase }
        }
    }

    /// Giving up key status (if a control inside took it) returns typing to the
    /// user's app; re-ordering front without key is the only way to drop it.
    private func didCollapse() {
        guard model.phase == .collapsed else { return }
        pointerInside = false
        if window.isKeyWindow {
            window.orderOut(nil)
            if !hidden { window.orderFrontRegardless() }
        }
    }

    // MARK: - Pointer

    private func pointerEntered() {
        closeTask?.cancel()
        switch model.phase {
        case .collapsed, .flash:
            expand()
        case .expanded:
            break
        }
    }

    private func pointerExited() {
        guard model.phase == .expanded else { return }
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.closeDelay)
            // A drag out of the panel or an open menu keeps it open until they finish.
            while !Task.isCancelled, let self, NSEvent.pressedMouseButtons != 0 || menusTracking > 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, let self else { return }
            if let geometry = model.geometry, geometry.rect(for: model.phase.geometryPhase).contains(NSEvent.mouseLocation) {
                pointerInside = true
                return
            }
            collapse()
        }
    }
}
