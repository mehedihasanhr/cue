import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RenderKit
import TimelineKit

/// The pictures of the movies brought into a project, for the preview and the clip lane.
///
/// The recording has its own `FrameSource` and `ClipThumbnails`, opened with the editor.
/// A movie brought in gets the same two, opened the first time something asks for one of
/// its frames — so a project with nothing imported opens nothing more than it did, and one
/// with ten movies in it only pays for the ones being looked at.
@MainActor
final class ImportedMedia {
    private let packageURL: URL
    private var sources: [String: FrameSource] = [:]
    /// Opens in flight, so two frames asked for at once share one open.
    private var opening: [String: Task<FrameSource?, Never>] = [:]
    private var strips: [String: ClipThumbnails] = [:]

    init(packageURL: URL) {
        self.packageURL = packageURL
    }

    /// A frame of the movie at `path`, at `time` in it, decoded as exactly as the preview
    /// is decoding the recording right now. `nil` when the file will not open.
    func frame(from path: String, at time: CMTime, quality: FrameSource.Quality) async -> CIImage? {
        guard let source = await source(for: path) else { return nil }
        await source.setQuality(quality)
        return await source.frame(at: time)
    }

    /// Warms the frames just ahead, the way the recording's are warmed during playback.
    func prefetch(from path: String, around time: CMTime, forward: Bool) async {
        await sources[path]?.prefetch(around: time, forward: forward)
    }

    private func source(for path: String) async -> FrameSource? {
        if let source = sources[path] { return source }
        if let pending = opening[path] { return await pending.value }
        let url = packageURL.appendingPathComponent(path)
        // A smaller cache than the recording's: a movie brought in is usually a short
        // stretch of the edit, and each decoded frame is the size of its picture.
        let pending = Task { try? await FrameSource(url: url, capacity: 12) }
        opening[path] = pending
        let source = await pending.value
        opening[path] = nil
        if let source { sources[path] = source }
        return source
    }

    /// The filmstrip for a movie's clips.
    func thumbnails(for file: MediaFile) -> ClipThumbnails {
        if let strip = strips[file.path] { return strip }
        let strip = ClipThumbnails(videoURL: packageURL.appendingPathComponent(file.path),
                                   size: file.pixelSize.width > 0 ? file.pixelSize : CGSize(width: 16, height: 9))
        strips[file.path] = strip
        return strip
    }

    /// Stops making pictures. For a window on its way out.
    func stop() {
        for strip in strips.values { strip.stop() }
        for pending in opening.values { pending.cancel() }
    }
}
