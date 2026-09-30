import CoreMedia
import Foundation
import os
import ScreenCaptureKit

/// How big a window's picture really is, measured from a frame of it.
///
/// The window that was picked is not always all that gets captured. A full-screen Chrome is
/// the page plus its tab strip and toolbar, each a window of its own stacked above it, and
/// capturing the page captures all three — 88 points taller than the page reports. A file
/// sized from what the window reports then gets a picture of another shape, scaled down to
/// fit its height, and a black band down the right for the whole take.
///
/// Neither the window nor the filter knows better; only a frame does. So a few frames are
/// captured before the countdown and the first complete one is asked: its content rect is
/// where the picture landed in the frame, and its content scale how far it was shrunk to
/// get there — the one divided by the other is the picture's own size.
enum WindowPicture {
    /// The picture's size in points, or `nil` if no frame arrived in time. A `nil` leaves
    /// the file sized as the window reports, which is right for every window but a few.
    @MainActor
    static func size(of filter: SCContentFilter,
                     configuration: SCStreamConfiguration,
                     timeout: Duration = .milliseconds(800)) async -> CGSize? {
        let probe = Probe()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addStreamOutput(probe, type: .screen, sampleHandlerQueue: probe.queue)
            try await stream.startCapture()
        } catch {
            log.error("Couldn't measure the window: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let size = await probe.firstSize(timeout: timeout)
        try? await stream.stopCapture()
        return size
    }

    /// The size a frame's picture had before it was scaled into the frame.
    static func size(of geometry: FrameGeometry) -> CGSize? {
        guard geometry.contentScale > 0.01,
              geometry.contentRect.width > 1, geometry.contentRect.height > 1 else { return nil }
        return CGSize(width: geometry.contentRect.width / geometry.contentScale,
                      height: geometry.contentRect.height / geometry.contentScale)
    }

    private static let log = Logger(subsystem: "com.stackrover.klik.recordkit", category: "screen")

    private final class Probe: NSObject, SCStreamOutput, @unchecked Sendable {
        let queue = DispatchQueue(label: "com.stackrover.klik.window-picture")
        private let found = OSAllocatedUnfairLock<CheckedContinuation<CGSize?, Never>?>(initialState: nil)
        private let result = OSAllocatedUnfairLock<CGSize??>(initialState: nil)

        func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, buffer.screenFrameStatus == .complete,
                  let geometry = buffer.frameGeometry else { return }
            finish(WindowPicture.size(of: geometry))
        }

        /// Once: the first frame, or the timeout, whichever comes first.
        private func finish(_ size: CGSize?) {
            let isFirst = result.withLock { stored in
                guard stored == nil else { return false }
                stored = .some(size)
                return true
            }
            guard isFirst else { return }
            found.withLock { $0 }?.resume(returning: size)
        }

        func firstSize(timeout: Duration) async -> CGSize? {
            await withCheckedContinuation { continuation in
                let already = result.withLock { stored -> CGSize?? in
                    if stored == nil { found.withLock { $0 = continuation } }
                    return stored
                }
                if let already { continuation.resume(returning: already); return }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.finish(nil)
                }
            }
        }
    }
}
