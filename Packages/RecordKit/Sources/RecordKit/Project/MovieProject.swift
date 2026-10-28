import AVFoundation
import Foundation

/// A new project made from a movie that was not recorded here.
///
/// The movie is copied into the package, as everything a project uses is: a project that
/// points at a file somewhere else stops working the moment the file is moved. Its sound,
/// if it has any, stays inside the copy and the manifest says so by naming the same file as
/// both the screen and the sound — the shape the earliest recordings had, which the editor
/// already reads. There is no pointer, no clicks and no keys: zooms, styling, captions and
/// everything else that works on a picture still do.
public enum MovieProject {
    public enum Failure: Error, LocalizedError, Equatable {
        case noVideo

        public var errorDescription: String? {
            switch self {
            case .noVideo: "That file has no video in it."
            }
        }
    }

    /// Makes the package in `folder`, named after the movie.
    public static func create(from movie: URL, in folder: URL) async throws -> RecordingPackage {
        let asset = AVURLAsset(url: movie)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideo
        }
        let duration = try await asset.load(.duration).seconds
        let (natural, transform, rate, formats) = try await video.load(.naturalSize, .preferredTransform,
                                                                       .nominalFrameRate, .formatDescriptions)
        let hasSound = try await !asset.loadTracks(withMediaType: .audio).isEmpty

        let name = movie.deletingPathExtension().lastPathComponent
        let package = try RecordingPackage.create(named: name, in: folder)
        do {
            let copy = package.mediaFolder.appendingPathComponent("screen")
                .appendingPathExtension(movie.pathExtension.isEmpty ? "mov" : movie.pathExtension.lowercased())
            try FileManager.default.copyItem(at: movie, to: copy)
            try package.write(manifest(name: name,
                                       path: package.relativePath(of: copy),
                                       duration: duration,
                                       pixelSize: displayedSize(natural, transform),
                                       frameRate: rate,
                                       codec: formats.first.map(fourCC),
                                       hasSound: hasSound))
            return package
        } catch {
            package.discard()
            throw error
        }
    }

    /// The manifest for a movie, kept apart from the file work so it can be tested alone.
    static func manifest(name: String,
                         path: String,
                         duration: Double,
                         pixelSize: CGSize,
                         frameRate: Float,
                         codec: String?,
                         hasSound: Bool) -> RecordingManifest {
        var tracks = [RecordingManifest.Track(kind: .screen,
                                              path: path,
                                              pixelSize: pixelSize,
                                              frameRate: frameRate > 0 ? Int(frameRate.rounded()) : 30,
                                              codec: codec)]
        if hasSound {
            tracks.append(.init(kind: .systemAudio, path: path, name: "Sound"))
        }
        // One pixel to a point: there is no screen behind this picture whose scale to keep.
        return RecordingManifest(name: name,
                                 duration: duration,
                                 displayScale: 1,
                                 sourceRect: CGRect(origin: .zero, size: pixelSize),
                                 tracks: tracks,
                                 recordedBy: "Cue Studio (imported)")
    }

    /// The size the movie is shown at: a phone video stored sideways with a rotation says
    /// so in its transform, and the picture is the rotated size.
    static func displayedSize(_ natural: CGSize, _ transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width.rounded()), height: abs(rect.height.rounded()))
    }

    private static func fourCC(_ format: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(format)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
