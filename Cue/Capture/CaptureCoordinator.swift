import os
import AppKit

/// Drives the three capture flows end to end and reports results to the app.
final class CaptureCoordinator {
    var onCaptured: ((CapturedImage) -> Void)?
    /// Result of a text capture: the recognised text (possibly empty when none was found).
    var onTextRecognized: ((RecognizedText) -> Void)?
    /// Cue declined to read it, and can say why. Nothing reaches the clipboard.
    var onTextUnavailable: ((OCRUnavailable) -> Void)?
    var onPermissionRequired: ((PermissionKind) -> Void)?
    var onError: ((any Error) -> Void)?
    /// `true` while a capture flow runs (selection overlay, scrolling session…).
    var onBusyChanged: ((Bool) -> Void)?
    /// Result of the color picker.
    var onColorPicked: ((PickedColor) -> Void)?

    private let service = ScreenCaptureService()
    private let shortcuts: ShortcutController
    private let preferences: AppPreferences?
    private let engines: OCREngines?
    private var isBusy = false

    init(shortcuts: ShortcutController, preferences: AppPreferences? = nil, engines: OCREngines? = nil) {
        self.shortcuts = shortcuts
        self.preferences = preferences
        self.engines = engines
    }

    /// Built fresh for each capture, so a language chosen in Settings takes effect on
    /// the very next press rather than the next launch.
    private var ocr: OCRService {
        guard let preferences else { return OCRService() }
        return OCRService(settings: preferences.ocrSettings, engines: engines?.set ?? .onDevice)
    }

    // MARK: - Entry points

    /// `fromMenu` adds a short delay so the status menu has faded out before the capture.
    func captureFullScreen(fromMenu: Bool) {
        start(fromMenu: fromMenu) { [self] in
            let content = try await service.shareableContent()
            guard let display = service.display(containing: NSEvent.mouseLocation, in: content) else {
                throw CaptureError.noDisplay
            }
            let includeCursor = UserDefaults.standard.bool(forKey: PreferenceKey.includeCursor)
            onCaptured?(try await service.captureDisplay(display, in: content, includeCursor: includeCursor))
        }
    }

    func captureArea(fromMenu: Bool) {
        start(fromMenu: fromMenu) { [self] in
            guard let selection = try await CaptureSession(shortcuts: shortcuts).run(mode: .region, using: service) else { return }
            guard let image = selection.frozen.cropped(toPoints: selection.localRect) else {
                throw CaptureError.noDisplay
            }
            onCaptured?(image)
        }
    }

    /// Click a window to capture it alone, with its shadow (or drag an area as usual).
    func captureWindow(fromMenu: Bool) {
        start(fromMenu: fromMenu) { [self] in
            guard let selection = try await CaptureSession(shortcuts: shortcuts).run(mode: .window, using: service) else { return }
            if let window = selection.window {
                let content = try await service.shareableContent()
                if let image = try await service.captureWindow(id: window.id, in: content, fallbackScale: selection.frozen.scale) {
                    onCaptured?(image)
                    return
                }
                Log.capture.notice("Window \(window.id) not shareable; cropping the frozen frame instead")
            }
            guard let image = selection.frozen.cropped(toPoints: selection.localRect) else { throw CaptureError.noDisplay }
            onCaptured?(image)
        }
    }

    /// Auto-scroll needs Accessibility; without it the session still runs and the user
    /// scrolls by hand, so the permission is not a gate here.
    func captureScrolling(fromMenu: Bool) {
        start(fromMenu: fromMenu) { [self] in
            guard let selection = try await CaptureSession(shortcuts: shortcuts).run(mode: .scrolling, using: service) else { return }
            // Let the overlay windows go and the target app regain focus — briefly: until the
            // dimming is up, the page shows bare, and a quarter of a second of it read as
            // the capture flickering off and back on.
            try? await Task.sleep(for: .milliseconds(60))
            let session = ScrollingCaptureSession()
            if let image = try await session.run(selection: selection, service: service, shortcuts: shortcuts) {
                onCaptured?(image)
            }
        }
    }

    /// Select an area and copy the text in it — nothing is saved to the library.
    func captureText(fromMenu: Bool) {
        start(fromMenu: fromMenu) { [self] in
            guard let selection = try await CaptureSession(shortcuts: shortcuts).run(mode: .text, using: service) else { return }
            guard let image = selection.frozen.cropped(toPoints: selection.localRect) else {
                throw CaptureError.noDisplay
            }
            do {
                let recognized = try await ocr.recognize(image.cgImage)
                Log.ocr.info("Recognised \(recognized.items.count) line(s) with \(recognized.engine.rawValue, privacy: .public) in \(Int(image.pixelSize.width))×\(Int(image.pixelSize.height))px")
                onTextRecognized?(recognized)
            } catch OCRError.unavailable(let reason) {
                onTextUnavailable?(reason)
            }
        }
    }

    /// The pixel-grid color picker over frozen displays.
    func pickColor(fromMenu: Bool) {
        start(fromMenu: fromMenu) { [self] in
            if let color = try await ColorPickerSession(shortcuts: shortcuts).run(using: service) {
                onColorPicked?(color)
            }
        }
    }

    // MARK: - Common flow

    private func start(
        fromMenu: Bool,
        requires permissions: [PermissionKind] = [.screenRecording],
        _ body: @escaping () async throws -> Void
    ) {
        guard !isBusy else {
            Log.capture.notice("Capture requested while another is running; ignored")
            return
        }
        for permission in permissions where !PermissionManager.has(permission) {
            onPermissionRequired?(permission)
            return
        }
        isBusy = true
        onBusyChanged?(true)
        Task {
            defer {
                isBusy = false
                onBusyChanged?(false)
            }
            if fromMenu {
                try? await Task.sleep(for: .milliseconds(200))
            }
            do {
                try await body()
            } catch CaptureError.permissionDenied {
                onPermissionRequired?(.screenRecording)
            } catch CaptureError.cancelled {
                // User backed out; nothing to report.
            } catch {
                Log.capture.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                onError?(error)
            }
        }
    }
}

extension RegionSelection {
    /// The selection in the frozen image's coordinate space (screen-local points, y up).
    var localRect: CGRect {
        rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }
}
