import CoreMedia
import Foundation

/// One run of the source footage, at one speed.
///
/// The model that makes the awkward cases impossible rather than merely unlikely:
///
/// - A clip stores where it starts **in the source**, never where it sits on the
///   timeline. Its timeline position is its predecessors' lengths added up, so the
///   sequence is contiguous by construction — there is no such thing as a gap to
///   normalise away, and reordering cannot invent one.
/// - `speed` is source seconds consumed per timeline second, so a 2× clip plays half as
///   long. Deriving the timeline length from the source length (rather than storing
///   both) means they can never disagree.
///
/// # Clips that do not play
///
/// A clip can also stand still: a freeze frame holds the one frame at `sourceStart`, and a
/// title slide shows no footage at all. Both are `hold`s — a length of their own, with
/// `sourceDuration` zero — so they sit in the same contiguous sequence as the footage and
/// every edit that walks it (split, delete, ripple, reorder, copy and paste) moves them
/// without learning a second arithmetic. What differs is only what a clip *consumes*:
/// nothing. That zero is doing work: a held clip reaches no moment of the recording, so
/// nothing measured against the recording — a caption from speech, a click's sound, the
/// sound itself — can land on it by accident.
public struct Clip: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    /// The in-point in the recording. Trimming, reordering and speed changes never
    /// re-derive this from a new timeline position — that is how an edit stays attached
    /// to the footage it was made against.
    ///
    /// For a freeze frame, the moment whose frame is held.
    public var sourceStart: CMTime
    /// How much source this clip consumes. Zero for a clip that holds.
    public var sourceDuration: CMTime
    /// Source seconds per timeline second. 1 is normal, 2 is twice as fast. Ignored by a
    /// clip that holds, which has no source to go through faster or slower.
    public var speed: Double
    /// How long the clip stands still, or `nil` for footage that plays.
    ///
    /// `nil` for every clip written before a clip could stand still, which is exactly
    /// what they were.
    public var hold: CMTime?
    /// What a title slide says. `nil` for footage and for a freeze frame.
    ///
    /// Only ever set together with `hold`: a title shows no footage, so the only thing
    /// that can say how long it lasts is its own length.
    public var title: TitleCard?
    /// How this clip arrives from the one before it, or `nil` for a plain cut.
    ///
    /// Stored on the clip after the cut rather than on the cut itself, because a cut is not
    /// a thing the model has — it is where one clip ends and the next begins — and the
    /// incoming clip is the one that *has* an entrance. It travels with the clip when the
    /// clip is moved, and is ignored on the first clip, which has nothing to arrive from.
    public var transition: ClipTransition?
    /// Where the picture and sound come from: `nil` for the recording itself, or the path,
    /// relative to the package, of a movie brought into the project. See `MediaFile`.
    ///
    /// `nil` for every clip written before a project could hold more than one take, which
    /// is exactly what they were. For an imported clip `sourceStart` and `sourceDuration`
    /// are times in *that* file, so nothing measured against the recording — the pointer,
    /// the clicks, the keys, the words — may be looked up with them: `Timeline.sourceTime(at:)`
    /// answers `nil` over such a clip, and every walk from the recording's clock into the
    /// edit passes it by.
    public var source: String?

    public init(id: UUID = UUID(), sourceStart: CMTime, sourceDuration: CMTime, speed: Double = 1,
                hold: CMTime? = nil, title: TitleCard? = nil, transition: ClipTransition? = nil,
                source: String? = nil) {
        self.id = id
        self.sourceStart = sourceStart
        self.speed = max(Clip.minimumSpeed, min(speed, Clip.maximumSpeed))
        // A title is a hold whether or not one was given: without a length it would last
        // for no time at all.
        let hold = hold ?? (title == nil ? nil : Clip.defaultTitleLength)
        self.hold = hold.map(Clip.clampedHold)
        // A clip that holds consumes nothing — see the note on the type.
        self.sourceDuration = hold == nil ? sourceDuration : .zero
        self.title = title
        self.transition = transition
        // A title shows no footage, so it has no file to show it from.
        self.source = title == nil ? source.flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    /// A still of the frame at `source`, held for `length`.
    ///
    /// - Parameter media: the file the frame is in, `nil` for the recording.
    public static func still(of source: CMTime, for length: CMTime = Clip.defaultStillLength,
                             in media: String? = nil) -> Clip {
        Clip(sourceStart: max(.zero, source), sourceDuration: .zero, hold: length, source: media)
    }

    /// A title slide, shown for `length`.
    public static func title(_ card: TitleCard, for length: CMTime = Clip.defaultTitleLength) -> Clip {
        Clip(sourceStart: .zero, sourceDuration: .zero, hold: length, title: card)
    }

    public static let minimumSpeed = 0.25
    public static let maximumSpeed = 8.0
    /// Shorter than this and a clip is a cut, not a clip. Also what a resize stops at.
    public static let minimumDuration = CMTime(value: 1, timescale: 10)
    /// How long a freeze frame lasts unless somebody says otherwise: long enough to read
    /// the screen it is holding, short enough not to feel like the video has stalled.
    public static let defaultStillLength = CMTime(value: 2, timescale: 1)
    /// How long a title slide lasts unless somebody says otherwise: a title and a
    /// subtitle read aloud at an easy pace, with its entrance.
    public static let defaultTitleLength = CMTime(value: 3, timescale: 1)
    /// The longest a clip may stand still. Ten minutes is not a freeze frame any more; it
    /// is a file hand-edited into nonsense, and a number that large would make every
    /// region after it unreachable on the timeline.
    public static let maximumHold = CMTime(value: 600, timescale: 1)

    static func clampedHold(_ length: CMTime) -> CMTime {
        guard length.isNumeric else { return defaultStillLength }
        return max(minimumDuration, min(length, maximumHold))
    }

    /// How long this clip lasts on the timeline.
    public var duration: CMTime {
        if let hold { return hold }
        return CMTimeMultiplyByFloat64(sourceDuration, multiplier: 1 / speed)
    }

    public var sourceEnd: CMTime { sourceStart + sourceDuration }

    /// Whether this clip plays the recording, rather than holding a frame or showing a
    /// title. The question every edit that works in source time asks first.
    public var isFootage: Bool { hold == nil }

    /// Whether this clip holds one frame of the recording.
    public var isStill: Bool { hold != nil && title == nil }

    /// Whether this clip shows a title rather than any footage.
    public var isTitle: Bool { title != nil }

    /// Whether this clip's picture comes from a file brought into the project rather than
    /// from the recording — footage or a freeze frame of it.
    public var isImported: Bool { source != nil }

    /// Whether this clip plays the recording itself: footage, and not imported.
    ///
    /// The question every walk between the recording's clock and the edit's has to ask —
    /// a click, a word, a marker, a run of the recording's sound — because an imported
    /// clip's `sourceStart` is a time in another file, and a click at twelve seconds into
    /// the recording has nothing to do with twelve seconds into somebody's screencast.
    public var playsRecording: Bool { hold == nil && source == nil }

    /// Where a timeline offset inside this clip lands in the source.
    ///
    /// Every offset in a still lands on the frame it holds. A title answers with its
    /// `sourceStart` too, which is never drawn — the scene for a title has no picture in
    /// it — but is still a real moment of the recording, so nothing downstream is handed a
    /// time it cannot seek to.
    public func sourceTime(atOffset offset: CMTime) -> CMTime {
        guard hold == nil else { return sourceStart }
        return sourceStart + CMTimeMultiplyByFloat64(offset, multiplier: speed)
    }

    /// The part of this clip between two offsets into it, as a clip of its own.
    ///
    /// The one place that knows how each kind of clip is cut: footage keeps the source
    /// under that stretch at its own speed, and a clip that holds keeps holding the same
    /// thing for the shorter length. Keeps the id — callers that need a new one say so.
    func piece(from start: CMTime, to end: CMTime) -> Clip {
        var piece = self
        if hold != nil {
            piece.hold = end - start
        } else {
            piece.sourceStart = sourceTime(atOffset: start)
            piece.sourceDuration = CMTimeMultiplyByFloat64(end - start, multiplier: speed)
        }
        return piece
    }

    /// The same clip with a new identity, for a copy that must not alias its original.
    ///
    /// Everything it shows comes along; the transition does too, because arriving with a
    /// crossfade is part of what the copied clip looked like.
    public func renewed() -> Clip {
        Clip(sourceStart: sourceStart, sourceDuration: sourceDuration, speed: speed,
             hold: hold, title: title, transition: transition, source: source)
    }

    // MARK: - Reading a project back

    private enum CodingKeys: String, CodingKey {
        case id, sourceStart, sourceDuration, speed, hold, title, transition, source
    }

    /// The four fields every clip has always had are read as strictly as they always were;
    /// the four added since are read one at a time and fall back to "not there".
    ///
    /// Strict for the old ones because a clip without an in-point is not a clip, and
    /// guessing one would play the wrong footage. Lenient for the new ones because a
    /// title a newer build wrote, or one hand-edited into nonsense, must cost that title
    /// rather than the clip — and a clip that fails to decode costs the whole edit its
    /// cuts, since `Timeline` then falls back to one clip over the whole recording.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hold = (try? container.decodeIfPresent(CMTime.self, forKey: .hold)) ?? nil
        let title = (try? container.decodeIfPresent(TitleCard.self, forKey: .title)) ?? nil
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  sourceStart: try container.decode(CMTime.self, forKey: .sourceStart),
                  sourceDuration: try container.decode(CMTime.self, forKey: .sourceDuration),
                  speed: try container.decode(Double.self, forKey: .speed),
                  hold: hold,
                  title: title,
                  transition: (try? container.decodeIfPresent(ClipTransition.self, forKey: .transition)) ?? nil,
                  source: (try? container.decodeIfPresent(String.self, forKey: .source)) ?? nil)
    }

    /// Written so a clip of the recording that plays and arrives on a cut is byte for byte
    /// what it was before clips could hold, arrive, carry titles or come from another file:
    /// the new keys are left out rather than written as `null`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceStart, forKey: .sourceStart)
        try container.encode(sourceDuration, forKey: .sourceDuration)
        try container.encode(speed, forKey: .speed)
        try container.encodeIfPresent(hold, forKey: .hold)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(transition, forKey: .transition)
        try container.encodeIfPresent(source, forKey: .source)
    }
}
