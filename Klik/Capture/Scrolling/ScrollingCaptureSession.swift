import os
import AppKit

/// CleanShot-style scrolling capture: the region stays framed and live, the rest of
/// the screen dims, a preview of the stitched result grows beside the region, and a
/// Cancel / Done pill sits on the region's bottom edge.
///
/// The user scrolls the content by hand (in either direction). A ScreenCaptureKit
/// stream delivers frames of the region continuously; a background worker stitches
/// them as they arrive and hands the main actor a small preview. The capture ends
/// when the user clicks Done (↩) or Cancel (⎋).
final class ScrollingCaptureSession {
    private enum Outcome {
        case done
        case cancelled
    }

    private var continuation: CheckedContinuation<Outcome, Never>?

    private func finish(_ outcome: Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func run(
        selection: RegionSelection,
        service: ScreenCaptureService,
        shortcuts: ShortcutController
    ) async throws(CaptureError) -> CapturedImage? {
        let region = selection.rect
        let screen = selection.screen

        let worker = StitchWorker(previewWidth: 640)

        let status = ScrollingStatus()
        status.autoScroll = false
        let dim = ScrollingDimWindow(screen: screen, region: region)
        let controls = ScrollingControlPanel(
            status: status,
            onCancel: { [weak self] in self?.finish(.cancelled) },
            onDone: { [weak self] in self?.finish(.done) }
        )
        let preview = ScrollingPreviewPanel(region: region, screen: screen)
        dim.orderFrontRegardless()
        controls.show(below: region, on: screen)

        let escape = shortcuts.registerTemporary(.escape, id: .cancelCapture) { [weak self] in self?.finish(.cancelled) }
        let enter = shortcuts.registerTemporary(.enter, id: .confirmCapture) { [weak self] in self?.finish(.done) }

        defer {
            dim.close()
            controls.close()
            preview.close()
            withExtendedLifetime((escape, enter)) {}
        }

        // Build the content filter only now: ScreenCaptureKit resolves "exclude this app's
        // windows" against the windows that exist at filter creation, so the dim overlay and
        // the control pill must already be on screen to be left out of the frames.
        let capturer = try await service.makeRegionCapturer(region, on: screen)
        let scale = capturer.scale
        let stream = RegionFrameStream(filter: capturer.filter, configuration: capturer.configuration) { frame in
            let update = await worker.ingest(frame)
            guard let image = update.preview else { return }
            await MainActor.run {
                status.frames = update.frames
                preview.update(image: image)
            }
        }

        do {
            try await stream.start()
        } catch {
            Log.capture.error("Could not start scrolling stream: \(error.localizedDescription, privacy: .public)")
            throw .underlying(error)
        }
        Log.capture.info("Scrolling capture started: \(Int(region.width))×\(Int(region.height))pt")

        let outcome = await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        await stream.stop()

        guard outcome == .done, let cgImage = await worker.finish() else {
            Log.capture.info("Scrolling capture cancelled")
            return nil
        }
        Log.capture.info("Scrolling capture finished: \(cgImage.width)×\(cgImage.height)px")
        return CapturedImage(cgImage: cgImage, scale: scale, displayID: capturer.displayID, capturedAt: .now)
    }
}
