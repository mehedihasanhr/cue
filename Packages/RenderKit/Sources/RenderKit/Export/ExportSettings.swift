import AVFoundation
import CoreGraphics
import Foundation
import TimelineKit

/// What an export produces.
public enum ExportFormat: String, Sendable, CaseIterable, Codable {
    case mp4
    case mov
    case gif

    public var fileExtension: String { rawValue }

    /// `nil` for GIF, which is written by Image I/O rather than by AVFoundation.
    public var fileType: AVFileType? {
        switch self {
        case .mp4: .mp4
        case .mov: .mov
        case .gif: nil
        }
    }

    public var title: String {
        switch self {
        case .mp4: "MP4"
        case .mov: "MOV"
        case .gif: "GIF"
        }
    }

    public var detail: String {
        switch self {
        case .mp4: "Plays everywhere. The one to send."
        case .mov: "ProRes-friendly container for editing on."
        case .gif: "No sound, big files, plays in a chat window."
        }
    }

    public var carriesAudio: Bool { self != .gif }
}

/// Which encoder writes the file.
public enum ExportCodec: String, Sendable, CaseIterable, Codable {
    /// HEVC in a MOV, H.264 in an MP4 — the safe choice for each container, since an
    /// MP4 full of HEVC is exactly the file that will not open on someone's PC.
    case automatic
    case h264
    case hevc

    public func resolved(for format: ExportFormat) -> AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .automatic: format == .mov ? .hevc : .h264
        }
    }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}

/// How good the file should look, as the one dial anybody wants to touch.
public enum ExportQuality: String, Sendable, CaseIterable, Codable {
    case good, better, best

    /// Bits per second for a pixel count and a frame rate.
    ///
    /// Scaled by frame rate rather than fixed, because the same picture at 60 fps needs
    /// roughly twice what it needs at 30 — the per-pixel figures below are per frame at
    /// 60, which is what these recordings usually are.
    public func bitrate(forPixels pixels: Int, frameRate: Int) -> Int {
        let perPixel: Double = switch self {
        case .good: 0.05
        case .better: 0.09
        case .best: 0.15
        }
        let raw = Double(pixels) * perPixel * Double(max(1, frameRate)) / 8
        return max(1_000_000, min(Int(raw), 120_000_000))
    }

    public var title: String {
        switch self {
        case .good: "Good"
        case .better: "Better"
        case .best: "Best"
        }
    }
}

/// Everything one export needs to know.
public struct ExportSettings: Sendable, Equatable {
    public var format: ExportFormat
    public var frameRate: Int
    public var quality: ExportQuality
    public var codec: ExportCodec
    /// A cap on the longer side, or `nil` for the project's own size.
    ///
    /// A cap rather than a width or a height: the same "1080p" means a different pair of
    /// numbers for a 16:9 export and a 9:16 one, and asking the user which they meant is
    /// asking them to do arithmetic.
    public var maximumDimension: Double?
    public var includesAudio: Bool
    /// GIFs loop forever unless told otherwise, which is what everyone expects of them.
    public var loops: Bool

    public init(format: ExportFormat = .mp4,
                frameRate: Int = 60,
                quality: ExportQuality = .better,
                codec: ExportCodec = .automatic,
                maximumDimension: Double? = nil,
                includesAudio: Bool = true,
                loops: Bool = true) {
        self.format = format
        self.frameRate = frameRate
        self.quality = quality
        self.codec = codec
        self.maximumDimension = maximumDimension
        self.includesAudio = includesAudio
        self.loops = loops
    }

    /// A GIF at 60 fps is a file nobody can send. Capped here rather than in the UI, so
    /// the number the exporter uses and the number the UI shows cannot disagree.
    public static let maximumGIFFrameRate = 30

    public var effectiveFrameRate: Int {
        format == .gif ? min(frameRate, Self.maximumGIFFrameRate) : max(1, frameRate)
    }

    public var writesAudio: Bool { includesAudio && format.carriesAudio }

    /// The finished frame's size: the project's own, brought down under the cap.
    ///
    /// Never up. Asking for 4K from a 1080p recording produces a 4K file of exactly the
    /// same picture, four times the size and not one pixel sharper.
    public func outputSize(fitting size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        var width = size.width
        var height = size.height

        if let cap = maximumDimension, cap > 0 {
            let longer = max(width, height)
            if longer > cap {
                let scale = cap / longer
                width *= scale
                height *= scale
            }
        }
        // Every encoder here wants even dimensions; an odd one is refused at write time,
        // which is much later than here.
        return CGSize(width: max(2, (width / 2).rounded() * 2),
                      height: max(2, (height / 2).rounded() * 2))
    }

    /// How much the renderer's output has to be scaled to land at the export size.
    public func scale(from projectSize: CGSize, to exportSize: CGSize) -> Double {
        guard projectSize.width > 0 else { return 1 }
        return exportSize.width / projectSize.width
    }

    /// The common sizes offered by name.
    public static let dimensionChoices: [(title: String, value: Double?)] = [
        ("Project size", nil),
        ("4K — 3840", 3_840),
        ("1440p — 2560", 2_560),
        ("1080p — 1920", 1_920),
        ("720p — 1280", 1_280),
    ]
}
