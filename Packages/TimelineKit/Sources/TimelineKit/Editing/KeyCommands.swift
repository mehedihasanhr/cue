import CoreMedia
import Foundation
import RecordKit

public extension Commands {
    /// A press put on the lane by hand — for a shortcut the recorder could not see, or a
    /// recording made before keys were recorded at all.
    ///
    /// Refuses a region that would sit off the end of the edit or be too short to grab
    /// again, the same two conditions `AddZoom` refuses on.
    struct AddKeyCue: TimelineCommand {
        public let cue: KeyCue
        public var name: String { "Add Shortcut" }
        public init(_ cue: KeyCue) { self.cue = cue }
        public func apply(to timeline: inout Timeline) -> Bool {
            guard cue.duration >= Clip.minimumDuration, cue.start < timeline.duration else { return false }
            timeline.keyCues.append(cue)
            timeline.keyCues.sort { $0.start < $1.start }
            return true
        }
    }

    /// Changing what one cue says or whether it is shown, by id.
    ///
    /// By id rather than by index, for the reason `RestyleCursorRegion` is: the lane is
    /// kept sorted by start, so a drag past a neighbour renumbers the array under an
    /// inspector that is still open on one of them.
    struct RestyleKeyCue: TimelineCommand {
        public let id: UUID
        public let change: @Sendable (inout KeyCue) -> Void
        public let name: String

        public init(id: UUID, name: String, _ change: @escaping @Sendable (inout KeyCue) -> Void) {
            self.id = id
            self.name = name
            self.change = change
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.keyCues.firstIndex(where: { $0.id == id }) else { return false }
            let before = timeline.keyCues[index]
            change(&timeline.keyCues[index])
            timeline.keyCues[index].sanitise()
            guard timeline.keyCues[index] != before else { return false }
            timeline.keyCues.sort { $0.start < $1.start }
            return true
        }
    }

    /// Replacing every cue at once.
    ///
    /// One command rather than one per cue, for the reason `SetCaptions` is one: the
    /// recording's presses are one thing the user asked to have back, and taking them
    /// away again should not be two hundred presses of ⌘Z. Empty is "Remove All".
    struct SetKeyCues: TimelineCommand {
        public let cues: [KeyCue]
        public let name: String

        public init(_ cues: [KeyCue], name: String) {
            self.cues = cues
            self.name = name
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            let sorted = cues.sorted { $0.start < $1.start }
            guard timeline.keyCues != sorted else { return false }
            timeline.keyCues = sorted
            return true
        }
    }
}

public extension EditorDocument {
    /// The presses in the recording, as cues on this edit.
    ///
    /// Empty for a recording with no key telemetry, which is one made with the setting
    /// off, one made without the Accessibility grant, and every recording made before
    /// keys could be recorded. `manifest.telemetry.keys` tells those apart.
    func recordedKeyCues() -> [KeyCue] {
        KeyCueBuilder().cues(from: inputSamples, in: timeline)
    }

    /// The cues a recording opens with, as where it starts rather than as an edit.
    ///
    /// The same bargain the suggested zooms make on open — see `adopt(_:)`: a recording
    /// that has only been opened must not be a recording with unsaved changes. Only for a
    /// project nobody has edited, and only while the lane is empty: a project saved with
    /// its shortcuts taken out is one whose shortcuts were taken out on purpose.
    func adoptRecordedKeys() {
        guard !hasBeenEdited, timeline.keyCues.isEmpty else { return }
        let cues = recordedKeyCues()
        guard !cues.isEmpty else { return }
        var opened = timeline
        opened.keyCues = cues
        adopt(opened)
    }
}
