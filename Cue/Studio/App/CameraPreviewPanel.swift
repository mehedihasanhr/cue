import AppKit
@preconcurrency import AVFoundation
import RecordKit

/// A small live picture of the camera beside the bar, to frame yourself before a take.
///
/// Round and mirrored, like the bubble the editor draws, so what you see here is what the
/// recording will have. It opens the camera only when all of these hold — the camera is
/// turned on in the bar, the grant was already given, the preview is wanted, and the bar is
/// on screen — and lets go of it the moment any stops holding. Nothing here asks for a
/// permission.
///
/// Never in the recording, for the reason the bar is not: it is this app's window, and a
/// display or area recording leaves this app out. `sharingType = .none` keeps it out of
/// other apps' screen sharing too.
///
/// It can be dragged anywhere, before the take or during it, and stays where it was put
/// (a double-click sends it back beside the bar). Where it was left is where the camera
/// starts in the editor: see `placement(in:)`.
@MainActor
final class CameraPreviewPanel {
    static let diameter: CGFloat = 150

    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var deviceID: String?
    private weak var anchor: NSWindow?
    private var observers: [any NSObjectProtocol] = []
    /// Where it was dragged to (its frame's origin), until it is sent back to the bar.
    private var dropped: NSPoint?
    /// Set while this class moves the panel, so only a drag counts as a placement.
    private var placing = false

    var isShowing: Bool { panel?.isVisible ?? false }

    /// Shows the camera near `bar`, or hides it when `deviceID` is `nil`.
    func show(deviceID: String?, near bar: NSWindow?) {
        guard let deviceID, let bar else {
            hide()
            return
        }
        if deviceID != self.deviceID {
            stopSession()
            startSession(deviceID)
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        follow(bar)
        place(panel, beside: bar)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        stopSession()
        follow(nil)
    }

    // MARK: - The camera

    private func startSession(_ id: String) {
        guard WebcamRecorder.isAuthorized,
              let device = AVCaptureDevice(uniqueID: id),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        self.session = session
        deviceID = id
        preview?.session = session
        preview?.connection?.automaticallyAdjustsVideoMirroring = false
        preview?.connection?.isVideoMirrored = true
        // Off the main thread: starting a camera blocks while it wakes.
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    private func stopSession() {
        guard let session else { return }
        preview?.session = nil
        self.session = nil
        deviceID = nil
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    private var preview: AVCaptureVideoPreviewLayer? {
        (panel?.contentView as? PreviewView)?.previewLayer
    }

    // MARK: - The window

    private func makePanel() -> NSPanel {
        let size = NSSize(width: Self.diameter, height: Self.diameter)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        let view = PreviewView(frame: NSRect(origin: .zero, size: size))
        view.onReset = { [weak self] in self?.sendBack() }
        panel.contentView = view
        // The bar's level, so it sits over the target overlay as the bar does.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        if let session {
            view.previewLayer.session = session
            view.previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
            view.previewLayer.connection?.isVideoMirrored = true
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel, !self.placing else { return }
                self.dropped = panel.frame.origin
            }
        }
        return panel
    }

    /// Back beside the bar, following it again.
    private func sendBack() {
        dropped = nil
        guard let panel, let anchor else { return }
        place(panel, beside: anchor)
    }

    /// Where the bubble's centre is within `area` (screen points, origin bottom left),
    /// as fractions with the origin at the top left — `WebcamSettings.position`'s reading.
    /// `nil` when it was never dragged, or sits outside the area.
    func placement(in area: CGRect) -> CGPoint? {
        guard let dropped, area.width > 0, area.height > 0 else { return nil }
        let centre = NSPoint(x: dropped.x + Self.diameter / 2, y: dropped.y + Self.diameter / 2)
        guard area.contains(centre) else { return nil }
        return CGPoint(x: (centre.x - area.minX) / area.width, y: (area.maxY - centre.y) / area.height)
    }

    /// Above the bar's right-hand end, clear of its shadow; or where it was dragged to.
    private func place(_ panel: NSPanel, beside bar: NSWindow) {
        placing = true
        defer { placing = false }
        if let dropped {
            // Kept on a screen, should the one it was left on have gone.
            let frame = NSRect(origin: dropped, size: NSSize(width: Self.diameter, height: Self.diameter))
            let visible = (NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? bar.screen ?? NSScreen.main)?.visibleFrame
            var origin = dropped
            if let visible {
                origin.x = min(max(origin.x, visible.minX), visible.maxX - Self.diameter)
                origin.y = min(max(origin.y, visible.minY), visible.maxY - Self.diameter)
            }
            panel.setFrameOrigin(origin)
            return
        }
        // The bar's window is inset 14 points around the bar itself, for its shadow.
        let inset: CGFloat = 14
        var origin = NSPoint(x: bar.frame.maxX - inset - Self.diameter,
                             y: bar.frame.maxY - inset + 10)
        if let visible = (bar.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.diameter - 8)
            origin.y = min(origin.y, visible.maxY - Self.diameter - 8)
        }
        panel.setFrameOrigin(origin)
    }

    /// Moves with the bar when somebody drags it or it changes width.
    private func follow(_ bar: NSWindow?) {
        guard bar !== anchor || (bar != nil && observers.isEmpty) else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        anchor = bar
        guard let bar else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: bar, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, panel.isVisible, let anchor = self.anchor else { return }
                    self.place(panel, beside: anchor)
                }
            })
        }
    }
}

extension CameraPreviewPanel {
    /// What `target` records, in screen points with the origin at the bottom left; `nil`
    /// for an iPhone or iPad, which is not on this Mac's screen.
    static func screenArea(of target: CaptureTarget) -> CGRect? {
        func screen(_ id: CGDirectDisplayID) -> NSScreen? {
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        }
        // Window bounds are in global points from the top left of the main display.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        switch target {
        case .display(let id):
            return screen(id)?.frame
        case .area(let id, let rect):
            guard let frame = screen(id)?.frame else { return nil }
            return CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        case .window(let id):
            guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
                  let bounds = info[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }) else { return nil }
            return CGRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
        case .device:
            return nil
        }
    }
}

/// A round view whose layer is the camera's preview, dragged by any part of it.
private final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    var onReset: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds
        previewLayer.backgroundColor = NSColor.black.cgColor
        let host = CALayer()
        host.frame = bounds
        host.cornerRadius = min(frame.width, frame.height) / 2
        host.masksToBounds = true
        host.borderWidth = 2
        host.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        host.addSublayer(previewLayer)
        layer = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
