import CoreMedia
import Foundation

/// A stretch of footage lifted off the timeline, on its way somewhere else.
///
/// The other half of `CopiedRegion`, and a separate type rather than a seventh case on it
/// for a reason that is structural rather than tidy: every member of `CopiedRegion` is
/// *one* region with *one* id, one `Selection` that points at it, and one lane to append it
/// to — and footage is none of those things. It is a run of clips, the regions that lived
/// only over them, and the sound that was playing: a small timeline rather than an object
/// on one. Folding it into that enum would have made `id`, `selection` and
/// `placed(at:in:)` lie for one case out of seven, which is where the next reader gets hurt.
///
/// Pasting one is `ClipSequence.insert`, because pasting footage means inserting *time*:
/// the sequence grows, and every region after the insertion point has to travel with the
/// footage it was placed against. That arithmetic belongs beside the arithmetic it is the
/// inverse of, not inside a clipboard payload.
///
/// # What travels with the footage
///
/// The judgement call at the centre of the feature, so it is written down here rather than
/// left to be inferred from the code.
///
/// **A region travels if and only if it lies wholly within the copied stretch.** A zoom,
/// blur, annotation, caption or pointer region sitting entirely over the copied frames is a
/// statement *about those frames* — somebody chose a scale, an aim and a length against
/// what happens there — and footage pasted without it looks nothing like the thing the user
/// selected, which makes ⌘C ⌘V read as broken rather than as conservative.
///
/// **A region straddling either edge of the stretch is left behind entirely**, and that is
/// the interesting half of the rule. Such a region is a statement about the copied footage
/// *and* about its neighbour, so neither answer is free: clipping it to the selection
/// invents an edit nobody made (a four-second push-in arriving as a one-second one is a
/// different push-in), and taking it whole pastes a length of effect that was never
/// selected. Leaving it keeps the copy describable in one sentence — "the frames, and the
/// things that live only there" — which is the rule a user can predict from the chips they
/// can see on the lanes.
///
/// **Imported sounds follow the same rule**, even though a music bed is arguably not part
/// of any particular footage. A sound effect dropped onto a gesture *is* part of that
/// gesture; a bed running under the whole take straddles both edges and stays behind. One
/// rule across six lanes beats a seventh special case for the user to learn. Their files are
/// the paster's problem rather than this type's: an `AudioRegion.path` is relative to *its*
/// project package, so a sound pasted into another project names a file that is not there —
/// see `withoutSounds(where:)`.
///
/// **The recording's own sound is clipped rather than dropped**, which is the one place the
/// rule bends, and it bends because a sound run is footage rather than a statement about
/// footage. A `SoundRun` carries `sourceStart` and `speed`, so a run cut down to the copied
/// stretch plays *exactly* the sound that was over the copied frames — no invention at all,
/// unlike a shortened zoom. Dropping it would make copying a range out of a detached lane
/// produce silence, which is a worse answer than the true one.
public struct CopiedFootage: Equatable, Sendable {
    /// The clips, in order, each one's position implied by the lengths before it — the same
    /// contiguous-by-construction bargain `Timeline.clips` makes, held to here so a payload
    /// cannot describe a gap the timeline has no way to represent.
    public var clips: [Clip]
    /// The regions that lived only over this stretch, with `start` measured from the
    /// beginning of the copy rather than of the timeline. Relative, because the whole point
    /// of a copy is that it lands somewhere else.
    public var zooms: [ZoomRegion]
    public var blurs: [BlurRegion]
    public var annotations: [AnnotationItem]
    public var captions: [CaptionCue]
    public var audio: [AudioRegion]
    public var cursorRegions: [CursorRegion]
    /// The recording's own sound over this stretch — always, whether or not the lane it was
    /// lifted from had been detached.
    ///
    /// Carried even when the source timeline's sound followed its picture, because the
    /// *destination* may be detached, and a detached lane is the whole truth about the
    /// sound there: clips inserted into one are silent unless something lays runs down for
    /// them. So a copy always knows what it sounded like, and the paste decides whether that
    /// answer is needed — an attached destination ignores it, because there the clips
    /// already say it.
    public var soundRuns: [SoundRun]
    /// How long the recording these clips are cut from was.
    ///
    /// Carried so a paste can refuse footage naming source this project does not have. A
    /// length is a weak identity for a recording — two different takes of equal length pass
    /// — and the honest fix is an identity on the recording itself, which `Timeline` has
    /// not got yet. Until it does, this catches the case that actually happens: footage
    /// copied out of a long take and pasted into a short one, where the clips would point
    /// past the end of the file and play nothing at all.
    public var sourceDuration: CMTime

    public init(clips: [Clip],
                zooms: [ZoomRegion] = [],
                blurs: [BlurRegion] = [],
                annotations: [AnnotationItem] = [],
                captions: [CaptionCue] = [],
                audio: [AudioRegion] = [],
                cursorRegions: [CursorRegion] = [],
                soundRuns: [SoundRun] = [],
                sourceDuration: CMTime) {
        self.clips = clips
        self.zooms = zooms
        self.blurs = blurs
        self.annotations = annotations
        self.captions = captions
        self.audio = audio
        self.cursorRegions = cursorRegions
        self.soundRuns = soundRuns
        self.sourceDuration = sourceDuration
    }

    // MARK: - Lifting it off the timeline

    /// Reads whatever the selection points at, if it points at footage.
    ///
    /// `nil` for everything `CopiedRegion` handles, which is the same division read from the
    /// other side: exactly one of the two initialisers answers any given selection, and the
    /// editor asks both. The trim handles are footage in one sense and are still refused —
    /// they select the frames a trim took *away*, which are not on the timeline to copy.
    public init?(_ selection: Selection, in timeline: Timeline) {
        switch selection {
        case .clip, .range:
            guard let range = selection.range(in: timeline) else { return nil }
            self.init(range, in: timeline)
        case .none, .zoom, .blur, .annotation, .caption, .audio, .cursorRegion,
             .sound, .soundTrack, .soundRun, .headTrim, .tailTrim:
            return nil
        }
    }

    /// Lifts a stretch of the timeline, without changing the timeline.
    ///
    /// Performed on a *copy* that has been cut at both ends, which is how the clips come out
    /// describing the range exactly rather than approximately: the same two `split` calls
    /// `delete` makes, so a copy and a ripple delete of one stretch always see the same
    /// clips. Where a cut is refused because it would leave a sliver shorter than
    /// `Clip.minimumDuration`, the copy is the whole clips that fit and the payload's own
    /// `duration` says how much that came to — nothing downstream re-derives a length from
    /// the range that was asked for.
    public init?(_ range: CMTimeRange, in timeline: Timeline) {
        var cut = timeline
        let wanted = max(.zero, range.start)
        let wantedEnd = min(timeline.duration, range.end)
        guard wantedEnd - wanted >= Clip.minimumDuration else { return nil }

        ClipSequence.split(&cut, at: wanted)
        ClipSequence.split(&cut, at: wantedEnd)

        var lifted: [Clip] = []
        var liftedStart: CMTime?
        var elapsed = CMTime.zero
        for clip in cut.clips {
            let clipEnd = elapsed + clip.duration
            if elapsed >= wanted, clipEnd <= wantedEnd {
                if liftedStart == nil { liftedStart = elapsed }
                lifted.append(clip)
            }
            elapsed = clipEnd
        }
        guard !lifted.isEmpty, let start = liftedStart else { return nil }
        let end = start + lifted.reduce(CMTime.zero) { $0 + $1.duration }

        /// Wholly inside, rebased to the start of the copy. The rule the doc comment argues
        /// for, written once and read over all six lanes.
        func lift<Region: TimelineRegion>(_ regions: [Region]) -> [Region] {
            regions.compactMap { region in
                guard region.start >= start, region.end <= end else { return nil }
                var region = region
                region.start = region.start - start
                return region
            }
        }

        let runs: [SoundRun]
        if let detached = cut.detachedSound {
            // Clipped rather than dropped — see the note on `soundRuns` for why sound is
            // the exception. `sourceTime(atOffset:)` is what keeps the words where they
            // were: a run cut at its front has to advance its in-point by the source the
            // cut part consumed, or the copy plays the right length of the wrong moment.
            runs = detached.compactMap { run in
                let from = max(run.start, start)
                let to = min(run.end, end)
                guard to - from >= Clip.minimumDuration else { return nil }
                return SoundRun(start: from - start,
                                duration: to - from,
                                sourceStart: run.sourceTime(atOffset: from - run.start),
                                speed: run.speed)
            }
        } else {
            // The lane the source did not have, built exactly the way detaching would have
            // built it: one run per clip, at the clip's own speed. That is
            // `Timeline.soundRunsFollowingClips`' rule read over a sub-range of the clips
            // rather than over all of them, which is why it is spelled out rather than
            // called — the property has no sub-range form, and giving it one would mean a
            // second way to ask the same question.
            var following: [SoundRun] = []
            following.reserveCapacity(lifted.count)
            var playhead = CMTime.zero
            for clip in lifted {
                following.append(SoundRun(start: playhead,
                                          duration: clip.duration,
                                          sourceStart: clip.sourceStart,
                                          speed: clip.speed))
                playhead = playhead + clip.duration
            }
            runs = following
        }

        self.init(clips: lifted,
                  zooms: lift(cut.zooms),
                  blurs: lift(cut.blurs),
                  annotations: lift(cut.annotations),
                  captions: lift(cut.captions),
                  audio: lift(cut.audio),
                  cursorRegions: lift(cut.cursorRegions),
                  soundRuns: runs,
                  sourceDuration: timeline.sourceDuration)
    }

    // MARK: - What it is

    /// How much time pasting this would insert.
    ///
    /// Derived from the clips and never stored, for the reason `Timeline.duration` is
    /// derived: two answers to one question is one answer too many.
    public var duration: CMTime {
        clips.reduce(CMTime.zero) { $0 + $1.duration }
    }

    public var isEmpty: Bool { clips.isEmpty }

    /// The furthest into the recording any of these clips reaches, which is what a paste
    /// measures against the destination's `sourceDuration`.
    public var sourceEnd: CMTime {
        clips.reduce(CMTime.zero) { max($0, $1.sourceEnd) }
    }

    /// What the menu and the undo stack call it.
    ///
    /// "Footage" rather than "Clip", and rather than a count: a copied range is usually
    /// several clips and sometimes one, and an undo entry whose wording changes with the
    /// number of cuts that happened to fall inside the selection is one nobody can learn.
    public var title: String { "Footage" }

    /// How many regions came along, for the sentence a paste can show. Zero when nothing
    /// but picture and sound travelled.
    public var carried: Int {
        zooms.count + blurs.count + annotations.count + captions.count
            + audio.count + cursorRegions.count
    }

    // MARK: - Where it lands

    /// The same footage with new identities throughout.
    ///
    /// Every clip and every region gets a fresh `id`, for the reason
    /// `CopiedRegion.placed(at:in:)` gives: two things in one document sharing an id is a
    /// document where selecting, moving and deleting all pick the wrong one. Done on the way
    /// *out* of the clipboard rather than on the way in, so pasting one copy twice produces
    /// two independent stretches rather than two aliases of one.
    ///
    /// Positions stay relative — `ClipSequence.insert` is what knows where the paste landed
    /// — but the caller gets the new ids back, which is how a paste can leave the footage it
    /// just inserted selected.
    ///
    /// Two fields are deliberately dropped from a zoom, exactly as a region paste drops
    /// them: a seam ramp only means anything beside the region it was cut from, and a copy
    /// arrives unlocked because the first thing anybody does with one is drag it.
    public func freshened() -> CopiedFootage {
        CopiedFootage(
            clips: clips.map {
                Clip(sourceStart: $0.sourceStart, sourceDuration: $0.sourceDuration, speed: $0.speed)
            },
            zooms: zooms.map {
                ZoomRegion(start: $0.start, duration: $0.duration, scale: $0.scale,
                           center: $0.center, easing: $0.easing, transition: $0.transition,
                           followsCursor: $0.followsCursor, source: $0.source)
            },
            blurs: blurs.map {
                BlurRegion(start: $0.start, duration: $0.duration,
                           rect: $0.rect, style: $0.style, radius: $0.radius)
            },
            annotations: annotations.map {
                AnnotationItem(start: $0.start, duration: $0.duration, kind: $0.kind,
                               rect: $0.rect, color: $0.color, fontSize: $0.fontSize)
            },
            captions: captions.map {
                CaptionCue(start: $0.start, duration: $0.duration, text: $0.text)
            },
            audio: audio.map {
                AudioRegion(start: $0.start, duration: $0.duration, path: $0.path,
                            gain: $0.gain, sourceStart: $0.sourceStart)
            },
            cursorRegions: cursorRegions.map {
                CursorRegion(start: $0.start, duration: $0.duration, isHidden: $0.isHidden,
                             smoothing: $0.smoothing, isHeld: $0.isHeld, transition: $0.transition)
            },
            soundRuns: soundRuns.map {
                SoundRun(start: $0.start, duration: $0.duration,
                         sourceStart: $0.sourceStart, speed: $0.speed)
            },
            sourceDuration: sourceDuration)
    }

    /// The same footage with the sounds this project cannot find taken out.
    ///
    /// Here rather than in the paster so the rule is testable without a filesystem: the
    /// caller supplies the predicate, this decides what a missing file costs. It costs the
    /// one region — the footage still pastes, and the picture is what the user asked for.
    /// Refusing a whole paste over a music cue would be the clipboard telling the user what
    /// they meant.
    public func withoutSounds(where isMissing: (String) -> Bool) -> CopiedFootage {
        var copy = self
        copy.audio = audio.filter { !isMissing($0.path) }
        return copy
    }

    // MARK: - Words for other apps

    /// A one-line description, for the plain text written alongside the real payload.
    ///
    /// The same bargain `CopiedRegion.summary` makes, for the same reason: a pasteboard
    /// carrying only a private type looks empty to every other app on the Mac, so ⌘C here
    /// and ⌘V into a bug report would appear to have failed. One-way — nothing parses it
    /// back — so the wording is free to improve whenever it reads better.
    public var summary: String {
        let length = String(format: "%.2fs", duration.seconds)
        let cuts = clips.count == 1 ? "1 clip" : "\(clips.count) clips"
        guard carried > 0 else { return "Klik footage · \(length) · \(cuts)" }
        return "Klik footage · \(length) · \(cuts) · \(carried) region\(carried == 1 ? "" : "s")"
    }
}

// MARK: - Crossing the pasteboard

extension CopiedFootage: Codable {
    /// Bumped if the shape of the envelope changes. Everything inside it already decodes
    /// field by field — `Clip`, `SoundRun`, and every region in `Regions.swift` — so this
    /// only has to describe the wrapper.
    public static let currentFormat = 1

    private enum CodingKeys: String, CodingKey {
        case formatVersion, kind, clips, zooms, blurs, annotations, captions
        case audio, cursorRegions, soundRuns, sourceDuration
    }

    /// A fixed discriminator in the payload, matching the `kind` string `CopiedRegion`
    /// writes, so a decoder handed the wrong one of the two refuses at the boundary instead
    /// of quietly producing an empty edit. Spelled out rather than derived from the type's
    /// name for the reason `CopiedRegion.Kind` is spelled out: renaming a Swift type must
    /// not make every copy an older build wrote unreadable.
    private static let kind = "footage"

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormat, forKey: .formatVersion)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(clips, forKey: .clips)
        try container.encode(zooms, forKey: .zooms)
        try container.encode(blurs, forKey: .blurs)
        try container.encode(annotations, forKey: .annotations)
        try container.encode(captions, forKey: .captions)
        try container.encode(audio, forKey: .audio)
        try container.encode(cursorRegions, forKey: .cursorRegions)
        try container.encode(soundRuns, forKey: .soundRuns)
        try container.encode(sourceDuration, forKey: .sourceDuration)
    }

    /// Field by field, the way `Timeline.init(from:)` reads a project, and for the same
    /// reason: a lane written by a newer build — or hand-edited into nonsense — should cost
    /// the user that lane, not the whole paste. The two things a paste cannot proceed
    /// without are the kind and the clips, so those two are the only ones that throw.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == Self.kind else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                   debugDescription: "not copied footage")
        }
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        let clips = try container.decode([Clip].self, forKey: .clips)
        guard !clips.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .clips, in: container,
                                                   debugDescription: "footage with no clips")
        }
        self.init(clips: clips,
                  zooms: value(.zooms, default: []),
                  blurs: value(.blurs, default: []),
                  annotations: value(.annotations, default: []),
                  captions: value(.captions, default: []),
                  audio: value(.audio, default: []),
                  cursorRegions: value(.cursorRegions, default: []),
                  soundRuns: value(.soundRuns, default: []),
                  sourceDuration: value(.sourceDuration, default: .zero))
    }

    /// The bytes to put on the pasteboard.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Whatever was on the pasteboard, if it was footage.
    ///
    /// Optional rather than throwing, for the reason `CopiedRegion.decoded(from:)` is: every
    /// caller treats "not something this build understands" exactly as it treats an empty
    /// pasteboard, and nothing here trusts a length, an index or a range read out of the
    /// payload — which is what keeps rubbish from becoming a crash.
    public static func decoded(from data: Data) -> CopiedFootage? {
        try? JSONDecoder().decode(CopiedFootage.self, from: data)
    }
}
