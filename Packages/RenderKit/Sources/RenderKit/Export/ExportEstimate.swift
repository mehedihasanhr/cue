import CoreGraphics
import Foundation

/// What an export will be, worked out before any of it is written.
///
/// Every number here is already decided by the settings and the length of the edit, so
/// there is no reason to make somebody start a five-minute encode to find out that they
/// asked for a 400 MB file. The dimensions and the frame rate are exact; the byte count
/// is not, and says so.
public struct ExportEstimate: Sendable, Equatable {
    public var size: CGSize
    public var frameRate: Int
    /// Seconds of finished video.
    public var duration: Double
    /// Roughly how big the file will be, in bytes.
    public var byteCount: Int
    /// Whether that figure is a guess worth qualifying out loud.
    ///
    /// A movie's size follows from a bitrate we hand the encoder, so it is close. A GIF's
    /// follows from how well a palette and LZW happen to compress this particular
    /// picture, which can be out by a factor of two either way.
    public var isApproximate: Bool

    public init(size: CGSize, frameRate: Int, duration: Double, byteCount: Int, isApproximate: Bool) {
        self.size = size
        self.frameRate = frameRate
        self.duration = duration
        self.byteCount = byteCount
        self.isApproximate = isApproximate
    }

    /// The number of frames the exporter will walk — the same arithmetic the exporters
    /// do, kept here so a progress bar and an estimate cannot disagree about the total.
    public var frameCount: Int {
        max(1, Int((duration * Double(frameRate)).rounded()))
    }

    /// "18 MB", in whatever units the Mac is set to show.
    public var formattedByteCount: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = byteCount < 10_000_000 ? [.useKB, .useMB] : [.useMB, .useGB]
        return formatter.string(fromByteCount: Int64(byteCount))
    }
}

public extension ExportSettings {
    /// What these settings would produce from a project of this size and length.
    ///
    /// `projectSize` is the renderer's own output size — `SceneBuilder.outputSize(for:)`,
    /// which is what the preview is drawn at — so the dimensions here are the dimensions
    /// the file gets, not an approximation of them.
    func estimate(projectSize: CGSize, duration: Double) -> ExportEstimate {
        let output = outputSize(fitting: projectSize)
        let rate = effectiveFrameRate
        let seconds = max(0, duration)
        let pixels = Int(output.width * output.height)

        let bytes: Int
        let approximate: Bool
        switch format {
        case .gif:
            // An 8-bit palette is one byte a pixel before compression; LZW over screen
            // recordings — large flat areas, a pointer moving across them — lands near a
            // quarter of that. Deliberately not generous: an estimate that comes in under
            // the real file is the one that surprises people.
            bytes = Int(Double(pixels) * 0.28 * Double(max(1, Int((seconds * Double(rate)).rounded()))))
            approximate = true
        case .mp4, .mov:
            let video = Double(quality.bitrate(forPixels: pixels, frameRate: rate)) / 8 * seconds
            // The same 192 kbps AAC `VideoExporter` asks for, and nothing if there will be
            // no sound track at all.
            let audio = writesAudio ? 192_000.0 / 8 * seconds : 0
            // A couple of per cent for the container's own indexes and headers.
            bytes = Int((video + audio) * 1.02)
            approximate = false
        }

        return ExportEstimate(size: output,
                              frameRate: rate,
                              duration: seconds,
                              byteCount: max(1, bytes),
                              isApproximate: approximate)
    }
}
