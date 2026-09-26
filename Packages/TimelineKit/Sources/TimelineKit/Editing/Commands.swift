import CoreGraphics
import CoreMedia
import Foundation

/// The edits, one type each.
///
/// Small structs rather than an enum with a case per edit: a command carries exactly the
/// data its own edit needs, and adding one does not touch the others.
public enum Commands {
    public struct Split: TimelineCommand {
        public let time: CMTime
        public var name: String { "Split" }
        public init(at time: CMTime) { self.time = time }
        public func apply(to timeline: inout Timeline) -> Bool {
            ClipSequence.split(&timeline, at: time)
        }
    }

    public struct DeleteRange: TimelineCommand {
        public let range: CMTimeRange
        public var name: String { "Delete" }
        public init(_ range: CMTimeRange) { self.range = range }
        public func apply(to timeline: inout Timeline) -> Bool {
            ClipSequence.delete(&timeline, range: range)
        }
    }

    /// Putting footage back on the timeline: a paste, or a duplicate of a clip.
    ///
    /// The footage counterpart of `InsertRegion`, and one command rather than two for the
    /// same reason that one is: paste and duplicate are the same insertion, and the undo
    /// menu is the only place that has to tell them apart, so `name` is passed in.
    ///
    /// The footage arrives already freshened — new ids throughout, courtesy of
    /// `CopiedFootage.freshened()` — and still measured from its own start, because the
    /// insertion point is this command's argument rather than the payload's. That split is
    /// deliberate in the same way `InsertRegion`'s is: freshening in here would mean the
    /// command knew the ids of the clips it created and nobody else did, and the paste could
    /// not leave the footage it just inserted selected.
    ///
    /// One command, so one entry on the undo stack, however many clips and regions came
    /// along — and since `UndoStack` stores whole timelines, undoing it is one snapshot
    /// rather than an inverse that would have to remember what it displaced.
    public struct InsertFootage: TimelineCommand {
        public let footage: CopiedFootage
        public let time: CMTime
        public let name: String

        public init(_ footage: CopiedFootage, at time: CMTime, name: String) {
            self.footage = footage
            self.time = time
            self.name = name
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            ClipSequence.insert(&timeline, footage, at: time)
        }
    }

    public struct SetSpeed: TimelineCommand {
        public let range: CMTimeRange
        public let speed: Double
        /// Carry the zooms, blurs and captions along with the footage. On by default:
        /// leaving them behind desynchronises everything after the change.
        public let movesRegions: Bool
        public var name: String { speed > 1 ? "Speed Up" : "Slow Down" }
        public init(_ range: CMTimeRange, speed: Double, movesRegions: Bool = true) {
            self.range = range
            self.speed = speed
            self.movesRegions = movesRegions
        }
        public func apply(to timeline: inout Timeline) -> Bool {
            ClipSequence.setSpeed(&timeline, range: range, speed: speed, movesRegions: movesRegions)
        }
    }

    public struct TrimClip: TimelineCommand {
        public let clipID: UUID
        public let head: CMTime?
        public let tail: CMTime?
        /// See `SetSpeed.movesRegions`.
        public let movesRegions: Bool
        public var name: String { "Trim" }
        public init(clipID: UUID, head: CMTime? = nil, tail: CMTime? = nil, movesRegions: Bool = true) {
            self.clipID = clipID
            self.head = head
            self.tail = tail
            self.movesRegions = movesRegions
        }
        public func apply(to timeline: inout Timeline) -> Bool {
            ClipSequence.trim(&timeline, clipID: clipID, head: head, tail: tail, movesRegions: movesRegions)
        }
    }

    public struct MoveClip: TimelineCommand {
        public let from: Int
        public let to: Int
        public var name: String { "Move Clip" }
        public init(from: Int, to: Int) {
            self.from = from
            self.to = to
        }
        public func apply(to timeline: inout Timeline) -> Bool {
            ClipSequence.move(&timeline, from: from, to: to)
        }
    }

    public struct AddZoom: TimelineCommand {
        public let region: ZoomRegion
        public var name: String { "Add Zoom" }
        public init(_ region: ZoomRegion) { self.region = region }
        public func apply(to timeline: inout Timeline) -> Bool {
            guard region.duration >= Clip.minimumDuration, region.start < timeline.duration else { return false }
            timeline.zooms.append(region)
            timeline.zooms.sort { $0.start < $1.start }
            return true
        }
    }

    public struct AddZooms: TimelineCommand {
        public let regions: [ZoomRegion]
        public var name: String { "Add Zooms" }
        public init(_ regions: [ZoomRegion]) { self.regions = regions }
        public func apply(to timeline: inout Timeline) -> Bool {
            let usable = regions.filter { $0.duration >= Clip.minimumDuration && $0.start < timeline.duration }
            guard !usable.isEmpty else { return false }
            timeline.zooms.append(contentsOf: usable)
            timeline.zooms.sort { $0.start < $1.start }
            return true
        }
    }

    public struct AddBlur: TimelineCommand {
        public let region: BlurRegion
        public var name: String { "Add Blur" }
        public init(_ region: BlurRegion) { self.region = region }
        public func apply(to timeline: inout Timeline) -> Bool {
            timeline.blurs.append(region)
            return true
        }
    }

    /// A sound brought in from outside the recording: music, a voiceover.
    ///
    /// The file it names has already been copied into the project by the time this runs,
    /// so undoing leaves an unused file behind rather than breaking a redo. That is the
    /// same bargain the background import makes, and the same sweep cleans up after it.
    public struct AddAudio: TimelineCommand {
        public let region: AudioRegion
        /// What the undo entry says. Defaulted, because laying a sound down is what this
        /// command is; named, because a voiceover the user recorded here is not something
        /// they would recognise under "Undo Add Sound".
        public let name: String
        public init(_ region: AudioRegion, name: String = "Add Sound") {
            self.region = region
            self.name = name
        }
        public func apply(to timeline: inout Timeline) -> Bool {
            timeline.audio.append(region)
            return true
        }
    }

    /// Putting a region back on the timeline: a paste, or a duplicate.
    ///
    /// One command for both and for every kind, because the difference between them is
    /// entirely in the words on the undo stack and in the start time the caller worked
    /// out — the edit itself is the same append into the same lane. `name` is therefore
    /// passed in rather than derived: "Paste Zoom" and "Duplicate Zoom" are the same
    /// insertion, and the undo menu is the only place that has to tell them apart.
    ///
    /// The region arrives already placed — fresh `id`, start and duration clamped by
    /// `CopiedRegion.placed(at:in:)` — so this only has to refuse what it cannot hold.
    /// Doing the clamping here instead would mean the command knew the id of the region it
    /// created and nobody else did, and the paste could not leave its own copy selected.
    public struct InsertRegion: TimelineCommand {
        public let region: CopiedRegion
        public let name: String

        public init(_ region: CopiedRegion, name: String) {
            self.region = region
            self.name = name
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard region.duration >= Clip.minimumDuration, region.start < timeline.duration else { return false }
            switch region {
            case .zoom(let r):
                timeline.zooms.append(r)
                // Sorted for the same reason `AddZoom` sorts: the renderer sums zooms in
                // order, and a lane drawn out of order is a lane that flickers.
                timeline.zooms.sort { $0.start < $1.start }
            case .blur(let r):
                timeline.blurs.append(r)
            case .annotation(let r):
                timeline.annotations.append(r)
            case .caption(let r):
                timeline.captions.append(r)
                // `SetCaptions` keeps this invariant too: `captionAtPlayhead` takes the
                // last cue that contains the playhead, which is only the right one in a
                // sorted list.
                timeline.captions.sort { $0.start < $1.start }
            case .audio(let r):
                timeline.audio.append(r)
            case .cursor(let r):
                timeline.cursorRegions.append(r)
                // Sorted for the reason `AddCursorRegion` sorts: the lane is kept in
                // order so an inspector open on one region does not find itself pointing
                // at another after a paste.
                timeline.cursorRegions.sort { $0.start < $1.start }
            }
            return true
        }
    }

    /// A stretch where the pointer behaves differently: hidden, calmed, or held still.
    ///
    /// Refuses a region that would sit off the end of the edit or be too short to grab
    /// again, the same two conditions `AddZoom` refuses on — a chip nobody can see or
    /// reach is worse than no chip.
    public struct AddCursorRegion: TimelineCommand {
        public let region: CursorRegion
        public var name: String { region.isHidden ? "Hide Pointer" : "Pointer" }
        public init(_ region: CursorRegion) { self.region = region }
        public func apply(to timeline: inout Timeline) -> Bool {
            guard region.duration >= Clip.minimumDuration, region.start < timeline.duration else { return false }
            timeline.cursorRegions.append(region)
            timeline.cursorRegions.sort { $0.start < $1.start }
            return true
        }
    }

    /// Changing what a cursor region does to the pointer.
    ///
    /// By id rather than by index, unlike the zoom and blur inspectors: `AddCursorRegion`
    /// keeps the lane sorted by start, so dragging a region past its neighbour renumbers
    /// the array under an inspector that is still open on it.
    public struct RestyleCursorRegion: TimelineCommand {
        public let id: UUID
        public let change: @Sendable (inout CursorRegion) -> Void
        public let name: String

        public init(id: UUID, name: String, _ change: @escaping @Sendable (inout CursorRegion) -> Void) {
            self.id = id
            self.name = name
            self.change = change
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.cursorRegions.firstIndex(where: { $0.id == id }) else { return false }
            let before = timeline.cursorRegions[index]
            change(&timeline.cursorRegions[index])
            return timeline.cursorRegions[index] != before
        }
    }

    public struct AddAnnotation: TimelineCommand {
        public let item: AnnotationItem
        public var name: String { "Add Annotation" }
        public init(_ item: AnnotationItem) { self.item = item }
        public func apply(to timeline: inout Timeline) -> Bool {
            timeline.annotations.append(item)
            return true
        }
    }

    /// Replacing every caption at once.
    ///
    /// One command rather than one per cue, because that is what generating captions
    /// actually is: a recogniser produces a whole transcript, and undoing it has to take
    /// the whole transcript away rather than leaving the user pressing ⌘Z two hundred
    /// times.
    public struct SetCaptions: TimelineCommand {
        public let cues: [CaptionCue]
        public var name: String { cues.isEmpty ? "Clear Captions" : "Captions" }

        public init(_ cues: [CaptionCue]) { self.cues = cues }

        public func apply(to timeline: inout Timeline) -> Bool {
            let sorted = cues.sorted { $0.start < $1.start }
            guard timeline.captions != sorted else { return false }
            timeline.captions = sorted
            return true
        }
    }

    /// Changing what one caption says.
    public struct SetCaptionText: TimelineCommand {
        public let id: UUID
        public let text: String
        public var name: String { "Caption Text" }

        public init(id: UUID, text: String) {
            self.id = id
            self.text = text
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.captions.firstIndex(where: { $0.id == id }),
                  timeline.captions[index].text != text else { return false }
            timeline.captions[index].text = text
            return true
        }
    }

    /// Moving or resizing a blur or an annotation on the picture.
    ///
    /// One command for both kinds and for both gestures, for the same reason
    /// `MoveRegion` is one command: a drag that also grows the rectangle is still one
    /// thing the user did, and it belongs on the undo stack once.
    ///
    /// The two rectangles are in different spaces — a blur is normalised to the
    /// recording so it stays on the thing it covers when the camera moves, an annotation
    /// to the finished frame so it stays where it was put. That difference is the
    /// caller's to respect; this only stores what it is given.
    public struct SetRegionRect: TimelineCommand {
        public let id: UUID
        public let rect: CGRect
        public var name: String { "Move" }

        public init(id: UUID, rect: CGRect) {
            self.id = id
            self.rect = rect
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            let clamped = Self.clamped(rect)
            if let index = timeline.blurs.firstIndex(where: { $0.id == id }) {
                guard timeline.blurs[index].rect != clamped else { return false }
                timeline.blurs[index].rect = clamped
                return true
            }
            if let index = timeline.annotations.firstIndex(where: { $0.id == id }) {
                guard timeline.annotations[index].rect != clamped else { return false }
                timeline.annotations[index].rect = clamped
                return true
            }
            return false
        }

        /// Kept inside the frame and never smaller than something you can grab again.
        ///
        /// A rectangle dragged to nothing is not a small rectangle, it is one the user
        /// has lost — there is no handle left to pull it back out by.
        public static let minimumSide: CGFloat = 0.02

        static func clamped(_ rect: CGRect) -> CGRect {
            var rect = rect.standardized
            rect.size.width = min(1, max(minimumSide, rect.width))
            rect.size.height = min(1, max(minimumSide, rect.height))
            rect.origin.x = min(1 - rect.width, max(0, rect.minX))
            rect.origin.y = min(1 - rect.height, max(0, rect.minY))
            return rect
        }
    }

    /// Changing what an annotation says or how it looks.
    public struct RestyleAnnotation: TimelineCommand {
        public let id: UUID
        public let change: @Sendable (inout AnnotationItem) -> Void
        public let name: String

        public init(id: UUID, name: String, _ change: @escaping @Sendable (inout AnnotationItem) -> Void) {
            self.id = id
            self.name = name
            self.change = change
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.annotations.firstIndex(where: { $0.id == id }) else { return false }
            let before = timeline.annotations[index]
            change(&timeline.annotations[index])
            return timeline.annotations[index] != before
        }
    }

    // MARK: - The recording's own sound, on a lane of its own

    /// Cuts the recording's sound loose from the picture.
    ///
    /// An explicit, undoable act rather than something that happens the first time
    /// somebody drags the lane, because it changes what the lane *means*: before it, the
    /// sound is the picture's sound and the cuts are shared; after it, the two are separate
    /// edits that can disagree. A user has to be able to say "no, put that back", and
    /// Undo is how they say it.
    public struct DetachSound: TimelineCommand {
        public var name: String { "Detach Audio" }
        public init() {}
        public func apply(to timeline: inout Timeline) -> Bool {
            ClipSequence.detachSound(&timeline)
        }
    }

    /// Puts the recording's sound back in step with the picture.
    ///
    /// Destructive when the lane has been edited, which is why the caller asks
    /// `Timeline.detachedSoundIsInStepWithClips` first and says what is about to go. The
    /// command itself does not warn: one whose result depended on a dialogue would be one
    /// the undo stack cannot predict.
    public struct AttachSound: TimelineCommand {
        public var name: String { "Re-attach Audio" }
        public init() {}
        public func apply(to timeline: inout Timeline) -> Bool {
            ClipSequence.attachSound(&timeline)
        }
    }

    /// Dragging or trimming one run of the detached sound.
    ///
    /// Not `MoveRegion`, and the difference is the whole reason this exists. Moving a
    /// region means "put it somewhere else"; a run of the recording has a second thing
    /// attached to every edge — which second of the *recording* plays there. Dragging the
    /// body should slide the sound in time and go on playing the same words, so
    /// `sourceStart` is left alone. Dragging the left edge should trim, which means the
    /// words that survive have to stay exactly where they were: the in-point must advance
    /// by as much source as the edge crossed. Handing both to `MoveRegion` would make every
    /// head trim quietly re-cut the take, and the symptom — the sound sliding a few frames
    /// whenever you shortened it — is precisely what detaching was for.
    public struct MoveSoundRun: TimelineCommand {
        public let id: UUID
        public let start: CMTime
        public let duration: CMTime?
        /// Whether the recording should stay put underneath while the run's front edge
        /// moves. True for a head trim, false for a drag of the whole run.
        public let trimsHead: Bool
        public var name: String { duration == nil ? "Move Sound" : "Trim Sound" }

        public init(id: UUID, start: CMTime, duration: CMTime? = nil, trimsHead: Bool = false) {
            self.id = id
            self.start = start
            self.duration = duration
            self.trimsHead = trimsHead
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            // Read before the array is taken out, for the reason `MoveRegion` reads it
            // early: two accesses to one value at once is what Swift refuses.
            let end = timeline.duration
            guard var runs = timeline.detachedSound,
                  let index = runs.firstIndex(where: { $0.id == id }) else { return false }

            let before = runs[index]
            var run = before
            let settled = max(.zero, min(start, end - Clip.minimumDuration))
            if trimsHead {
                // Negative when the edge moved left, which reveals source trimmed off
                // earlier — clamped at the head of the recording, because there is nothing
                // before second zero to reveal.
                let crossed = CMTimeMultiplyByFloat64(settled - run.start, multiplier: run.speed)
                run.sourceStart = max(.zero, run.sourceStart + crossed)
            }
            run.start = settled
            if let duration {
                run.duration = max(Clip.minimumDuration, min(duration, end - run.start))
            } else if run.end > end {
                run.start = end - run.duration
            }
            guard run != before else { return false }
            runs[index] = run
            timeline.detachedSound = runs
            return true
        }
    }

    /// Deleting anything with an id, without a command per kind.
    public struct DeleteRegion: TimelineCommand {
        public let id: UUID
        public var name: String { "Delete" }
        public init(id: UUID) { self.id = id }
        public func apply(to timeline: inout Timeline) -> Bool {
            // An array rather than a tuple: the lanes outgrew the six a tuple will compare,
            // and counting them in a list that can be read down the page is clearer than
            // spelling the comparison out by hand.
            func counts(_ timeline: Timeline) -> [Int] {
                [timeline.zooms.count, timeline.blurs.count, timeline.annotations.count,
                 timeline.captions.count, timeline.audio.count, timeline.cursorRegions.count,
                 timeline.detachedSound?.count ?? 0]
            }

            let before = counts(timeline)
            timeline.zooms.removeAll { $0.id == id }
            timeline.blurs.removeAll { $0.id == id }
            timeline.annotations.removeAll { $0.id == id }
            timeline.captions.removeAll { $0.id == id }
            timeline.audio.removeAll { $0.id == id }
            // Only when detached: an attached lane has no runs to delete, and silencing the
            // recording's sound is `SoundStyle.isMuted`'s job rather than this one's.
            timeline.detachedSound?.removeAll { $0.id == id }
            timeline.cursorRegions.removeAll { $0.id == id }
            return before != counts(timeline)
        }
    }

    /// Dragging or resizing a region on the timeline.
    ///
    /// One command for both, because a drag that also hits a boundary is a resize, and
    /// two commands would put two entries on the undo stack for one gesture.
    public struct MoveRegion: TimelineCommand {
        public let id: UUID
        public let start: CMTime
        public let duration: CMTime?
        public var name: String { duration == nil ? "Move" : "Resize" }
        public init(id: UUID, start: CMTime, duration: CMTime? = nil) {
            self.id = id
            self.start = start
            self.duration = duration
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            // A locked zoom does not move. Checked here rather than in the timeline view
            // because this is the one door every drag and every resize comes through — the
            // lane, the keyboard, a nudge command somebody adds later — and a lock enforced
            // in a view is a lock the next caller forgets. Refusing by returning false is
            // the right shape for it as well: nothing lands on the undo stack, so a drag on
            // a locked zoom costs the user no undo to get back out of.
            if timeline.zooms.contains(where: { $0.id == id && $0.isLocked }) { return false }

            // The end of the timeline is read once, before anything is mutated: passing
            // `&timeline.zooms` while the closure still reads `timeline` is two accesses
            // to the same value at once, which Swift refuses for good reason.
            let end = timeline.duration

            func move<Region: TimelineRegion>(_ regions: inout [Region]) -> Bool {
                guard let index = regions.firstIndex(where: { $0.id == id }) else { return false }
                var region = regions[index]
                region.start = max(.zero, min(start, end - Clip.minimumDuration))
                if let duration {
                    region.duration = max(Clip.minimumDuration, min(duration, end - region.start))
                } else if region.end > end {
                    region.start = end - region.duration
                }
                guard region != regions[index] else { return false }
                regions[index] = region
                return true
            }

            return move(&timeline.zooms) || move(&timeline.blurs) || move(&timeline.annotations)
                || move(&timeline.captions) || move(&timeline.audio) || move(&timeline.cursorRegions)
        }
    }

    /// Choosing the part of the recording that is shown.
    ///
    /// A command of its own rather than a `Restyle`, because it is the one style change
    /// with a rule attached: a crop that takes nothing away is stored as *no crop*, so
    /// dragging a handle back to the edges leaves a document that is identical to one
    /// that was never cropped.
    public struct SetCrop: TimelineCommand {
        public let crop: CropRect?
        public var name: String { crop == nil ? "Reset Crop" : "Crop" }
        public init(_ crop: CropRect?) { self.crop = crop }
        public func apply(to timeline: inout Timeline) -> Bool {
            let settled = (crop?.isFull ?? true) ? nil : crop
            guard settled != timeline.style.crop else { return false }
            timeline.style.crop = settled
            return true
        }
    }

    /// Everything on the style sidebar: background, padding, cursor, webcam.
    ///
    /// Takes a closure rather than a property path per setting, so a new setting needs no
    /// new command — the name is what the undo menu shows.
    public struct Restyle: TimelineCommand {
        public let name: String
        private let change: @Sendable (inout Timeline) -> Void
        public init(_ name: String, _ change: @escaping @Sendable (inout Timeline) -> Void) {
            self.name = name
            self.change = change
        }
        public func apply(to timeline: inout Timeline) -> Bool {
            let before = timeline
            change(&timeline)
            return timeline != before
        }
    }

    // MARK: - The second pass over a take

    /// Changing what one zoom does, by id.
    ///
    /// By id rather than by index, for the reason `RestyleCursorRegion` is: the zoom lane is
    /// kept sorted by start, so a split, a merge or a drag past a neighbour renumbers the
    /// array under an inspector that is still open on one of them. The zoom inspector's
    /// sliders predate that and still work by index, which is only safe because a slider
    /// cannot move a region; several of the things added here can.
    ///
    /// Deliberately does *not* refuse a locked zoom. The lock exists to stop a drag and a
    /// suggestion run, both of which happen to a zoom rather than being aimed at it — while
    /// this only ever runs from a control somebody pointed at, beside the padlock they
    /// pointed at first.
    public struct RestyleZoom: TimelineCommand {
        public let id: UUID
        public let change: @Sendable (inout ZoomRegion) -> Void
        public let name: String

        public init(id: UUID, name: String, _ change: @escaping @Sendable (inout ZoomRegion) -> Void) {
            self.id = id
            self.name = name
            self.change = change
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.zooms.firstIndex(where: { $0.id == id }) else { return false }
            let before = timeline.zooms[index]
            change(&timeline.zooms[index])
            guard timeline.zooms[index] != before else { return false }
            // A change may have moved the region — aiming one cannot, but a caller that sets
            // a start could — and the lane's order is an invariant rather than a convention.
            timeline.zooms.sort { $0.start < $1.start }
            return true
        }
    }

    /// One zoom cut in two at a time, so the halves can be aimed apart.
    ///
    /// The arithmetic is `ZoomLane.split`, including why the two halves have no ramp where
    /// they meet. This only finds the region and keeps the lane in order.
    ///
    /// Allowed on a locked zoom: splitting is something the user aims at one region from a
    /// menu, and the lock is there for the accidents.
    public struct SplitZoom: TimelineCommand {
        public let id: UUID
        public let time: CMTime
        public var name: String { "Split Zoom" }

        public init(id: UUID, at time: CMTime) {
            self.id = id
            self.time = time
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.zooms.firstIndex(where: { $0.id == id }),
                  let (first, second) = ZoomLane.split(timeline.zooms[index], at: time) else { return false }
            timeline.zooms[index] = first
            timeline.zooms.insert(second, at: index + 1)
            return true
        }
    }

    /// Two zooms as one, keeping the earlier one's identity.
    ///
    /// The earlier id survives so a selection or an open inspector lands on a region that is
    /// still there; `ZoomLane.merge` says what the result keeps, and why it is exactly the
    /// inverse of a split.
    public struct MergeZooms: TimelineCommand {
        public let first: UUID
        public let second: UUID
        public var name: String { "Merge Zooms" }

        public init(_ first: UUID, _ second: UUID) {
            self.first = first
            self.second = second
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let a = timeline.zooms.first(where: { $0.id == first }),
                  let b = timeline.zooms.first(where: { $0.id == second }),
                  let merged = ZoomLane.merge(a, b) else { return false }
            timeline.zooms.removeAll { $0.id == first || $0.id == second }
            timeline.zooms.append(merged)
            timeline.zooms.sort { $0.start < $1.start }
            return true
        }
    }

    /// The result of an auto-zoom run, reconciled with what is already on the lane.
    ///
    /// Not `AddZooms`, which appends: a *re-run* has to leave the user's zooms alone and
    /// replace the previous run's rather than doubling it. `ZoomLane.reconciled` is the rule,
    /// and it is worth reading before changing this — the failure it prevents is silent.
    ///
    /// `AddZooms` stays: it is still the right command for anything that genuinely means
    /// "add these zooms to the lane".
    public struct SuggestZooms: TimelineCommand {
        public let regions: [ZoomRegion]
        public var name: String { "Auto-Zoom" }

        public init(_ regions: [ZoomRegion]) { self.regions = regions }

        public func apply(to timeline: inout Timeline) -> Bool {
            let settled = ZoomLane.reconciled(regions, with: timeline.zooms, duration: timeline.duration)
            guard settled != timeline.zooms else { return false }
            timeline.zooms = settled
            return true
        }
    }
}
