import CoreGraphics
import CoreMedia
import Foundation

/// A movie brought into the project: another take, or any video file.
///
/// The file itself is copied into the package, and clips name it by `path` — see
/// `Clip.source`. What is kept here is what the edit needs to know about the file without
/// opening it: how long it is, so a trim knows how far it may reach; how big its picture
/// is, so `SceneBuilder` can fit it into the recording's frame without a decoder; and
/// whether it has any sound, so the mixdown does not go looking for none.
///
/// Measured once, when it arrives, and never again. A file in the package does not change
/// under the edit, and asking AVFoundation for a duration on every frame of the preview
/// would be the editor waiting on the disk to say what it already said.
public struct MediaFile: Identifiable, Equatable, Codable, Sendable {
    /// Relative to the package, like every other file the edit uses.
    public var path: String
    /// What the file was called before it was copied in, for the timeline and the
    /// inspector. The copy has a fresh name so two `clip.mov`s cannot collide.
    public var name: String
    public var duration: CMTime
    /// The picture's size in pixels, rotation applied.
    public var pixelSize: CGSize
    public var hasSound: Bool
    public var kind: Kind

    public enum Kind: String, Codable, Sendable {
        /// Any movie file.
        case video
        /// The screen of another Cue recording. Its pointer and clicks stay behind: they
        /// were measured against that take's clock, and this project keeps only one.
        case recording
    }

    public var id: String { path }

    public init(path: String, name: String, duration: CMTime, pixelSize: CGSize,
                hasSound: Bool, kind: Kind = .video) {
        self.path = path
        self.name = name
        self.duration = duration
        self.pixelSize = pixelSize
        self.hasSound = hasSound
        self.kind = kind
    }

    /// Where the media files live inside a project package.
    public static let folderName = "Movies"

    // MARK: - Reading a project back

    private enum CodingKeys: String, CodingKey {
        case path, name, duration, pixelSize, hasSound, kind
    }

    /// Only the path is required: without it there is no file to name. Everything else
    /// falls back to something that still plays — a missing duration to "as long as
    /// the clips on it reach", a missing size to "the recording's own", which the builder
    /// reads as no fit at all.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        path = try container.decode(String.self, forKey: .path)
        name = value(.name, default: (path as NSString).lastPathComponent)
        duration = value(.duration, default: .zero)
        pixelSize = value(.pixelSize, default: .zero)
        hasSound = value(.hasSound, default: true)
        kind = value(.kind, default: .video)
    }

    /// One entry of a list, or nothing when it will not decode — so a list of files is
    /// read file by file.
    struct Lenient: Decodable {
        let value: MediaFile?

        init(from decoder: any Decoder) throws {
            value = try? MediaFile(from: decoder)
        }
    }
}

extension Timeline {
    /// The imported file a clip plays, or `nil` for a clip of the recording — or for one
    /// naming a file this project has no record of, which a hand-edited project can.
    public func media(for clip: Clip) -> MediaFile? {
        guard let source = clip.source else { return nil }
        return media.first { $0.path == source }
    }

    /// How much footage a clip's file has to offer: the recording's length for a clip of
    /// the recording, the imported file's for an imported one.
    ///
    /// What a trim is bounded by. An imported clip whose file has gone unrecorded is
    /// bounded by what it already plays, so a trim can shorten it and never reach past
    /// the end of something nobody measured.
    public func sourceDuration(of clip: Clip) -> CMTime {
        guard let source = clip.source else { return sourceDuration }
        if let file = media.first(where: { $0.path == source }), file.duration > .zero {
            return file.duration
        }
        return clip.sourceEnd
    }

    /// Where a timeline time lands in whichever file the clip under it plays, and which
    /// file that is — `nil` for the recording.
    ///
    /// What reads *pictures* asks this; what reads the pointer, the clicks or the words
    /// asks `sourceTime(at:)`, which has no answer over an imported clip. A freeze frame of
    /// an imported clip answers with the moment it holds in that clip's file.
    public func mediaTime(at time: CMTime) -> (source: String?, time: CMTime)? {
        guard let (_, clip, offset) = clip(at: time) else { return nil }
        return (clip.source, clip.sourceTime(atOffset: offset))
    }
}
