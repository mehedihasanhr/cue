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
        let dump = FrameDump.ifEnabled()
        let stream = RegionFrameStream(filter: capturer.filter, configuration: capturer.configuration) { frame in
            let update = await worker.ingest(frame)
            dump?.record(frame, result: update.result)
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
        dump?.finish(result: cgImage)
        return CapturedImage(cgImage: cgImage, scale: scale, displayID: capturer.displayID, capturedAt: .now)
    }
}

/// Diagnostics: with `defaults write com.stackrover.cue debug.dumpScrollFrames -bool YES`
/// every frame of a scrolling capture is written as PNG, with the engine's decision per
/// frame, so a failing page can be replayed offline (see `FrameStitcherTests`).
nonisolated final class FrameDump: Sendable {
    private let folder: URL
    private let queue = DispatchQueue(label: "com.stackrover.cue.frame-dump", qos: .utility)
    private let count = OSAllocatedUnfairLock(initialState: 0)

    static func ifEnabled() -> FrameDump? {
        guard UserDefaults.standard.bool(forKey: "debug.dumpScrollFrames") else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ScrollFrames \(formatter.string(from: .now))", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        Log.capture.notice("Scrolling capture: dumping frames to \(folder.path, privacy: .public)")
        return FrameDump(folder: folder)
    }

    private init(folder: URL) {
        self.folder = folder
    }

    func record(_ frame: Bitmap, result: ScrollingCaptureEngine.Ingest) {
        let index = count.withLock { $0 += 1; return $0 }
        queue.async { [folder] in
            if let image = frame.cgImage, let png = ImageEncoding.png(image) {
                try? png.write(to: folder.appendingPathComponent(String(format: "frame-%04d.png", index)))
            }
            let line = String(format: "%04d %@\n", index, String(describing: result))
            if let handle = try? FileHandle(forWritingTo: folder.appendingPathComponent("decisions.txt")) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: folder.appendingPathComponent("decisions.txt"))
            }
        }
    }

    func finish(result: CGImage) {
        queue.async { [folder] in
            if let png = ImageEncoding.png(result) {
                try? png.write(to: folder.appendingPathComponent("result.png"))
            }
            Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
    }
}
