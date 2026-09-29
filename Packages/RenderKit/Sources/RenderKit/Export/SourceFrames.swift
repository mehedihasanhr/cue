import CoreImage
import CoreMedia
import Foundation

/// The picture for each frame of an export, from whichever file its clip plays.
///
/// A project can hold movies brought in beside the recording, and a frame names its file
/// in `SceneDescriptor.sourceMedia`. Each file gets a reader of its own, opened the first
/// time a frame asks for it and walked in order from then on — so an edit that goes from
/// the recording to an imported clip and back costs each reader one jump, not one per
/// frame, and a project with nothing imported opens nothing new at all.
final class SourceFrames {
    private let packageURL: URL?
    private let recording: ExportFrameReader
    private var imported: [String: ExportFrameReader] = [:]

    /// - Parameter recording: the recording's reader, already asked for its size — the
    ///   exporter needs that before the first frame, so it opens the reader itself.
    init(recording: ExportFrameReader, packageURL: URL?) {
        self.recording = recording
        self.packageURL = packageURL
    }

    /// The picture `scene` shows, or `nil` for a title, which shows none.
    ///
    /// A movie the edit plays that is not in the package fails the export, and says which:
    /// writing its stretch as an empty frame would be a video with a hole in it that the
    /// preview never showed, since the preview cannot show it either.
    func frame(for scene: SceneDescriptor) async throws(ExportError) -> CIImage? {
        guard scene.showsRecording else { return nil }
        guard let path = scene.sourceMedia else { return try recording.frame(at: scene.sourceTime) }
        return try await reader(for: path).frame(at: scene.sourceTime)
    }

    private func reader(for path: String) async throws(ExportError) -> ExportFrameReader {
        if let reader = imported[path] { return reader }
        guard let packageURL else {
            throw ExportError.unreadableSource("A movie this edit plays could not be found.")
        }
        let url = packageURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw ExportError.unreadableSource("“\(url.lastPathComponent)” is missing from the project.")
        }
        let reader = try await ExportFrameReader(url: url)
        // Where the reader learns the file's rotation, as the recording's does.
        _ = await reader.naturalSize()
        imported[path] = reader
        return reader
    }

    func cancel() {
        recording.cancel()
        for reader in imported.values { reader.cancel() }
        imported.removeAll()
    }
}
