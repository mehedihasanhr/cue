import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import TimelineKit
import UniformTypeIdentifiers

/// One frame of the finished video, as a picture.
///
/// What "Copy Frame" and "Save Frame As…" hand over: the frame at the playhead exactly as
/// the export would write it, at the export's size. Same builder, same renderer, same
/// scale step as `VideoExporter.append` — there is one renderer, and a still is one
/// frame of the film rather than a screenshot of the preview. Two halves, so the drawing
/// can be tested without a file or a pasteboard: `image(for:)` turns a described frame
/// into pixels, and `render(_:at:)` does the errand around it — reading the frame out of
/// the recording and describing it.
public enum FrameStill {
    /// A described frame, drawn at the size these export settings would write it.
    ///
    /// The scale is applied to the rendered image rather than by describing a smaller
    /// frame, for the reason the exporter gives: the descriptor's geometry is in project
    /// pixels, and a second layout at export size could disagree with the preview's.
    public static func image(for scene: SceneDescriptor,
                             source: CIImage?,
                             webcam: CIImage? = nil,
                             blending: CIImage? = nil,
                             blendingWebcam: CIImage? = nil,
                             fitting settings: ExportSettings = ExportSettings(),
                             renderer: SceneRenderer = SceneRenderer()) -> CGImage? {
        let outputSize = settings.outputSize(fitting: scene.outputSize)
        let scale = settings.scale(from: scene.outputSize, to: outputSize)
        var image = renderer.image(for: scene, source: source, webcam: webcam,
                                   blending: blending, blendingWebcam: blendingWebcam)
        if scale != 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return renderer.context.createCGImage(image,
                                              from: CGRect(origin: .zero, size: outputSize),
                                              format: .RGBA8,
                                              colorSpace: renderer.colorSpace)
    }

    /// The frame of an edit at a moment, read from the recording and drawn.
    ///
    /// The frame is fetched exactly — no tolerance, full size — which is the export's
    /// reading of the recording and not the preview's while it moves. The builder is
    /// measured against the file's real size first, as the exporter measures it, so the
    /// picture lands where the film has it and not a pixel off.
    public static func render(_ timeline: Timeline,
                              at time: CMTime,
                              builder: SceneBuilder,
                              cursor: CursorTrack?,
                              videoURL: URL,
                              webcamURL: URL? = nil,
                              packageURL: URL? = nil,
                              fitting settings: ExportSettings = ExportSettings()) async throws(ExportError) -> CGImage {
        /// The file a frame's picture comes from: the recording, or a movie brought in.
        func file(_ scene: SceneDescriptor) throws(ExportError) -> URL {
            guard let path = scene.sourceMedia else { return videoURL }
            guard let packageURL else { throw ExportError.unreadableSource("A movie this edit plays could not be found.") }
            return packageURL.appendingPathComponent(path)
        }
        // The recording's size measures the builder, whatever this frame shows: the
        // project's frame is the recording's shape, and an imported picture is fitted into it.
        let recorded = try await frame(of: videoURL, at: timeline.sourceTime(at: time) ?? .zero)
        let builder = recorded.size == .zero ? builder : builder.resized(to: recorded.size)
        let scene = builder.descriptor(for: timeline, at: time, cursor: cursor?.smoothed(timeline.cursor.smoothing))
        let source = scene.sourceMedia == nil
            ? recorded.image
            : try await frame(of: try file(scene), at: scene.sourceTime).image
        // The camera's frame only when the frame being drawn has a bubble in it, and a
        // camera file that will not open costs the bubble rather than the picture — the
        // exporter's bargain, made here for the same reason.
        var camera: CIImage?
        if scene.webcam != nil, let webcamURL {
            camera = try? await frame(of: webcamURL, at: scene.sourceTime).image
        }
        // The other side of a crossfade, the same two reads again at its own moment.
        var lent: CIImage?
        var lentCamera: CIImage?
        if let other = scene.blendedScene, other.showsRecording {
            lent = try await frame(of: try file(other), at: other.sourceTime).image
            if other.webcam != nil, let webcamURL {
                lentCamera = try? await frame(of: webcamURL, at: other.sourceTime).image
            }
        }
        guard let image = image(for: scene, source: source, webcam: camera,
                                blending: lent, blendingWebcam: lentCamera, fitting: settings) else {
            throw ExportError.writerFailed("The frame couldn't be drawn.")
        }
        return image
    }

    /// The bytes of a PNG, for a file on disk.
    public static func pngData(of image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// One exact frame of a file, the way up the preview shows it, and the file's size.
    private static func frame(of url: URL, at time: CMTime) async throws(ExportError) -> (image: CIImage?, size: CGSize) {
        let asset = AVURLAsset(url: url)
        let size: CGSize
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExportError.noVideoTrack
            }
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            size = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.unreadableSource(error.localizedDescription)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = .zero
        let image: CGImage? = await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: max(.zero, time)) { image, _, _ in
                continuation.resume(returning: image)
            }
        }
        return (image.map { CIImage(cgImage: $0) }, size)
    }
}
