import os
import ScreenCaptureKit

/// A continuous ScreenCaptureKit stream of one screen region. Frames are delivered
/// on a private queue as `Bitmap`s; a frame that arrives while the previous one is
/// still being processed is dropped, so the stitcher never falls behind the screen.
nonisolated final class RegionFrameStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private let stream: SCStream
    private let queue = DispatchQueue(label: "com.stackrover.klik.scrolling-frames", qos: .userInteractive)
    private let handler: @Sendable (Bitmap) async -> Void
    private let busy = OSAllocatedUnfairLock(initialState: false)

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, framesPerSecond: Int = 60,
         handler: @escaping @Sendable (Bitmap) async -> Void) {
        let config = configuration.copy() as! SCStreamConfiguration
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        config.queueDepth = 6
        config.showsCursor = false
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        self.handler = handler
        super.init()
    }

    func start() async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stop() async {
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        // Drop the frame if the stitcher is still chewing on the previous one.
        let claimed = busy.withLock { isBusy -> Bool in
            if isBusy { return false }
            isBusy = true
            return true
        }
        guard claimed, let bitmap = Bitmap(pixelBuffer: pixelBuffer) else {
            if claimed { busy.withLock { $0 = false } }
            return
        }
        Task { [handler, busy] in
            await handler(bitmap)
            busy.withLock { $0 = false }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Log.capture.error("Scrolling frame stream stopped: \(error.localizedDescription, privacy: .public)")
    }
}

/// Owns the stitching engine off the main actor so frame matching never blocks the UI.
actor StitchWorker {
    struct Update: Sendable {
        let result: ScrollingCaptureEngine.Ingest
        let frames: Int
        /// A reduced composite for the live preview, only when the result grew.
        let preview: CGImage?
    }

    private let engine: ScrollingCaptureEngine
    private let previewWidth: Int

    init(expectedOverlap: Int, previewWidth: Int) {
        engine = ScrollingCaptureEngine(expectedOverlap: expectedOverlap)
        self.previewWidth = previewWidth
    }

    func ingest(_ frame: Bitmap) -> Update {
        let result = engine.ingest(frame)
        switch result {
        case .first, .appended, .prepended:
            let preview = engine.compose()?.cgImage.map { Self.thumbnail(of: $0, maxWidth: previewWidth) }
            return Update(result: result, frames: engine.frameCount, preview: preview)
        default:
            return Update(result: result, frames: engine.frameCount, preview: nil)
        }
    }

    func finish() -> CGImage? {
        guard engine.frameCount > 0 else { return nil }
        return engine.compose()?.cgImage
    }

    private static func thumbnail(of image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth else { return image }
        let scale = CGFloat(maxWidth) / CGFloat(image.width)
        let size = CGSize(width: maxWidth, height: max(1, Int(CGFloat(image.height) * scale)))
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage() ?? image
    }
}
