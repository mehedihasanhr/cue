import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Where the real pointer was in one frame of the recording.
struct FrameObservation {
    /// Seconds from the start of the file.
    let time: Double
    /// The top-left of the pointer's dark fill, in recorded points — a pixel or two inside
    /// its hotspot. `nil` when no pointer is in the part of the frame that was searched.
    let tip: CGPoint?
}

/// Finds the system pointer in a recording made over a blank white stage.
///
/// The recording under test is made with the system pointer burnt into the picture, which
/// the product never does — and that is the point of it. It gives every frame a second,
/// independent account of where the pointer was: the one the window server drew. The
/// telemetry is then marked against the picture rather than against itself.
enum FrameScan {
    /// Reads every frame and finds the pointer in it.
    ///
    /// - Parameters:
    ///   - scale: pixels per recorded point.
    ///   - region: the part of the frame that is known to be blank stage, in points.
    static func observations(of url: URL, scale: Double, region: CGRect) async throws -> [FrameObservation] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }

        var found: [FrameObservation] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            found.append(FrameObservation(time: time, tip: tip(in: buffer, scale: scale, region: region)))
        }
        return found.sorted { $0.time < $1.time }
    }

    static func tip(in buffer: CVPixelBuffer, scale: Double, region: CGRect) -> CGPoint? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        let minX = max(0, Int(region.minX * scale)), maxX = min(width - 1, Int(region.maxX * scale))
        let minY = max(0, Int(region.minY * scale)), maxY = min(height - 1, Int(region.maxY * scale))
        guard minX < maxX, minY < maxY else { return nil }

        @inline(__always) func isDark(_ x: Int, _ y: Int) -> Bool {
            let offset = y * rowBytes + x * 4
            return pixels[offset] < 80 && pixels[offset + 1] < 80 && pixels[offset + 2] < 80
        }

        // Coarse first: the pointer's fill is tens of pixels across, so every third pixel
        // cannot step over it.
        var hit: (x: Int, y: Int)?
        var y = minY
        search: while y <= maxY {
            var x = minX
            while x <= maxX {
                if isDark(x, y) { hit = (x, y); break search }
                x += 3
            }
            y += 3
        }
        guard let hit else { return nil }

        // Then exactly, around what was found.
        let reach = Int(60 * scale)
        var left = Int.max, top = Int.max
        for row in max(0, hit.y - reach)...min(height - 1, hit.y + reach) {
            for column in max(0, hit.x - reach)...min(width - 1, hit.x + reach) where isDark(column, row) {
                left = min(left, column)
                top = min(top, row)
            }
        }
        guard left != .max else { return nil }
        return CGPoint(x: Double(left) / scale, y: Double(top) / scale)
    }
}
