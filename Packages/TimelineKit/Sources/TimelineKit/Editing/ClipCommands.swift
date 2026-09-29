import CoreMedia
import Foundation

/// The edits that add clips which do not play the recording, and change how clips meet.
///
/// Beside `Commands` rather than inside that file, one struct each as there, for the same
/// reason: a command carries exactly what its own edit needs.
extension Commands {
    /// A still of the frame under a moment, put in at that moment.
    ///
    /// The id is chosen here, before the edit runs, so the editor can select the still it
    /// has just made. See `ClipSequence.freeze`.
    public struct FreezeFrame: TimelineCommand {
        public let time: CMTime
        public let length: CMTime
        public let id: UUID
        public var name: String { "Freeze Frame" }

        public init(at time: CMTime, for length: CMTime = Clip.defaultStillLength, id: UUID = UUID()) {
            self.time = time
            self.length = length
            self.id = id
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            ClipSequence.freeze(&timeline, at: time, for: length, id: id)
        }
    }

    /// A title slide, put in at a moment — the start, the end, or the playhead.
    public struct AddTitle: TimelineCommand {
        public let clip: Clip
        public let time: CMTime
        public var name: String { "Add Title Slide" }

        public init(_ card: TitleCard = TitleCard(), at time: CMTime, for length: CMTime = Clip.defaultTitleLength) {
            self.clip = .title(card, for: length)
            self.time = time
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            ClipSequence.insert(&timeline, clip: clip, at: time)
        }
    }

    /// How long a freeze frame or a title lasts. See `ClipSequence.setHold`.
    public struct SetHold: TimelineCommand {
        public let clipID: UUID
        public let length: CMTime
        public var name: String { "Change Length" }

        public init(clipID: UUID, to length: CMTime) {
            self.clipID = clipID
            self.length = length
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            ClipSequence.setHold(&timeline, clipID: clipID, to: length)
        }
    }

    /// Changing what a title slide says or how it looks, by the clip's id.
    ///
    /// A closure rather than a field per setting, for the reason `Restyle` takes one: a new
    /// setting on the card needs no new command, and the name is what the undo menu shows.
    /// Refused on a clip that is not a title, so a stale inspector cannot turn footage into
    /// one.
    public struct RestyleTitle: TimelineCommand {
        public let clipID: UUID
        public let name: String
        private let change: @Sendable (inout TitleCard) -> Void

        public init(clipID: UUID, _ name: String, _ change: @escaping @Sendable (inout TitleCard) -> Void) {
            self.clipID = clipID
            self.name = name
            self.change = change
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.clips.firstIndex(where: { $0.id == clipID }),
                  var card = timeline.clips[index].title else { return false }
            let before = card
            change(&card)
            guard card != before else { return false }
            timeline.clips[index].title = card
            return true
        }
    }

    /// How a clip arrives from the one before it. `nil` is a plain cut.
    public struct SetTransition: TimelineCommand {
        public let clipID: UUID
        public let transition: ClipTransition?
        public var name: String { transition == nil ? "Remove Transition" : "Transition" }

        public init(clipID: UUID, _ transition: ClipTransition?) {
            self.clipID = clipID
            self.transition = transition
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            ClipSequence.setTransition(&timeline, clipID: clipID, to: transition)
        }
    }
}
