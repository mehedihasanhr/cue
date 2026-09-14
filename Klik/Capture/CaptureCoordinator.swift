import os
import AppKit

/// Drives the three capture flows end to end and reports results to the app.
final class CaptureCoordinator {
    var onCaptured: ((CapturedImage) -> Void)?
    /// Result of a text capture: the recognised text (possibly empty when none was found).
    var onTextRecognized: ((RecognizedText) -> Void)?
    var onPermissionRequired: ((PermissionKind) -> Void)?
    var onError: ((any Error) -> Void)?

    private let service = ScreenCaptureService()
    private let ocr = OCRService()
    private let shortcuts: ShortcutController
    private var isBusy = false

    init(shortcuts: ShortcutController) {
        self.shortcuts = shortcuts
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
            onCaptured?(try await service.captureDisplay(display, includeCursor: includeCursor))
        }
    }

    func captureArea(fromMenu: Bool) {
        start(fromMenu: fromMenu) { [self] in
            guard let selection = try await CaptureSession().run(mode: .region, using: service) else { return }
            guard let image = selection.frozen.cropped(toPoints: selection.localRect) else {
                throw CaptureError.noDisplay
            }
            onCaptured?(image)
        }
    }

    /// Auto-scroll needs Accessibility; without it the session still runs and the user
    /// scrolls by hand, so the permission is not a gate here.
    func captureScrolling(fromMenu: Bool) {
        start(fromMenu: fromMenu) { [self] in
            guard let selection = try await CaptureSession().run(mode: .scrolling, using: service) else { return }
            // Let the overlay windows disappear and the target app regain focus.
            try? await Task.sleep(for: .milliseconds(250))
            let session = ScrollingCaptureSession()
            if let image = try await session.run(selection: selection, service: service, shortcuts: shortcuts) {
                onCaptured?(image)
            }
        }
    }

    /// Select an area and copy the text in it — nothing is saved to the library.
    func captureText(fromMenu: Bool) {
        start(fromMenu: fromMenu) { [self] in
            guard let selection = try await CaptureSession().run(mode: .text, using: service) else { return }
            guard let image = selection.frozen.cropped(toPoints: selection.localRect) else {
                throw CaptureError.noDisplay
            }
            let recognized = try await ocr.recognize(image.cgImage)
            Log.ocr.info("Recognised \(recognized.items.count) line(s) in \(Int(image.pixelSize.width))×\(Int(image.pixelSize.height))px")
            onTextRecognized?(recognized)
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
        Task {
            defer { isBusy = false }
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
