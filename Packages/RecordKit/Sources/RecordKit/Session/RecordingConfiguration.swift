import AddOnKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Which encoder a recording uses.
public enum VideoCodec: String, Sendable, Codable {
    /// HEVC where the hardware has an encoder, H.264 otherwise. The default: half the
    /// bytes for the same picture, and every Mac that runs macOS 14 can play it.
    case automatic
    case hevc
    case h264

    /// What to actually ask `AVAssetWriter` for.
    public var resolved: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .automatic:
            // The check is for an encoder, not a decoder: an Intel Mac without one
            // would otherwise write a file its own CPU has to software-encode.
            VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? .hevc : .h264
        }
    }
}

/// How good the recording should look, as the one dial a user is offered.
public enum CaptureQuality: String, Sendable, Codable, CaseIterable {
    case good, better, best

    /// Bits per second for a given pixel count, tuned for screen content: large flat
    /// areas, hard edges, occasional full-frame scrolls.
    public func bitrate(forPixels pixels: Int) -> Int {
        let perPixel: Double = switch self {
        case .good: 0.08
        case .better: 0.13
        case .best: 0.2
        }
        let raw = Double(pixels) * perPixel * 60 / 8
        return max(2_000_000, min(Int(raw), 120_000_000))
    }
}

/// Everything one recording needs to know before it starts.
public struct RecordingConfiguration: Sendable {
    public var target: CaptureTarget
    public var frameRate: Int
    /// Off by default. The cursor is recorded as data and drawn at render time — that is
    /// what makes size, smoothing, click bounce and auto-zoom possible afterwards.
    /// Turning it on bakes the system cursor into the pixels instead.
    public var capturesCursorInVideo: Bool
    public var systemAudio: Bool
    /// The microphones' `uniqueID`s, not the devices: a configuration is a value that
    /// crosses threads and outlives the moment, and a device that was unplugged in
    /// between should fail when the recording starts, not silently record nothing.
    ///
    /// A list rather than one, because a recording routinely has more than one voice in
    /// it — a built-in microphone and an interview guest's headset, a podcast pair on two
    /// USB mics — and mixing those together at capture time throws away the edit that
    /// matters most afterwards, which is turning one of them down. Each is written to its
    /// own file and arrives in the editor as its own lane, in this order.
    ///
    /// Empty is "no microphone", which is the state in which no microphone is ever opened.
    public var microphoneIDs: [String]
    /// The camera's `uniqueID`, or `nil` for a take with no camera in it.
    ///
    /// Modelled exactly like `microphoneIDs`, and for the same two reasons: a configuration
    /// is a value that crosses threads and outlives the moment it was made, and a camera
    /// unplugged in between should fail when the recording starts rather than silently
    /// record nothing. There is a third reason here, and it is the important one — **`nil`
    /// is the only state in which no camera session is ever created.** A boolean plus a
    /// separately-stored device would have two ways to spell "no camera", and the one that
    /// got out of step would be an app filming somebody who did not ask.
    public var webcamID: String?
    public var codec: VideoCodec
    public var quality: CaptureQuality
    /// Where the `.klikrec` package is created.
    public var destination: URL
    public var name: String
    /// Sampled cursor positions per second. 120 is two samples per frame at 60 fps,
    /// which is enough for the smoothing filter to have something to smooth.
    public var cursorSampleRate: Int
    public var capturesClicks: Bool
    /// Needs the Accessibility grant, so it is opt-in and off here.
    public var capturesKeystrokes: Bool
    /// Record which window, app and text field had focus.
    ///
    /// On by default, and cheap: the app and window halves need no grant beyond the one
    /// a recording already holds. Only the text-field half needs Accessibility, and it
    /// is left out rather than prompted for when the grant is missing.
    public var capturesFocus: Bool

    public init(target: CaptureTarget,
                destination: URL,
                name: String = "Recording",
                frameRate: Int = 60,
                capturesCursorInVideo: Bool = false,
                systemAudio: Bool = true,
                microphoneIDs: [String] = [],
                webcamID: String? = nil,
                codec: VideoCodec = .automatic,
                quality: CaptureQuality = .better,
                cursorSampleRate: Int = 120,
                capturesClicks: Bool = true,
                capturesKeystrokes: Bool = false,
                capturesFocus: Bool = true) {
        self.target = target
        self.destination = destination
        self.name = name
        self.frameRate = frameRate
        self.capturesCursorInVideo = capturesCursorInVideo
        self.systemAudio = systemAudio
        self.microphoneIDs = microphoneIDs
        self.webcamID = webcamID
        self.codec = codec
        self.quality = quality
        self.cursorSampleRate = cursorSampleRate
        self.capturesClicks = capturesClicks
        self.capturesKeystrokes = capturesKeystrokes
        self.capturesFocus = capturesFocus
    }

    /// The stream configuration for a filter, in pixels.
    ///
    /// `queueDepth` is 8 rather than the default 3: an encoder that stalls for a moment
    /// then drops frames it never saw is worse than one that catches up from a queue.
    public func streamConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = filter.pointPixelScale
        let size = filter.contentRect.size

        var width = Int((size.width * CGFloat(scale)).rounded())
        var height = Int((size.height * CGFloat(scale)).rounded())
        if case .area(_, let rect) = target {
            configuration.sourceRect = rect
            width = Int((rect.width * CGFloat(scale)).rounded())
            height = Int((rect.height * CGFloat(scale)).rounded())
        }
        // Both encoders want even dimensions; an odd one is rejected at write time,
        // which is much later than here.
        configuration.width = max(2, width - width % 2)
        configuration.height = max(2, height - height % 2)

        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        configuration.showsCursor = capturesCursorInVideo
        configuration.capturesAudio = systemAudio
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }
}
