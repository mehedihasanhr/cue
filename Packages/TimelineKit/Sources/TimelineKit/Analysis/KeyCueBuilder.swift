import CoreMedia
import Foundation
import RecordKit

/// Turns the recorded key presses into cues on the Keys lane.
///
/// A pure function over the sidecar, like `ZoomSuggester`, so it can be re-run against an
/// edited timeline and tested against a written-down take. Three rules:
///
/// 1. **A press shows for a moment** — `showFor`, about a second — and then goes.
/// 2. **The same keys pressed again within `repeatWithin` are one press that counts.**
///    ⌘Z ⌘Z ⌘Z is "⌘Z ×3", not three cues stepping on each other, and the moment lasts
///    `showFor` past the last of them.
/// 3. **A press that arrives while another is showing cuts the earlier one short.** Two
///    cues on screen at once would be two things to read.
///
/// The third rule has one exception, and it comes from the style. A named key on its own
/// — Return, an arrow — is drawn only when the project asks for those, so whether it is
/// "showing" is not known here. A shortcut always cuts what came before it; a lone named
/// key cuts only another lone named key. Where one follows a shortcut the two overlap in
/// the file, and `Timeline.keyCue(at:)` settles it frame by frame: the later one wins
/// while it is drawn at all, and the shortcut runs its full length when it is not.
public struct KeyCueBuilder: Sendable {
    public struct Tuning: Sendable {
        /// How long a press stays on screen.
        public var showFor: Double
        /// The same keys pressed again within this are one press that counts.
        public var repeatWithin: Double

        public init(showFor: Double = KeyCue.defaultDuration.seconds, repeatWithin: Double = 0.6) {
            self.showFor = showFor
            self.repeatWithin = repeatWithin
        }
    }

    public var tuning: Tuning

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// The cues for a recording's presses, on this edit's clock.
    ///
    /// Times in the sidecar are the recording's; a press inside footage the edit has cut
    /// away has no place on the lane, and one inside a sped-up clip lands where that
    /// footage now plays. Grouping happens *after* the mapping, in the edit's time,
    /// because that is the time the viewer experiences the gaps in.
    public func cues(from input: [InputSample], in timeline: Timeline) -> [KeyCue] {
        let presses = input.compactMap { sample -> Press? in
            guard case .shortcut(let t, let modifiers, let key) = sample, !key.isEmpty,
                  let placed = timeline.timelineTime(atSource: CMTime(seconds: t, preferredTimescale: 600))
            else { return nil }
            return Press(t: placed.seconds, modifiers: modifiers, key: key)
        }
        return cues(from: presses, duration: timeline.duration)
    }

    /// One press, already on the edit's clock.
    struct Press: Equatable, Sendable {
        var t: Double
        var modifiers: KeyModifiers
        var key: String

        var isAlone: Bool { modifiers.isDisjoint(with: .operating) && NamedKey(name: key) != nil }

        func sameKeys(as other: Press) -> Bool {
            modifiers == other.modifiers && key == other.key
        }
    }

    private struct Draft {
        var first: Press
        var start: Double
        var end: Double
        var lastPress: Double
        var count: Int
    }

    /// The grouping, on times that are already the edit's.
    func cues(from presses: [Press], duration: CMTime) -> [KeyCue] {
        let end = duration.seconds
        var drafts: [Draft] = []
        // Only the most recent of each kind can still be showing: each new one cuts the
        // last of its kind short, so there is never a third to consider.
        var lastShortcut: Int?
        var lastAlone: Int?

        func cut(_ index: Int?, at t: Double) {
            guard let index, drafts[index].end > t else { return }
            drafts[index].end = t
        }

        func continues(_ index: Int?, _ press: Press) -> Bool {
            guard let index else { return false }
            let draft = drafts[index]
            return draft.first.sameKeys(as: press) && press.t - draft.lastPress <= tuning.repeatWithin
        }

        for press in presses.sorted(by: { $0.t < $1.t }) where press.t >= 0 && press.t < end {
            if press.isAlone {
                if continues(lastAlone, press) {
                    drafts[lastAlone!].count += 1
                    drafts[lastAlone!].lastPress = press.t
                    drafts[lastAlone!].end = press.t + tuning.showFor
                } else {
                    cut(lastAlone, at: press.t)
                    drafts.append(Draft(first: press, start: press.t, end: press.t + tuning.showFor,
                                        lastPress: press.t, count: 1))
                    lastAlone = drafts.count - 1
                }
            } else if continues(lastShortcut, press) {
                drafts[lastShortcut!].count += 1
                drafts[lastShortcut!].lastPress = press.t
                drafts[lastShortcut!].end = press.t + tuning.showFor
                // A named key that came in between is over: the shortcut was pressed
                // again, and it is what the viewer should be reading.
                cut(lastAlone, at: press.t)
            } else {
                cut(lastShortcut, at: press.t)
                cut(lastAlone, at: press.t)
                drafts.append(Draft(first: press, start: press.t, end: press.t + tuning.showFor,
                                    lastPress: press.t, count: 1))
                lastShortcut = drafts.count - 1
                // A shortcut ends a run of a named key: the next Return is a new press.
                lastAlone = nil
            }
        }

        return drafts.compactMap { draft in
            // Each edge converted on its own and the length taken from the two, so that a
            // cue cut short ends on exactly the tick the next press starts on. A length
            // converted from a difference of seconds lands a tick short, and two chips
            // that should touch would not.
            let start = CMTime(seconds: draft.start, preferredTimescale: 600)
            let stop = min(CMTime(seconds: draft.end, preferredTimescale: 600), duration)
            let length = stop - start
            // Cut to less than a moment — two shortcuts a few frames apart — it could not
            // have been read, and a chip that short cannot be taken hold of.
            guard length >= Clip.minimumDuration else { return nil }
            return KeyCue(start: start,
                          duration: length,
                          modifiers: draft.first.modifiers,
                          key: draft.first.key,
                          count: draft.count)
        }
    }
}
