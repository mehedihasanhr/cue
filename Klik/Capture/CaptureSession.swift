import os
import AppKit

enum CaptureMode {
    case region
    case scrolling
    /// Same selection UX as `region`; the result goes to OCR instead of the library.
    case text
    /// Hover highlights a window, a click takes it (with its shadow); a drag still
    /// selects an area.
    case window

    /// Area-style modes capture the moment the mouse is released; scrolling waits for "Start".
    var confirmsOnRelease: Bool { self != .scrolling }
}

/// What the user picked in the overlay.
struct RegionSelection {
    /// Global AppKit coordinates (points).
    let rect: CGRect
    let screen: NSScreen
    /// The frozen frame of `screen` the selection was made on.
    let frozen: CapturedImage
    /// The window that was clicked, in window mode.
    var window: WindowInfo? = nil
}

/// Runs one area-selection interaction across all screens: freezes every display,
/// shows an overlay per screen, and resolves with the chosen region (or `nil`).
final class CaptureSession: SelectionViewDelegate {
    private var controllers: [OverlayWindowController] = []
    private var continuation: CheckedContinuation<RegionSelection?, Never>?
    private var activeView: SelectionView?
    private var previousApp: NSRunningApplication?

    func run(mode: CaptureMode, using service: ScreenCaptureService) async throws(CaptureError) -> RegionSelection? {
        let frozen = try await service.captureAllDisplays()
        // Plain area selection, as in CleanShot, except in window mode, where the
        // windows on screen light up under the pointer.
        let windows: [WindowInfo] = mode == .window ? WindowDetector.onScreenWindows() : []
        previousApp = NSWorkspace.shared.frontmostApplication

        for screen in NSScreen.screens {
            guard let displayID = screen.displayID, let image = frozen[displayID] else { continue }
            let localWindows = windows.map {
                WindowInfo(id: $0.id, ownerName: $0.ownerName, title: $0.title,
                           frame: $0.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY))
            }
            controllers.append(OverlayWindowController(
                screen: screen, frozen: image, mode: mode, windows: localWindows, delegate: self
            ))
        }
        guard !controllers.isEmpty else { throw .noDisplay }

        let mouse = NSEvent.mouseLocation
        let initial = controllers.first { NSMouseInRect(mouse, $0.screen.frame, false) } ?? controllers[0]
        for controller in controllers {
            controller.present(makeKey: controller === initial)
        }
        if let window = initial.window {
            NSApp.activateForOverlay(keyWindow: window)
            window.makeFirstResponder(initial.selectionView)
        }
        activeView = initial.selectionView
        Log.capture.info("Selection overlay shown on \(self.controllers.count) screen(s)")

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func finish(with result: RegionSelection?) {
        guard let continuation else { return }
        self.continuation = nil
        for controller in controllers {
            controller.close()
        }
        controllers.removeAll()
        NSCursor.arrow.set()
        // Hand focus back so a scrolling capture scrolls the app the user was in.
        previousApp?.activate(from: .current, options: [])
        continuation.resume(returning: result)
    }

    // MARK: - SelectionViewDelegate

    func selectionViewDidBeginInteraction(_ view: SelectionView) {
        activeView = view
        for controller in controllers where controller.selectionView !== view {
            controller.selectionView.becomePassive()
        }
    }

    func selectionViewWantsFocus(_ view: SelectionView) -> Bool {
        if let activeView, activeView !== view, activeView.hasSelection {
            return false
        }
        for controller in controllers where controller.selectionView !== view {
            controller.selectionView.becomePassive()
        }
        activeView = view
        return true
    }

    func selectionViewDidCancel(_ view: SelectionView) {
        finish(with: nil)
    }

    func selectionView(_ view: SelectionView, didConfirm rect: CGRect) {
        guard let controller = controllers.first(where: { $0.selectionView === view }) else { return }
        let global = rect.offsetBy(dx: controller.screen.frame.minX, dy: controller.screen.frame.minY)
        finish(with: RegionSelection(rect: global, screen: controller.screen, frozen: controller.frozen, window: view.pickedWindow))
    }
}
