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
        public var name: String { "Add Sound" }
        public init(_ region: AudioRegion) { self.region = region }
        public func apply(to timeline: inout Timeline) -> Bool {
            timeline.audio.append(region)
            return true
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

    /// Deleting anything with an id, without a command per kind.
    public struct DeleteRegion: TimelineCommand {
        public let id: UUID
        public var name: String { "Delete" }
        public init(id: UUID) { self.id = id }
        public func apply(to timeline: inout Timeline) -> Bool {
            let before = (timeline.zooms.count, timeline.blurs.count,
                          timeline.annotations.count, timeline.captions.count, timeline.audio.count)
            timeline.zooms.removeAll { $0.id == id }
            timeline.blurs.removeAll { $0.id == id }
            timeline.annotations.removeAll { $0.id == id }
            timeline.captions.removeAll { $0.id == id }
            timeline.audio.removeAll { $0.id == id }
            return before != (timeline.zooms.count, timeline.blurs.count,
                              timeline.annotations.count, timeline.captions.count, timeline.audio.count)
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
                || move(&timeline.captions) || move(&timeline.audio)
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
}
