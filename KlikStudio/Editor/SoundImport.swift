import AVFoundation
import AppKit
import CoreMedia
import Foundation
import TimelineKit

/// Bringing a sound into a project: music, a voiceover, an effect.
///
/// The copy is the point, for the same reason the background import copies: a sandboxed
/// app cannot reopen a path it merely remembers, and a project that points at
/// `~/Music/whatever.m4a` stops working the moment it moves to another Mac. The file goes
/// inside the package and the document stores a package-relative path.
///
/// Nothing is re-encoded. A background is downsampled because it is about to be scaled to
/// fill a frame anyway; sound has no equivalent — re-encoding it would only make it worse
/// than what the user chose.
enum SoundImport {
    /// Where imported sound lives inside a project package.
    static let folderName = "Audio"

    enum Failure: Error, LocalizedError {
        case unreadable
        case noSound

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file couldn't be read."
            case .noSound: "That file has no sound in it."
            }
        }
    }

    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a sound"
        panel.message = "Music, a voiceover or an effect to lay over the recording."
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Copies `url` into the package and describes what arrived.
    ///
    /// The duration is read here rather than guessed at the call site, because a region
    /// whose length does not match its file either stops early or runs into silence, and
    /// only the file knows which.
    static func copy(_ url: URL, into packageURL: URL) async throws -> (path: String, duration: CMTime) {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
            throw Failure.noSound
        }
        guard let duration = try? await asset.load(.duration), duration > .zero else {
            throw Failure.unreadable
        }

        let folder = packageURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A fresh name rather than the original: two files called `music.m4a` from two
        // folders are two different sounds, and one must not quietly replace the other.
        let name = "\(UUID().uuidString).\(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)"
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: destination)

        return ("\(folderName)/\(name)", duration)
    }
}
