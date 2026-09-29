import AVFoundation
import CoreGraphics
import Foundation

/// Exports made to a size: the Smaller File quality, and a limit on how big the file may be.
///
/// Both come down to the bitrate the encoder is handed, and both are worked out here, where
/// the estimate and the exporter can ask the same questions — a sheet that promised 9.8 MB
/// and an encoder aiming at 12 would be two answers to one question.
public extension ExportSettings {
    /// The least a movie is ever given, in bits a second. Below this a screen recording's
    /// text dissolves into blocks, and a file that small is not worth sending.
    static let minimumBitrate = 250_000
    /// How far over the average one second of a size-limited movie may run. See
    /// `VideoExporter.videoOutputSettings`.
    static let peakAllowance = 1.5
    /// The sound beside a movie for watching, in bits a second: what `VideoExporter` asks
    /// the AAC encoder for.
    static let audioBitrate = 192_000
    /// The share of a size limit the picture and sound are aimed at. The encoder's average
    /// is an average, and the container's indexes are extra; aiming a few per cent under is
    /// what makes "under 10 MB" true of the file rather than of the arithmetic.
    static let targetHeadroom = 0.93

    /// The size limits offered by name, in bytes as the Finder counts them (a million to
    /// the megabyte). Eight and ten are where chat apps draw their lines.
    static let targetChoices: [(title: String, value: Int?)] = [
        ("No limit", nil),
        ("8 MB", 8_000_000),
        ("10 MB", 10_000_000),
        ("25 MB", 25_000_000),
        ("50 MB", 50_000_000),
        ("100 MB", 100_000_000),
    ]

    /// Whether a size limit means anything for this format. ProRes is written at a quality
    /// of its own and cannot be told a size.
    var offersTargetSize: Bool { !format.isProRes }

    /// The encoder that writes the file.
    ///
    /// Smaller File with the codec left on Automatic is HEVC in either container: that is
    /// where the smaller file comes from. An MP4 of HEVC plays on every Apple device, on
    /// phones, and in current browsers; the PC that cannot play it is the reason Automatic
    /// is H.264 in an MP4 at the other qualities. A codec chosen by hand is kept.
    var videoCodec: AVVideoCodecType {
        if quality == .smaller, codec == .automatic, format == .mp4 || format == .mov { return .hevc }
        return codec.resolved(for: format)
    }

    /// The bitrate a movie's picture is written at: the quality's own, or less when a size
    /// limit needs it to be. Never more — a limit is a most, and a short clip under it is
    /// not made bigger to reach it.
    ///
    /// - Parameter duration: seconds of finished video.
    func videoBitrate(forPixels pixels: Int, frameRate: Int, duration: Double) -> Int {
        let chosen = quality.bitrate(forPixels: pixels, frameRate: frameRate)
        guard let target = targetByteCount, offersTargetSize, duration > 0 else { return chosen }
        let sound = writesAudio ? Double(Self.audioBitrate) / 8 * duration : 0
        // The estimate adds 2% for the container; so does this, from the other side.
        let picture = Double(target) * Self.targetHeadroom / 1.02 - sound
        let fitting = picture > 0 ? Int(picture * 8 / duration) : 0
        return max(Self.minimumBitrate, min(chosen, fitting))
    }

    /// These settings with a GIF's size limit turned into a size and a frame rate.
    ///
    /// A GIF has no bitrate: the only way to fewer bytes is fewer pixels or fewer frames.
    /// Smaller frames go first, down to 320 across, because a GIF is usually looked at
    /// small; then fewer of them, down to 10 a second, below which movement stutters; then
    /// smaller again. Aimed by the estimate, which for a GIF is a guess — so a GIF is aimed
    /// at its limit, not held to it, and the sheet says so. Anything but a GIF, or a GIF
    /// with no limit, comes back as it was.
    func aimedAtTarget(projectSize: CGSize, duration: Double) -> ExportSettings {
        guard format == .gif, let target = targetByteCount else { return self }
        var aimed = self
        aimed.targetByteCount = nil
        func fits() -> Bool { aimed.estimate(projectSize: projectSize, duration: duration).byteCount <= target }
        guard !fits() else { return aimed }

        let drawn = aimed.estimate(projectSize: projectSize, duration: duration).size
        var across = max(drawn.width, drawn.height)
        while across > 320 {
            across = max(320, (across * 0.9).rounded())
            aimed.maximumDimension = across
            if fits() { return aimed }
        }
        for rate in [12, 10] where rate < aimed.effectiveFrameRate {
            aimed.frameRate = rate
            if fits() { return aimed }
        }
        while across > 160 {
            across = max(160, (across * 0.9).rounded())
            aimed.maximumDimension = across
            if fits() { return aimed }
        }
        return aimed
    }
}
