import CoreImage
import CoreVideo
import Foundation
import Vision

/// Finds the person in a camera frame.
///
/// A protocol so the renderer can be handed a stand-in: what the renderer *does* with a
/// mask — blur behind it, cut along it — is arithmetic worth testing on a mask whose shape
/// is known, which no real segmentation of a synthetic picture can promise.
public protocol PersonMatting: AnyObject, Sendable {
    /// A greyscale mask covering exactly `frame.extent`: white where the person is, black
    /// where they are not, soft in between. `nil` when there is nothing to go on.
    func matte(for frame: CIImage) -> CIImage?
}

/// Vision's person segmentation, one camera frame at a time, remembered per frame.
///
/// **One frame at a time.** Vision's own advice for video is a sequence handler, which
/// steadies the mask from one frame to the next by remembering the frames before. That
/// memory is exactly what this renderer cannot have: the mask for a frame would depend on
/// which frames happened to be looked at first, so a frame scrubbed to would be cut out
/// differently from the same frame played to, and the export — which reads every frame in
/// order — differently from the preview. Each frame is segmented on its own, with a fresh
/// request, at one fixed quality and revision, so the same picture always gets the same
/// mask.
///
/// **Remembered per frame.** Segmenting is the one expensive thing about a camera frame,
/// and the same frame is asked about again and again: an export at 60 frames a second over
/// a camera filmed at 30 draws every camera frame twice, and a preview that is scrubbed
/// back and forth draws the same few over and over. The frame sources hand back the *same*
/// image object for as long as a frame stands — the export's reader holds its current frame
/// until the next one begins, and the preview's cache keeps each decoded frame — so the
/// mask is filed under that object. Weakly: the entry does not keep a camera frame alive
/// (in an export that would be holding the decoder's own buffers), and one whose frame has
/// gone is never mistaken for a new frame that happens to reuse its address.
///
/// **Balanced quality**, for preview and export alike — the two must cut the person out the
/// same way, and the accurate model is several times slower for an edge nobody sees at the
/// size of a bubble.
public final class PersonMatte: PersonMatting, @unchecked Sendable {
    private final class Entry {
        weak var frame: CIImage?
        let mask: CIImage?

        init(frame: CIImage, mask: CIImage?) {
            self.frame = frame
            self.mask = mask
        }
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var order: [ObjectIdentifier] = []
    private let capacity: Int
    private let segmenter: @Sendable (CIImage) -> CIImage?

    private var made = 0

    /// How many times a frame had to be segmented rather than remembered. For tests.
    public var segmentations: Int {
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    /// - Parameter segmenter: what produces a mask for a frame not seen before. Vision's
    ///   person segmentation unless a test says otherwise.
    public init(capacity: Int = 8,
                segmenter: @escaping @Sendable (CIImage) -> CIImage? = PersonMatte.segment) {
        self.capacity = max(1, capacity)
        self.segmenter = segmenter
    }

    public func matte(for frame: CIImage) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(frame)
        if let entry = entries[key], entry.frame === frame { return entry.mask }

        made += 1
        let mask = segmenter(frame)
        order.removeAll { $0 == key }
        order.append(key)
        entries[key] = Entry(frame: frame, mask: mask)
        // Any whose frame has gone are no use to anybody, and then the oldest go first.
        for stale in order where entries[stale]?.frame == nil {
            entries.removeValue(forKey: stale)
        }
        order.removeAll { entries[$0] == nil }
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
        return mask
    }

    /// What Vision draws a Core Image frame with before it can look at it. One for every
    /// frame rather than one per request: making a context is far dearer than using one,
    /// and a context is safe to share between threads.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Vision's mask for one frame, stretched over the frame's own extent.
    ///
    /// Scaled up smoothly and softened by a pixel or two: the mask comes back far smaller
    /// than the camera's picture, and stretched as it is its steps would show as a jagged
    /// line round the head.
    public static func segment(_ frame: CIImage) -> CIImage? {
        let extent = frame.extent
        guard extent.width >= 2, extent.height >= 2, extent.width.isFinite, extent.height.isFinite else {
            return nil
        }
        // Vision reads the picture from its own origin.
        let placed = frame.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))

        let request = VNGeneratePersonSegmentationRequest()
        request.revision = VNGeneratePersonSegmentationRequestRevision1
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: placed, options: [.ciContext: context])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }

        let mask = CIImage(cvPixelBuffer: buffer)
        guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
        let softness = max(0.5, min(extent.width, extent.height) / 500)
        return mask
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                               y: extent.height / mask.extent.height))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: softness)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}
