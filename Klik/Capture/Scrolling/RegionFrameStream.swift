import os
import ScreenCaptureKit

/// A continuous ScreenCaptureKit stream of one screen region. Frames are delivered
/// on a private queue as `Bitmap`s. While the stitcher is busy with one frame only the
/// newest arrival is kept, so it always sees the current screen rather than a backlog.
nonisolated final class RegionFrameStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private let stream: SCStream
    private let queue = DispatchQueue(label: "com.stackrover.klik.scrolling-frames", qos: .userInteractive)
    private let handler: @Sendable (Bitmap) async -> Void
    private struct Inbox {
        var running = false
        var pending: Bitmap?
    }
    private let inbox = OSAllocatedUnfairLock(initialState: Inbox())

    /// 30 fps is plenty for hand scrolling (ScreenCaptureKit only sends a frame when
    /// something changed) and halves the matcher's work per second.
    init(filter: SCContentFilter, configuration: SCStreamConfiguration, framesPerSecond: Int = 30,
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

        guard let bitmap = Bitmap(pixelBuffer: pixelBuffer) else { return }
        // Hand it over, or park it as the newest pending frame while a previous one is
        // still being stitched (replacing any older pending frame).
        let start = inbox.withLock { inbox -> Bool in
            if inbox.running {
                inbox.pending = bitmap
                return false
            }
            inbox.running = true
            return true
        }
        guard start else { return }
        Task { [handler, inbox] in
            var next: Bitmap? = bitmap
            while let frame = next {
                await handler(frame)
                next = inbox.withLock { inbox in
                    defer { inbox.pending = nil }
                    if inbox.pending == nil { inbox.running = false }
                    return inbox.pending
                }
            }
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

    private let engine = ScrollingCaptureEngine()
    private let preview: StitchPreview

    init(previewWidth: Int) {
        preview = StitchPreview(width: previewWidth)
    }

    func ingest(_ frame: Bitmap) -> Update {
        let result = engine.ingest(frame)
        switch result {
        case .first, .appended, .prepended:
            let image = preview.update(pieces: engine.pieces, totalRows: engine.totalRows, dirtyFrom: engine.dirtyFrom)
            return Update(result: result, frames: engine.frameCount, preview: image)
        default:
            return Update(result: result, frames: engine.frameCount, preview: nil)
        }
    }

    func finish() -> CGImage? {
        guard engine.frameCount > 0 else { return nil }
        return engine.compose()?.cgImage
    }
}

/// A reduced copy of the stitched result, kept up to date by drawing only the rows that
/// changed. Composing and shrinking the whole result on every frame would take longer
/// and longer as the capture grows, until the stitcher could no longer keep up.
nonisolated final class StitchPreview {
    let width: Int
    private var scale: CGFloat = 0
    private var context: CGContext?
    private var capacity = 0
    private var drawnRows = 0

    init(width: Int) {
        self.width = width
    }

    func update(pieces: [StitchPiece], totalRows: Int, dirtyFrom: Int) -> CGImage? {
        guard let first = pieces.first, totalRows > 0 else { return nil }
        if scale == 0 { scale = min(1, CGFloat(width) / CGFloat(first.frame.width)) }
        let previewWidth = Int((CGFloat(first.frame.width) * scale).rounded())
        let previewRows = Int((CGFloat(totalRows) * scale).rounded(.up))
        guard ensureCapacity(previewRows, width: previewWidth), let context else { return nil }

        let from = min(dirtyFrom, drawnRows)
        var row = 0
        for piece in pieces {
            let end = row + piece.rows
            defer { row = end }
            guard end > from, piece.rows > 0, let image = piece.frame.cgImage else { continue }
            let skip = max(from - row, 0)
            let crop = CGRect(x: 0, y: piece.from + skip, width: piece.frame.width, height: piece.rows - skip)
            guard let part = image.cropping(to: crop) else { continue }
            let top = CGFloat(row + skip) * scale
            let height = CGFloat(crop.height) * scale
            // The context is y-up; preview row r sits at y = capacity − r.
            context.draw(part, in: CGRect(x: 0, y: CGFloat(capacity) - top - height, width: CGFloat(previewWidth), height: height))
        }
        drawnRows = totalRows
        return context.makeImage()?.cropping(to: CGRect(x: 0, y: 0, width: previewWidth, height: previewRows))
    }

    /// Grows the backing bitmap (doubling) and carries the drawn rows over.
    private func ensureCapacity(_ rows: Int, width: Int) -> Bool {
        guard rows > capacity else { return true }
        let newCapacity = max(rows, capacity * 2, 512)
        guard let fresh = CGContext(data: nil, width: width, height: newCapacity, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return false }
        fresh.interpolationQuality = .medium
        if let context, let old = context.makeImage() {
            fresh.draw(old, in: CGRect(x: 0, y: CGFloat(newCapacity - capacity), width: CGFloat(width), height: CGFloat(capacity)))
        }
        context = fresh
        capacity = newCapacity
        return true
    }
}
