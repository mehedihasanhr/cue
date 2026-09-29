import CoreImage
import CoreMedia
import Foundation

/// The frame the other side of a crossfade lends, read out of the recording for an export.
///
/// Its own readers rather than the export's: the main reader walks the recording in order,
/// and asking it for the other clip's frame in the middle of that walk would send it back
/// to a keyframe and forward again on every frame of the transition. The frame lent is
/// the same one for a whole half of a transition — see `ClipTransition` — so it is read
/// once and held, and a project with no crossfades never opens these at all.
final class LentFrames {
    private let videoURL: URL
    private let webcamURL: URL?
    private let packageURL: URL?
    /// The pictures, from whichever file the other side's clip plays. See `SourceFrames`.
    private var screen: SourceFrames?
    private var camera: ExportFrameReader?
    private var held: (time: CMTime, media: String?, screen: CIImage?, camera: CIImage?)?

    init(videoURL: URL, webcamURL: URL?, packageURL: URL? = nil) {
        self.videoURL = videoURL
        self.webcamURL = webcamURL
        self.packageURL = packageURL
    }

    /// The recording's and the camera's frames for the other side of `scene`'s crossfade,
    /// or nothing when it is not in one.
    ///
    /// A camera file that will not open costs the other side its bubble, not the export —
    /// the bargain the exporter makes for the camera everywhere else.
    func frames(for scene: SceneDescriptor) async throws(ExportError) -> (screen: CIImage?, camera: CIImage?) {
        guard let other = scene.blendedScene, other.showsRecording else { return (nil, nil) }
        if let held, held.time == other.sourceTime, held.media == other.sourceMedia {
            return (held.screen, held.camera)
        }

        if screen == nil {
            let reader = try await ExportFrameReader(url: videoURL)
            // Where the reader learns the recording's rotation, as the exporter's does.
            _ = await reader.naturalSize()
            screen = SourceFrames(recording: reader, packageURL: packageURL)
        }
        let picture = try await screen?.frame(for: other)

        var face: CIImage?
        if other.webcam != nil, other.sourceMedia == nil, let webcamURL {
            if camera == nil, let reader = try? await ExportFrameReader(url: webcamURL) {
                _ = await reader.naturalSize()
                camera = reader
            }
            face = try? camera?.frame(at: other.sourceTime)
        }
        held = (other.sourceTime, other.sourceMedia, picture, face)
        return (picture, face)
    }

    func cancel() {
        screen?.cancel()
        camera?.cancel()
        held = nil
    }
}
