import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Taking a movie somebody chose and making it a background of a project.
///
/// Copied whole, for the reason pictures are copied: a project that points at a file in
/// somebody's Downloads stops working when it is moved. Not re-encoded — the renderer reads
/// it with the same decoder it reads the recording with, and any movie the Mac can play
/// will do. Only the picture is used; its sound never reaches the mix.
public enum BackgroundMovieImport {
    public enum Failure: Error, LocalizedError, Equatable {
        case notAMovie
        case couldNotCopy

        public var errorDescription: String? {
            switch self {
            case .notAMovie: "That file has no video in it that can be played."
            case .couldNotCopy: "That movie couldn't be copied into the project."
            }
        }
    }

    /// Asks for a movie. Returns `nil` when the user cancels.
    @MainActor
    public static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a background video"
        panel.message = "It plays on a loop behind the recording, without its sound."
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Copies `url` into `packageURL/Backgrounds/` and returns the path to store in the
    /// document — package-relative, with forward slashes — once it is known to have a
    /// picture in it.
    public static func copy(_ url: URL, into packageURL: URL) async throws -> String {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }

        let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        guard let tracks, !tracks.isEmpty else { throw Failure.notAMovie }

        let folder = packageURL.appendingPathComponent(BackgroundImport.folderName, isDirectory: true)
        let fileExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(fileExtension)"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        } catch {
            throw Failure.couldNotCopy
        }
        return "\(BackgroundImport.folderName)/\(name)"
    }
}
