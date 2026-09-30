import AVFoundation
import CoreGraphics
import Foundation
import TimelineKit

/// What an export produces.
public enum ExportFormat: String, Sendable, CaseIterable, Codable {
    case mp4
    case mov
    /// Apple ProRes 422 in a MOV: what an editing application wants to be handed.
    case proRes422
    /// Apple ProRes 4444 in a MOV, which keeps an alpha channel — the one to choose when
    /// the background is transparent and the video is going over something else.
    case proRes4444
    case gif

    /// Both ProRes formats are movies like any other MOV: the codec is what differs, and
    /// it is the file's contents rather than its name that says so.
    public var fileExtension: String {
        switch self {
        case .mp4: "mp4"
        case .mov, .proRes422, .proRes4444: "mov"
        case .gif: "gif"
        }
    }

    /// `nil` for GIF, which is written by Image I/O rather than by AVFoundation.
    public var fileType: AVFileType? {
        switch self {
        case .mp4: .mp4
        case .mov, .proRes422, .proRes4444: .mov
        case .gif: nil
        }
    }

    public var title: String {
        switch self {
        case .mp4: "MP4"
        case .mov: "MOV"
        case .proRes422: "ProRes 422"
        case .proRes4444: "ProRes 4444"
        case .gif: "GIF"
        }
    }

    public var detail: String {
        switch self {
        case .mp4: "Plays everywhere. The one to send."
        case .mov: "HEVC or H.264 in a QuickTime movie. Can keep a transparent background."
        case .proRes422: "For editing in Final Cut Pro, Premiere or Resolve. Large files."
        case .proRes4444: "For editing, and keeps a transparent background. The largest files."
        case .gif: "No sound, big files, plays in a chat window."
        }
    }

    public var carriesAudio: Bool { self != .gif }

    /// Whether this is one of the ProRes formats, whose codec is part of the format and
    /// whose quality is the codec's own rather than a bitrate we choose.
    public var isProRes: Bool { self == .proRes422 || self == .proRes4444 }

    /// Whether the codec can be chosen: only for the two ordinary movie formats.
    public var offersCodecChoice: Bool { self == .mp4 || self == .mov }
}

/// Which encoder writes the file.
public enum ExportCodec: String, Sendable, CaseIterable, Codable {
    /// HEVC in a MOV, H.264 in an MP4 — the safe choice for each container, since an
    /// MP4 full of HEVC is exactly the file that will not open on someone's PC.
    case automatic
    case h264
    case hevc
    /// HEVC carrying an alpha channel, so a transparent background stays transparent.
    /// Only a MOV can hold it — AVFoundation refuses it in an MP4 — so in an MP4 it is
    /// written as plain HEVC.
    case hevcWithAlpha

    /// The encoder that actually writes the file.
    ///
    /// A ProRes format decides for itself, whatever codec was last chosen for an MP4:
    /// the choice is only offered where there is one to make.
    public func resolved(for format: ExportFormat) -> AVVideoCodecType {
        switch format {
        case .proRes422: return .proRes422
        case .proRes4444: return .proRes4444
        case .mp4, .mov, .gif: break
        }
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        case .hevcWithAlpha: return format == .mov ? .hevcWithAlpha : .hevc
        case .automatic: return format == .mov ? .hevc : .h264
        }
    }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .hevcWithAlpha: "HEVC with transparency"
        }
    }

    /// The codecs worth offering for a format: all of them for a MOV, and none that could
    /// only be written as something else for an MP4.
    public static func choices(for format: ExportFormat) -> [ExportCodec] {
        format == .mov ? allCases : allCases.filter { $0 != .hevcWithAlpha }
    }
}

/// How good the file should look, as the one dial anybody wants to touch.
public enum ExportQuality: String, Sendable, CaseIterable, Codable {
    /// Size first: HEVC, whatever the container, at about half of Good's bitrate. HEVC
    /// keeps a screen recording's text sharp at a bitrate where H.264 smears it, which is
    /// the whole trick — the same picture in roughly half the bytes.
    case smaller
    case good, better, best

    /// Bits per second for a pixel count and a frame rate.
    ///
    /// The figures below are bits for each pixel of each frame, so the bitrate is simply
    /// pixels × frames × bits — already bits, and not to be divided by eight. (It once
    /// was, which put Good, Better and Best at an eighth of what was meant: nearly every
    /// 1080p export landed on the 1 Mb/s floor, and the three qualities came out alike.)
    ///
    /// Scaled by frame rate rather than fixed, because the same picture at 60 fps needs
    /// roughly twice what it needs at 30. At 1080p60 the four come to about 2.7 Mb/s
    /// (Smaller File, HEVC), 6.2 (Good), 11 (Better) and 19 (Best): screen recordings are
    /// mostly still, flat and sharp-edged, so this is well under what camera footage of
    /// the same size would want, and still enough that text survives a scroll.
    public func bitrate(forPixels pixels: Int, frameRate: Int) -> Int {
        let perPixel: Double = switch self {
        case .smaller: 0.022
        case .good: 0.05
        case .better: 0.09
        case .best: 0.15
        }
        let raw = Double(pixels) * perPixel * Double(max(1, frameRate))
        return max(self == .smaller ? ExportSettings.minimumBitrate : 1_000_000, min(Int(raw), 120_000_000))
    }

    public var title: String {
        switch self {
        case .smaller: "Smaller File"
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
    /// The most the file may weigh, in bytes, or `nil` for no limit. A movie is held to it
    /// by its bitrate; a GIF can only be aimed at it, by its size. See `ExportTarget`.
    public var targetByteCount: Int?

    public init(format: ExportFormat = .mp4,
                frameRate: Int = 60,
                quality: ExportQuality = .better,
                codec: ExportCodec = .automatic,
                maximumDimension: Double? = nil,
                includesAudio: Bool = true,
                loops: Bool = true,
                targetByteCount: Int? = nil) {
        self.format = format
        self.frameRate = frameRate
        self.quality = quality
        self.codec = codec
        self.maximumDimension = maximumDimension
        self.includesAudio = includesAudio
        self.loops = loops
        self.targetByteCount = targetByteCount
    }

    /// A GIF at 60 fps is a file nobody can send. Capped here rather than in the UI, so
    /// the number the exporter uses and the number the UI shows cannot disagree.
    public static let maximumGIFFrameRate = 30

    public var effectiveFrameRate: Int {
        format == .gif ? min(frameRate, Self.maximumGIFFrameRate) : max(1, frameRate)
    }

    public var writesAudio: Bool { includesAudio && format.carriesAudio }

    /// Whether the file keeps an alpha channel, so a transparent background is still
    /// transparent in it. Every other format has nowhere to put one, and the encoder
    /// writes black where the frame was see-through.
    public var keepsTransparency: Bool {
        guard format != .gif else { return false }
        let codec = videoCodec
        return codec == .proRes4444 || codec == .hevcWithAlpha
    }

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
