import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// How a connected device's picture is put into a file whose size cannot change.
///
/// A device can be turned over in the middle of a take, and when it is, the picture it
/// sends turns with it: an iPhone held upright sends 1179 × 2556, the same phone on its
/// side sends 2556 × 1179. An `AVAssetWriter` settles its dimensions before the first
/// frame and cannot change them afterwards, so something has to give. There were four
/// candidates, and the reasons three of them lost are worth keeping:
///
/// - **Rotate a turned picture back** to the take's first orientation. The file stays
///   full, but the device's content is on its side for as long as it is turned — a
///   landscape game recorded as a sideways one. Only an editor that knew when to turn it
///   back could fix that, and a file that is wrong without its editor is a wrong file.
/// - **A square file**, as big as the longer side, with every frame fitted inside. It
///   never has to choose, and every frame of every take — including the great majority
///   that are never turned — carries black down two sides of a phone-shaped picture.
/// - **Crop a turned picture to fill** the file, the way a resized window's picture is
///   cropped (`PictureTrack.filling`). A window resized a little loses a few percent at
///   its edges; a phone turned on its side would lose two thirds of its screen.
/// - **Fit a turned picture whole inside the file**, which is what this does. The file is
///   sized to the orientation the device was in when the take began — the one the person
///   set up the shot in — so the common take fills it exactly, with nothing scaled and
///   nothing lost. A stretch spent turned is shown whole, smaller, with black round it,
///   and turning back fills the frame again. Nothing is on its side, nothing is cropped,
///   nothing is stretched.
///
/// The arithmetic is here on its own so it can be checked without a phone.
public enum DeviceFrameFit {
    /// What to do with one frame.
    public enum Plan: Equatable, Sendable {
        /// The frame is the file's size already. The ordinary case: appended as it came.
        case passThrough
        /// Within a pixel or two of the file's size, the same way up — a device whose
        /// screen is an odd number of pixels across, in a file the encoder needs even.
        /// Scaled to the file: a pixel over twelve hundred is not a distortion anyone can
        /// see, and it is better than a one-pixel black line down the phone's edge.
        case stretch
        /// Another shape — the device was turned. Fitted whole inside the file, centred,
        /// with black round it; the rectangle is where the picture lands, in pixels.
        case fit(CGRect)
    }

    /// The file's size for a device whose picture is `picture` pixels when the take
    /// begins: the same, taken down to even numbers, which both encoders insist on.
    public static func canvas(for picture: CGSize) -> CGSize {
        let width = max(2, Int(picture.width.rounded(.down)))
        let height = max(2, Int(picture.height.rounded(.down)))
        return CGSize(width: width - width % 2, height: height - height % 2)
    }

    /// Whether two pictures are held different ways up: one taller than it is wide and the
    /// other not. A square picture counts as upright, the way a device is usually shown.
    public static func isTurned(_ source: CGSize, from canvas: CGSize) -> Bool {
        (source.width > source.height) != (canvas.width > canvas.height)
    }

    /// How much a picture may differ from the file and still be the same picture.
    static let slack: CGFloat = 2

    public static func plan(source: CGSize, canvas: CGSize) -> Plan {
        if source == canvas { return .passThrough }
        if !isTurned(source, from: canvas),
           abs(source.width - canvas.width) <= slack, abs(source.height - canvas.height) <= slack {
            return .stretch
        }
        return .fit(fitted(source, in: canvas))
    }

    /// Where a picture of `source` lands when fitted whole inside `canvas`, centred, in
    /// whole pixels: scaled evenly, so nothing is stretched, as large as the file allows.
    public static func fitted(_ source: CGSize, in canvas: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, canvas.width > 0, canvas.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }
        let scale = min(canvas.width / source.width, canvas.height / source.height)
        let width = (source.width * scale).rounded()
        let height = (source.height * scale).rounded()
        return CGRect(x: ((canvas.width - width) / 2).rounded(.down),
                      y: ((canvas.height - height) / 2).rounded(.down),
                      width: width, height: height)
    }
}

/// Carries out a `DeviceFrameFit.Plan` on real frames.
///
/// Confined to the capture queue, like everything a frame touches on its way to the
/// encoder. VideoToolbox's pixel transfer does the scaling on the GPU, which is the same
/// machinery the encoder uses, into buffers from a pool of the file's own size.
final class DeviceFrameFitter {
    let canvas: CGSize
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    init(canvas: CGSize) {
        self.canvas = canvas
    }

    deinit {
        if let session { VTPixelTransferSessionInvalidate(session) }
    }

    /// The frame, ready for a file of `canvas` — the same buffer when it already fits, a
    /// new one otherwise. `nil` when a frame cannot be made to fit, which drops that frame
    /// and leaves the writer's pacer to repeat the one before.
    func fit(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let source = buffer.imageBuffer else { return nil }
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        let mode: CFString
        switch DeviceFrameFit.plan(source: size, canvas: canvas) {
        case .passThrough: return buffer
        case .stretch: mode = kVTScalingMode_Normal
        case .fit: mode = kVTScalingMode_Letterbox
        }
        guard let session = transferSession(), let target = newBuffer() else { return nil }
        if mode == kVTScalingMode_Letterbox { Self.clear(target) }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: mode)
        guard VTPixelTransferSessionTransferImage(session, from: source, to: target) == noErr,
              let format = try? CMVideoFormatDescription(imageBuffer: target) else { return nil }
        let timing = CMSampleTimingInfo(duration: buffer.duration,
                                        presentationTimeStamp: buffer.presentationTimeStamp,
                                        decodeTimeStamp: .invalid)
        return try? CMSampleBuffer(imageBuffer: target, formatDescription: format, sampleTiming: timing)
    }

    private func transferSession() -> VTPixelTransferSession? {
        if let session { return session }
        var made: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &made) == noErr else { return nil }
        session = made
        return made
    }

    private func newBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(canvas.width),
                kCVPixelBufferHeightKey as String: Int(canvas.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made)
            pool = made
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    /// Black, opaque, before a fitted picture is drawn into it. A buffer from the pool
    /// still holds whatever frame it carried last, and the bands round a fitted picture
    /// must not show a ghost of the previous orientation.
    private static func clear(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        // BGRA: zero colour, full alpha.
        for row in 0..<height {
            let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt32.self)
            line.update(repeating: UInt32(0xFF00_0000).littleEndian, count: width)
        }
    }
}
