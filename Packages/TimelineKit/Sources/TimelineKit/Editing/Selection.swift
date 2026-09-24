import CoreMedia
import Foundation

/// What the editor is pointing at.
///
/// One thing at a time, deliberately. The inspector shows the properties of *a* zoom or
/// *a* clip, and a multi-object inspector is a much larger design than anything the
/// timeline needs today. `.range` covers the cases where "several things" is really the
/// answer — delete this stretch, speed this stretch up — and it maps straight onto the
/// two commands that already take a `CMTimeRange`.
///
/// Deliberately *not* part of `Timeline`: selecting something is not an edit. It must
/// not land on the undo stack, and since `isDirty` is `timeline != savedTimeline`, a
/// selection stored in the document would mark a project unsaved just for being looked
/// at.
public enum Selection: Equatable, Sendable {
    case none
    case clip(UUID)
    case zoom(UUID)
    case blur(UUID)
    case annotation(UUID)
    case caption(UUID)
    case audio(UUID)
    /// A stretch where the pointer behaves differently — hidden, calmed, held.
    case cursorRegion(UUID)
    /// The recording's own sound, which is one lane rather than one of many regions —
    /// there is exactly one of it, so it needs no identity to be picked out.
    case sound
    /// A stretch of the timeline rather than an object on it.
    case range(CMTimeRange)
    /// The footage trimmed off the front of the first clip.
    case headTrim
    /// The footage trimmed off the end of the last clip.
    case tailTrim

    /// The region this points at, for the commands that take an id.
    ///
    /// `nil` for a clip as well as for the non-object cases: a clip is not a region, and
    /// handing its id to `Commands.DeleteRegion` would silently do nothing.
    public var regionID: UUID? {
        switch self {
        case .zoom(let id), .blur(let id), .annotation(let id), .caption(let id), .audio(let id),
             .cursorRegion(let id):
            id
        case .none, .clip, .range, .headTrim, .tailTrim, .sound:
            nil
        }
    }

    public var clipID: UUID? {
        if case .clip(let id) = self { return id }
        return nil
    }

    public var isEmpty: Bool {
        if case .none = self { return true }
        return false
    }

    /// Whether this still points at something that exists.
    ///
    /// Worth checking after every edit: `ClipSequence.clampRegions` quietly drops any
    /// region that an edit shortened below `Clip.minimumDuration`, so a selection can
    /// stop being valid without anything having deleted it.
    public func isValid(in timeline: Timeline) -> Bool {
        switch self {
        case .none:
            return true
        case .clip(let id):
            return timeline.clips.contains { $0.id == id }
        case .zoom(let id):
            return timeline.zooms.contains { $0.id == id }
        case .blur(let id):
            return timeline.blurs.contains { $0.id == id }
        case .annotation(let id):
            return timeline.annotations.contains { $0.id == id }
        case .caption(let id):
            return timeline.captions.contains { $0.id == id }
        case .audio(let id):
            return timeline.audio.contains { $0.id == id }
        case .cursorRegion(let id):
            return timeline.cursorRegions.contains { $0.id == id }
        case .range(let range):
            return range.duration > .zero && range.start < timeline.duration
        case .sound:
            // Always valid: every recording has the setting, even one with no sound in it.
            return true
        case .headTrim:
            return (timeline.clips.first?.sourceStart ?? .zero) > .zero
        case .tailTrim:
            guard let last = timeline.clips.last else { return false }
            return last.sourceEnd < timeline.sourceDuration
        }
    }

    /// The stretch of timeline this occupies, when it occupies one.
    public func range(in timeline: Timeline) -> CMTimeRange? {
        switch self {
        case .range(let range):
            return range
        case .clip(let id):
            guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return nil }
            return CMTimeRange(start: timeline.start(ofClipAt: index),
                               duration: timeline.clips[index].duration)
        case .zoom(let id):
            return timeline.zooms.first { $0.id == id }?.range
        case .blur(let id):
            return timeline.blurs.first { $0.id == id }?.range
        case .annotation(let id):
            return timeline.annotations.first { $0.id == id }?.range
        case .caption(let id):
            return timeline.captions.first { $0.id == id }?.range
        case .audio(let id):
            return timeline.audio.first { $0.id == id }?.range
        case .cursorRegion(let id):
            return timeline.cursorRegions.first { $0.id == id }?.range
        case .none, .headTrim, .tailTrim, .sound:
            return nil
        }
    }
}
