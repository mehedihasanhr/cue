import CoreMedia

/// A stretch of the edit that would be better faster.
public struct PaceSuggestion: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// Nothing happening: the pointer still, the screen still, nobody speaking.
        case idle
        /// Somebody typing, and not talking over it.
        case typing
    }

    public let range: CMTimeRange
    public let reason: Reason
    public let speed: Double

    /// How much shorter the edit gets.
    public var saving: Double { range.duration.seconds * (1 - 1 / speed) }
}

/// Finds the waiting in a recording.
///
/// Every screen recording has it: the page loading, the build running, the sentence being
/// typed. Nobody watching wants to sit through it at the speed it happened, and nobody
/// editing wants to hunt for it. So it is found from what was recorded, and offered — never
/// applied without being asked.
///
/// Everything is measured on the timeline, after the edit's own cuts and speeds, and a
/// stretch that is already faster than real time is left alone.
public enum PaceSuggester {
    public struct Tuning: Equatable, Sendable {
        /// A still stretch shorter than this is a pause, not a wait.
        public var shortestIdle = 2.5
        /// Typing shorter than this is a word, not a paragraph.
        public var shortestTyping = 2.0
        /// Kept at full speed on each side, so the moment before and after is seen as it
        /// happened.
        public var margin = 0.4
        public var idleSpeed = 4.0
        public var typingSpeed = 2.5

        public init() {}
    }

    /// - Parameters:
    ///   - pointer: when the pointer was moving or clicking, in recording seconds.
    ///   - screen: when the picture was changing, in recording seconds.
    ///   - typing: bursts of typing, in recording seconds.
    ///   - speech: when somebody is speaking, on the timeline (the captions' words).
    public static func suggestions(timeline: Timeline,
                                   pointer: [ClosedRange<Double>],
                                   screen: [ClosedRange<Double>],
                                   typing: [ClosedRange<Double>],
                                   speech: [CMTimeRange],
                                   tuning: Tuning = Tuning()) -> [PaceSuggestion] {
        let end = timeline.duration
        guard end > .zero else { return [] }
        let onTimeline = { (ranges: [ClosedRange<Double>]) in ranges.flatMap { timeline.timelineRanges(ofSource: $0) } }
        // Title slides, freeze frames and movies brought in are left out along with what
        // is already sped up. Nothing was recorded over them, so they read as still time —
        // but a title is still on purpose, a freeze frame is a pause somebody made, and a
        // movie's own activity was never measured. `setSpeed` will not speed a hold up
        // either, so offering one promised a saving the edit could never make.
        let spedUp = spedUpRanges(in: timeline) + unmeasuredRanges(in: timeline)
        let margin = CMTime(seconds: tuning.margin, preferredTimescale: 60_000)

        // Idle: whatever is left when everything busy is taken away.
        let busy = TranscriptEditing.joined(onTimeline(pointer) + onTimeline(screen) + onTimeline(typing) + speech + spedUp)
        var idle: [PaceSuggestion] = []
        var cursor = CMTime.zero
        for range in busy + [CMTimeRange(start: end, duration: .zero)] {
            let gap = CMTimeRange(start: cursor, end: max(cursor, min(range.start, end)))
            cursor = max(cursor, range.end)
            // Not shrunk at the very start or end of the edit: there is no action there to
            // show at its own speed.
            let from = gap.start == .zero ? gap.start : gap.start + margin
            let to = gap.end == end ? gap.end : gap.end - margin
            guard to > from, (to - from).seconds >= tuning.shortestIdle else { continue }
            idle.append(PaceSuggestion(range: CMTimeRange(start: from, end: to), reason: .idle, speed: tuning.idleSpeed))
        }

        // Typing, where nobody is talking over it and nothing is already sped up.
        let quiet = TranscriptEditing.joined(speech + spedUp)
        let typed = TranscriptEditing.joined(onTimeline(typing)).flatMap { subtract(quiet, from: $0) }
        let typingSuggestions = typed.compactMap { range -> PaceSuggestion? in
            guard range.duration.seconds >= tuning.shortestTyping else { return nil }
            return PaceSuggestion(range: range, reason: .typing, speed: tuning.typingSpeed)
        }

        return (idle + typingSuggestions).sorted { $0.range.start < $1.range.start }
    }

    /// The stretches the edit already plays faster or slower than they happened.
    static func spedUpRanges(in timeline: Timeline) -> [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        var elapsed = CMTime.zero
        for clip in timeline.clips {
            if clip.speed != 1 { ranges.append(CMTimeRange(start: elapsed, duration: clip.duration)) }
            elapsed = elapsed + clip.duration
        }
        return ranges
    }

    /// The clips that do not play the recording: holds, titles and imported movies.
    static func unmeasuredRanges(in timeline: Timeline) -> [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        var elapsed = CMTime.zero
        for clip in timeline.clips {
            if !clip.isFootage || clip.source != nil {
                ranges.append(CMTimeRange(start: elapsed, duration: clip.duration))
            }
            elapsed = elapsed + clip.duration
        }
        return ranges
    }

    /// What is left of a range once some others are taken out of it.
    static func subtract(_ others: [CMTimeRange], from range: CMTimeRange) -> [CMTimeRange] {
        var pieces = [range]
        for other in others {
            pieces = pieces.flatMap { piece -> [CMTimeRange] in
                let overlap = piece.intersection(other)
                guard !overlap.isEmpty else { return [piece] }
                var kept: [CMTimeRange] = []
                if overlap.start > piece.start { kept.append(CMTimeRange(start: piece.start, end: overlap.start)) }
                if overlap.end < piece.end { kept.append(CMTimeRange(start: overlap.end, end: piece.end)) }
                return kept
            }
        }
        return pieces
    }
}

extension Commands {
    /// Several stretches set to their own speeds, as one edit.
    ///
    /// Applied from the last to the first, so each is where it was measured: a speed
    /// change moves everything after it.
    public struct SetSpeeds: TimelineCommand {
        public let changes: [(range: CMTimeRange, speed: Double)]
        public let name: String

        public init(_ changes: [(range: CMTimeRange, speed: Double)], name: String) {
            self.changes = changes
            self.name = name
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            var changed = false
            for change in changes.sorted(by: { $0.range.start > $1.range.start }) {
                changed = ClipSequence.setSpeed(&timeline, range: change.range, speed: change.speed) || changed
            }
            return changed
        }
    }
}
