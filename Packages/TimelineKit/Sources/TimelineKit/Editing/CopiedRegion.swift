import CoreMedia
import Foundation

/// A region lifted off the timeline, on its way somewhere else.
///
/// The thing a copy has to survive is not a variable — it is a trip through the system
/// pasteboard and into a *different* editor window, possibly a different project, and in
/// principle a different build of the app. So this is a value with a written-down
/// encoding rather than a reference to something in a timeline: by the time it is pasted,
/// the timeline it came from may have been closed, and the region it names deleted.
///
/// Five cases rather than `any TimelineRegion` because the pasteboard has to be told
/// which lane to put it back in, and an existential cannot say. It also keeps decoding
/// honest: a payload that claims a kind this build has never heard of is refused at the
/// boundary instead of becoming a half-initialised region.
public enum CopiedRegion: Equatable, Sendable {
    case zoom(ZoomRegion)
    case blur(BlurRegion)
    case annotation(AnnotationItem)
    case caption(CaptionCue)
    case audio(AudioRegion)

    /// Reads whatever the selection points at, if it points at something copyable.
    ///
    /// `nil` for a clip, a range and the trim handles. That is not an oversight — see the
    /// note on `placed(at:in:)` about why footage is a different feature.
    public init?(_ selection: Selection, in timeline: Timeline) {
        switch selection {
        case .zoom(let id):
            guard let region = timeline.zooms.first(where: { $0.id == id }) else { return nil }
            self = .zoom(region)
        case .blur(let id):
            guard let region = timeline.blurs.first(where: { $0.id == id }) else { return nil }
            self = .blur(region)
        case .annotation(let id):
            guard let item = timeline.annotations.first(where: { $0.id == id }) else { return nil }
            self = .annotation(item)
        case .caption(let id):
            guard let cue = timeline.captions.first(where: { $0.id == id }) else { return nil }
            self = .caption(cue)
        case .audio(let id):
            guard let region = timeline.audio.first(where: { $0.id == id }) else { return nil }
            self = .audio(region)
        case .none, .clip, .range, .headTrim, .tailTrim, .sound:
            return nil
        }
    }

    // MARK: - What it is

    public var id: UUID {
        switch self {
        case .zoom(let r): r.id
        case .blur(let r): r.id
        case .annotation(let r): r.id
        case .caption(let r): r.id
        case .audio(let r): r.id
        }
    }

    public var start: CMTime {
        switch self {
        case .zoom(let r): r.start
        case .blur(let r): r.start
        case .annotation(let r): r.start
        case .caption(let r): r.start
        case .audio(let r): r.start
        }
    }

    public var duration: CMTime {
        switch self {
        case .zoom(let r): r.duration
        case .blur(let r): r.duration
        case .annotation(let r): r.duration
        case .caption(let r): r.duration
        case .audio(let r): r.duration
        }
    }

    public var end: CMTime { start + duration }

    /// What the menu and the undo stack call it: "Paste Zoom", "Duplicate Sound".
    ///
    /// "Sound" rather than "Audio" because that is the word the rest of the editor uses
    /// for an imported track, and a menu that calls the same thing two names is a menu
    /// the user has to translate.
    public var title: String {
        switch self {
        case .zoom: "Zoom"
        case .blur: "Blur"
        case .annotation: "Annotation"
        case .caption: "Caption"
        case .audio: "Sound"
        }
    }

    /// How the editor would point at this, so pasting can leave the new copy selected
    /// without the caller switching over the kinds a second time.
    public var selection: Selection {
        switch self {
        case .zoom(let r): .zoom(r.id)
        case .blur(let r): .blur(r.id)
        case .annotation(let r): .annotation(r.id)
        case .caption(let r): .caption(r.id)
        case .audio(let r): .audio(r.id)
        }
    }

    /// The sound file this refers to, for the one kind that refers to one.
    ///
    /// Paths in an `AudioRegion` are relative to the *project package* so a project stays
    /// portable, which means a sound copied out of one project and pasted into another
    /// names a file that is not there. The paster has to check, and this is what it
    /// checks — see `EditorModel.pasteAtPlayhead`.
    public var audioPath: String? {
        if case .audio(let region) = self { return region.path }
        return nil
    }

    // MARK: - Where it lands

    /// A copy of this region, with a new identity, put at `start` in `timeline`.
    ///
    /// Three rules, in this order. It gets a fresh `id`, because two regions with one id
    /// is a document where selecting, moving and deleting all pick the wrong one. It
    /// keeps its duration, because the duration is most of what was worth copying — a
    /// zoom somebody tuned is a length as much as a scale. And it is clamped into the
    /// edit, because a region past the end of the timeline is one the user cannot see,
    /// reach or get rid of; when there is not room for the full length at `start`, the
    /// length gives way rather than the position, so the paste lands where it was asked
    /// for.
    ///
    /// `nil` when the edit has no room for a region at all, which is a timeline shorter
    /// than `Clip.minimumDuration` — nothing sensible to do but refuse.
    ///
    /// Deliberately only regions. A copied *clip* or a copied `Selection.range` is
    /// footage, and pasting footage is a different operation: it has to insert time into
    /// the timeline, split whatever clip the playhead is inside, and ripple every region
    /// after the insertion point along — which is `ClipSequence`'s work, not a paste's.
    /// Doing it badly would be worse than not offering it, so the range cases return
    /// `nil` from `init?(_:in:)` above and the menu item stays disabled.
    public func placed(at start: CMTime, in timeline: Timeline) -> CopiedRegion? {
        let end = timeline.duration
        guard end > Clip.minimumDuration else { return nil }
        let start = max(.zero, min(start, end - Clip.minimumDuration))
        let duration = max(Clip.minimumDuration, min(self.duration, end - start))

        // Rebuilt through each initialiser rather than mutated, because `id` is a `let` on
        // every region — which is the right thing for a region sitting in a document, and
        // the reason the one place that needs a new identity has to say so five times.
        switch self {
        case .zoom(let r):
            return .zoom(ZoomRegion(start: start, duration: duration, scale: r.scale,
                                    center: r.center, easing: r.easing, transition: r.transition,
                                    followsCursor: r.followsCursor, source: r.source))
        case .blur(let r):
            return .blur(BlurRegion(start: start, duration: duration,
                                    rect: r.rect, style: r.style, radius: r.radius))
        case .annotation(let r):
            return .annotation(AnnotationItem(start: start, duration: duration, kind: r.kind,
                                              rect: r.rect, color: r.color, fontSize: r.fontSize))
        case .caption(let r):
            return .caption(CaptionCue(start: start, duration: duration, text: r.text))
        case .audio(let r):
            return .audio(AudioRegion(start: start, duration: duration, path: r.path,
                                      gain: r.gain, sourceStart: r.sourceStart))
        }
    }

    // MARK: - Words for other apps

    /// A one-line description, for the plain text written alongside the real payload.
    ///
    /// Written because a pasteboard with only a private type on it is a pasteboard that
    /// looks empty to everything else on the Mac: ⌘C on a zoom and then ⌘V into Notes, a
    /// bug report or a message would do nothing at all, which reads as the copy having
    /// failed. A sentence costs nothing and means the gesture always produces something.
    /// It is deliberately one-way — nothing tries to parse this back into a region, so it
    /// can be rephrased whenever the wording improves.
    public var summary: String {
        let length = String(format: "%.2fs", duration.seconds)
        switch self {
        case .zoom(let r):
            return "Klik zoom · \(String(format: "%.1f", r.scale))× · \(length)"
        case .blur(let r):
            return "Klik blur · \(r.style == .pixelate ? "pixelate" : "gaussian") · \(length)"
        case .annotation(let r):
            switch r.kind {
            case .text(let text): return "Klik annotation · “\(text)” · \(length)"
            case .arrow: return "Klik annotation · arrow · \(length)"
            case .rectangle: return "Klik annotation · rectangle · \(length)"
            case .image(let path): return "Klik annotation · \((path as NSString).lastPathComponent) · \(length)"
            }
        case .caption(let r):
            // The caption's own words, which are the thing somebody pasting a caption
            // elsewhere actually wants.
            return r.text
        case .audio(let r):
            return "Klik sound · \((r.path as NSString).lastPathComponent) · \(length)"
        }
    }
}

// MARK: - Crossing the pasteboard

extension CopiedRegion: Codable {
    /// Bumped if the shape of the envelope ever changes. The region inside it is versioned
    /// by its own decoder — every field in `Regions.swift` is optional-tolerant — so this
    /// only has to describe the wrapper.
    public static let currentFormat = 1

    private enum CodingKeys: String, CodingKey {
        case formatVersion, kind, region
    }

    /// Spelled out, and *not* the case names, so renaming a case in Swift does not quietly
    /// make every copy made by an older build unreadable.
    private enum Kind: String, Codable {
        case zoom, blur, annotation, caption, audio
    }

    private var kind: Kind {
        switch self {
        case .zoom: .zoom
        case .blur: .blur
        case .annotation: .annotation
        case .caption: .caption
        case .audio: .audio
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormat, forKey: .formatVersion)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .zoom(let r): try container.encode(r, forKey: .region)
        case .blur(let r): try container.encode(r, forKey: .region)
        case .annotation(let r): try container.encode(r, forKey: .region)
        case .caption(let r): try container.encode(r, forKey: .region)
        case .audio(let r): try container.encode(r, forKey: .region)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A kind this build does not know is the newer-app case, and it throws rather
        // than guessing: a zoom is not a blur, and there is no sensible region to invent
        // from a name we have never seen. `decoded(from:)` turns that into a refusal.
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .zoom: self = .zoom(try container.decode(ZoomRegion.self, forKey: .region))
        case .blur: self = .blur(try container.decode(BlurRegion.self, forKey: .region))
        case .annotation: self = .annotation(try container.decode(AnnotationItem.self, forKey: .region))
        case .caption: self = .caption(try container.decode(CaptionCue.self, forKey: .region))
        case .audio: self = .audio(try container.decode(AudioRegion.self, forKey: .region))
        }
    }

    /// The bytes to put on the pasteboard.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Whatever was on the pasteboard, if it was one of these.
    ///
    /// Anything at all can be sitting under our type — a truncated write, a payload from a
    /// build that has a region kind this one has not, a file another app happened to
    /// declare. So this returns an optional rather than throwing, and every caller treats
    /// "not a region we understand" the same way it treats an empty pasteboard: the Paste
    /// item is simply disabled. Nothing here trusts a length, an index or a range read out
    /// of the payload, which is what keeps rubbish from becoming a crash.
    public static func decoded(from data: Data) -> CopiedRegion? {
        try? JSONDecoder().decode(CopiedRegion.self, from: data)
    }
}
