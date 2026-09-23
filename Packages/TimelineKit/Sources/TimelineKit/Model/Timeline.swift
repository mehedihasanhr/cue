import CoreMedia
import Foundation

/// The whole edit, as one value.
///
/// Every field is a value type, which buys three things at once: undo is a stored copy
/// rather than a pile of inverse operations, "has this changed?" is `==`, and no part of
/// the editor can mutate the document behind another part's back.
public struct Timeline: Equatable, Codable, Sendable {
    /// What this file was written by, so a future reader knows what it is looking at.
    public static let currentFormat = 1

    /// Absent from projects written before the field existed, which is exactly why it
    /// decodes to the current version rather than failing.
    public var formatVersion: Int
    /// How long the recording is, unedited. Kept so a trim knows what it may extend
    /// back into.
    public var sourceDuration: CMTime
    /// Primary footage, in order, contiguous. Never empty for a real project.
    public var clips: [Clip]
    public var zooms: [ZoomRegion]
    public var blurs: [BlurRegion]
    public var annotations: [AnnotationItem]
    public var captions: [CaptionCue]
    public var audio: [AudioRegion]
    public var style: FrameStyle
    public var cursor: CursorStyle
    public var webcam: WebcamSettings
    public var captionStyle: CaptionStyle

    public init(formatVersion: Int = Timeline.currentFormat,
                sourceDuration: CMTime,
                clips: [Clip]? = nil,
                zooms: [ZoomRegion] = [],
                blurs: [BlurRegion] = [],
                annotations: [AnnotationItem] = [],
                captions: [CaptionCue] = [],
                audio: [AudioRegion] = [],
                style: FrameStyle = FrameStyle(),
                cursor: CursorStyle = CursorStyle(),
                webcam: WebcamSettings = WebcamSettings(),
                captionStyle: CaptionStyle = CaptionStyle()) {
        self.formatVersion = formatVersion
        self.sourceDuration = sourceDuration
        self.clips = clips ?? [Clip(sourceStart: .zero, sourceDuration: sourceDuration)]
        self.zooms = zooms
        self.blurs = blurs
        self.annotations = annotations
        self.captions = captions
        self.audio = audio
        self.style = style
        self.cursor = cursor
        self.webcam = webcam
        self.captionStyle = captionStyle
    }

    // MARK: - Reading a project back

    /// Decodes one field at a time, keeping whatever is readable.
    ///
    /// The synthesised decoder is all-or-nothing: a single field written by a newer
    /// build — or one hand-edited into nonsense — throws, and the caller's only choice
    /// is to hand back an empty edit. Losing a background is a shrug; losing every cut
    /// and zoom because of it is not. So each field falls back to its default on its
    /// own, and `formatVersion` says what the file claimed to be.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }

        formatVersion = value(.formatVersion, default: Timeline.currentFormat)
        sourceDuration = value(.sourceDuration, default: .zero)
        let decodedClips: [Clip] = value(.clips, default: [])
        clips = decodedClips.isEmpty
            ? [Clip(sourceStart: .zero, sourceDuration: sourceDuration)]
            : decodedClips
        zooms = value(.zooms, default: [])
        blurs = value(.blurs, default: [])
        annotations = value(.annotations, default: [])
        captions = value(.captions, default: [])
        audio = value(.audio, default: [])
        style = value(.style, default: FrameStyle())
        cursor = value(.cursor, default: CursorStyle())
        webcam = value(.webcam, default: WebcamSettings())
        captionStyle = value(.captionStyle, default: CaptionStyle())
    }

    /// Spelled out so `init(from:)` above and the synthesised encoder agree, and so
    /// renaming a property is a compile error rather than a silently unreadable project.
    enum CodingKeys: String, CodingKey {
        case formatVersion, sourceDuration, clips, zooms, blurs
        case annotations, captions, audio, style, cursor, webcam, captionStyle
    }

    /// How long the edit plays for.
    public var duration: CMTime {
        clips.reduce(CMTime.zero) { $0 + $1.duration }
    }

    /// Where a clip starts on the timeline: the lengths of everything before it.
    ///
    /// Derived rather than stored, so a clip cannot claim a position that contradicts
    /// its neighbours — the bug every timeline gets wrong once.
    public func start(of clip: Clip) -> CMTime? {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return nil }
        return start(ofClipAt: index)
    }

    public func start(ofClipAt index: Int) -> CMTime {
        clips.prefix(index).reduce(CMTime.zero) { $0 + $1.duration }
    }

    /// The clip playing at a timeline time, and how far into it that is.
    ///
    /// The end of the timeline belongs to the last clip rather than to nothing: a
    /// playhead parked at the very end still has a frame to show.
    public func clip(at time: CMTime) -> (index: Int, clip: Clip, offset: CMTime)? {
        guard !clips.isEmpty else { return nil }
        var elapsed = CMTime.zero
        for (index, clip) in clips.enumerated() {
            let next = elapsed + clip.duration
            if time < next || index == clips.count - 1 {
                return (index, clip, max(.zero, min(time - elapsed, clip.duration)))
            }
            elapsed = next
        }
        return nil
    }

    /// Where a timeline time lands in the recording.
    ///
    /// This is the mapping everything else is built on: the preview seeks with it, the
    /// exporter pulls frames with it, and the cursor overlay looks up telemetry with it.
    public func sourceTime(at time: CMTime) -> CMTime? {
        guard let (_, clip, offset) = clip(at: time) else { return nil }
        return clip.sourceTime(atOffset: offset)
    }

    /// Where a moment in the recording ends up on the timeline.
    ///
    /// The inverse of `sourceTime(at:)`, and the mapping anything measured against the
    /// original footage needs: speech recognition runs on the recorded audio and comes
    /// back with times in *its* clock, which is not the edit's once anything has been
    /// trimmed, reordered or sped up.
    ///
    /// `nil` when that moment was cut: footage nobody kept has no place on the timeline,
    /// and a caption for words nobody will hear is worse than no caption. Where a moment
    /// survives in more than one clip — the same stretch used twice — the first is the
    /// answer, which is the one a reader reaches first.
    public func timelineTime(atSource source: CMTime) -> CMTime? {
        var elapsed = CMTime.zero
        for clip in clips {
            if source >= clip.sourceStart, source < clip.sourceEnd {
                let into = source - clip.sourceStart
                return elapsed + CMTimeMultiplyByFloat64(into, multiplier: 1 / clip.speed)
            }
            elapsed = elapsed + clip.duration
        }
        return nil
    }

    /// Every edge a drag can snap to: clip cuts, region edges, the start and the end.
    public var boundaries: [CMTime] {
        var times: [CMTime] = [.zero, duration]
        var elapsed = CMTime.zero
        for clip in clips {
            elapsed = elapsed + clip.duration
            times.append(elapsed)
        }
        for zoom in zooms { times.append(zoom.start); times.append(zoom.end) }
        for blur in blurs { times.append(blur.start); times.append(blur.end) }
        for item in annotations { times.append(item.start); times.append(item.end) }
        for cue in captions { times.append(cue.start); times.append(cue.end) }
        for region in audio { times.append(region.start); times.append(region.end) }
        return times
    }
}
