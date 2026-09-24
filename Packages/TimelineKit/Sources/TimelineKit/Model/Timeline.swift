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
    /// The recording's own sound, once it has been cut loose from the picture.
    ///
    /// `nil` — the default, and what every project written before this field existed
    /// decodes to — means the sound is not a lane of its own at all: it is cut exactly
    /// where `clips` is cut, because it is one take, and `AudioMixdown` lays it down from
    /// `clips`. That is the right default and nothing here changes it.
    ///
    /// Non-`nil` means the user detached it, and these runs are now the whole truth about
    /// the recording's sound: the picture's cuts say nothing about it any more. An *empty*
    /// array is therefore a meaningful state — a detached lane whose runs have all been
    /// deleted, which is silence — and that is why this is an `Optional` rather than an
    /// array whose emptiness would have to mean "attached".
    public var detachedSound: [SoundRun]?
    /// Stretches where the pointer does something other than what `cursor` says.
    ///
    /// An override on top of the global style, never a replacement for it: empty means
    /// "the pointer is drawn as `cursor` describes, everywhere", which is what every
    /// project written before this field existed decodes to.
    public var cursorRegions: [CursorRegion]
    public var style: FrameStyle
    public var cursor: CursorStyle
    public var camera: CameraStyle
    /// What the recording's own sound does. See `SoundStyle`.
    public var sound: SoundStyle
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
                detachedSound: [SoundRun]? = nil,
                cursorRegions: [CursorRegion] = [],
                style: FrameStyle = FrameStyle(),
                cursor: CursorStyle = CursorStyle(),
                camera: CameraStyle = CameraStyle(),
                sound: SoundStyle = SoundStyle(),
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
        self.detachedSound = detachedSound
        self.cursorRegions = cursorRegions
        self.style = style
        self.cursor = cursor
        self.camera = camera
        self.sound = sound
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
        // Absent in every project written before the sound could be detached, and absent
        // is `nil` rather than `[]` — the sound follows the picture, which is what those
        // projects sounded like and must go on sounding like.
        detachedSound = ((try? container.decodeIfPresent([SoundRun].self, forKey: .detachedSound)) ?? nil)
        // Absent in every project written before cursor regions existed, and empty is
        // exactly "the pointer behaves as the global style says" — so an old project opens
        // and renders frame for frame as it did.
        cursorRegions = value(.cursorRegions, default: [])
        style = value(.style, default: FrameStyle())
        cursor = value(.cursor, default: CursorStyle())
        camera = value(.camera, default: CameraStyle())
        sound = value(.sound, default: SoundStyle())
        webcam = value(.webcam, default: WebcamSettings())
        captionStyle = value(.captionStyle, default: CaptionStyle())
    }

    /// Spelled out so `init(from:)` above and the synthesised encoder agree, and so
    /// renaming a property is a compile error rather than a silently unreadable project.
    enum CodingKeys: String, CodingKey {
        case formatVersion, sourceDuration, clips, zooms, blurs
        case annotations, captions, audio, detachedSound, cursorRegions
        case style, cursor, camera, sound, webcam, captionStyle
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

    /// What the cursor regions ask of the pointer at one moment.
    ///
    /// On the model rather than in the renderer because it is a question about the edit,
    /// not about pixels, and because it has to be answerable without a renderer to test it
    /// with. The early return is not just tidiness: this runs on every frame of the
    /// preview and every frame of an export, and a project with no cursor regions — every
    /// project written before they existed — must pay nothing at all for them.
    public func cursorOverride(at time: CMTime) -> CursorOverride {
        guard !cursorRegions.isEmpty else { return .none }

        var override = CursorOverride.none
        for region in cursorRegions {
            let region = region.sanitised
            let presence = region.presence(at: time)
            guard presence > 0 else { continue }
            if region.isHidden { override.hiding = max(override.hiding, presence) }
            override.smoothingWindow = max(override.smoothingWindow, region.smoothingWindow(at: time))
            // The hold that has arrived furthest wins its anchor, because blending two
            // frozen positions would put the pointer somewhere it never was.
            if region.isHeld, presence > override.holding {
                override.holding = presence
                override.heldSince = region.start
            }
        }
        return override
    }

    // MARK: - The sound lane

    /// Whether the recording's sound has a life of its own yet.
    public var isSoundDetached: Bool { detachedSound != nil }

    /// The runs a detach performed right now would produce: the sound as the picture cuts
    /// it, one run per clip.
    ///
    /// Written once and used three ways — to perform the detach, to decide whether a
    /// re-attach would throw an edit away, and to test that detaching changes nothing you
    /// can hear. Three readings of one rule beat three implementations of it.
    public var soundRunsFollowingClips: [SoundRun] {
        var runs: [SoundRun] = []
        runs.reserveCapacity(clips.count)
        var playhead = CMTime.zero
        for clip in clips {
            runs.append(SoundRun(start: playhead,
                                 duration: clip.duration,
                                 sourceStart: clip.sourceStart,
                                 speed: clip.speed))
            playhead = playhead + clip.duration
        }
        return runs
    }

    /// Whether a detached lane still sounds exactly like the picture it was cut from.
    ///
    /// The question re-attaching has to ask before it answers: putting the sound back in
    /// step is free when nobody has moved anything, and destructive the moment somebody
    /// has. Identity is deliberately ignored — a run that was detached and never touched
    /// carries a fresh `id`, and that is not an edit anyone made.
    public var detachedSoundIsInStepWithClips: Bool {
        guard let detachedSound else { return true }
        let expected = soundRunsFollowingClips
        guard detachedSound.count == expected.count else { return false }
        return zip(detachedSound, expected).allSatisfy {
            $0.start == $1.start && $0.duration == $1.duration
                && $0.sourceStart == $1.sourceStart && $0.speed == $1.speed
        }
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
        // Only when detached: an attached lane's edges are the clip cuts already above,
        // and adding them twice would make the snapping arithmetic do the same work twice.
        for run in detachedSound ?? [] { times.append(run.start); times.append(run.end) }
        for region in cursorRegions { times.append(region.start); times.append(region.end) }
        return times
    }
}
