import CoreMedia
import Foundation

/// Editing the video by what was said in it.
///
/// Every cut here is an ordinary cut — picture, sound and everything laid over them move
/// together — worked out from the captions' word timings. Only words the recogniser timed
/// are used: a line typed or corrected by hand has its words spread out by guesswork, and
/// cutting where a guess says an "um" was could cut a real word.
public enum TranscriptEditing {
    /// A word, and when it is heard on the timeline.
    public struct SpokenWord: Equatable, Sendable {
        public let text: String
        public let range: CMTimeRange
        public let cue: UUID
        /// Where in its line the word is, counting from nought.
        public var index: Int = 0

        /// Which word this is, for picking it out of a transcript.
        public var id: WordID { WordID(cue: cue, index: index) }
    }

    /// Sounds that are not words. Only these: "like", "so" and "you know" are words as
    /// often as they are fillers, and taking them out takes meaning out with them.
    public static let fillers: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhm", "erm", "er", "ah", "ahh", "hmm", "hm", "mm", "mmm",
        "mhmm", "huh", "uh-huh",
    ]

    /// The smallest cut worth making out of a pause: shortening one by less than this is
    /// a jump in the picture nobody would notice the time saved by.
    public static let smallestPauseCut = 0.2

    /// Every timed word in the captions, in the order it is heard.
    public static func spokenWords(in timeline: Timeline) -> [SpokenWord] {
        timeline.captions
            .filter { !$0.words.isEmpty && $0.words == $0.timedWords }
            .flatMap { cue -> [SpokenWord] in
                let seconds = cue.duration.seconds
                return cue.words.enumerated().map { index, word in
                    let from = cue.start + CMTime(seconds: word.from * seconds, preferredTimescale: 60_000)
                    let to = cue.start + CMTime(seconds: word.to * seconds, preferredTimescale: 60_000)
                    return SpokenWord(text: word.text, range: CMTimeRange(start: from, end: max(from, to)),
                                      cue: cue.id, index: index)
                }
            }
            .sorted { $0.range.start < $1.range.start }
    }

    static func isFiller(_ text: String) -> Bool {
        let bare = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return fillers.contains(bare)
    }

    /// Where the fillers are, touching ones joined into one stretch.
    public static func fillerRanges(in timeline: Timeline) -> [CMTimeRange] {
        joined(spokenWords(in: timeline).filter { isFiller($0.text) }.map(\.range))
    }

    /// The silences between words that are longer than `limit`, each cut down to `kept`.
    ///
    /// What is cut is the middle of the silence, so the pause that is left is split
    /// between the end of one sentence and the start of the next rather than all landing
    /// on one side. A silence in which the pointer is doing something is left alone: that
    /// is somebody showing rather than telling, and the silence is the demonstration.
    ///
    /// - Parameter busy: when the pointer was moving or clicking, on the timeline.
    public static func pauseRanges(in timeline: Timeline,
                                   longerThan limit: Double,
                                   keeping kept: Double,
                                   busy: [CMTimeRange] = []) -> [CMTimeRange] {
        let words = spokenWords(in: timeline)
        guard words.count > 1, limit > kept, kept >= 0 else { return [] }
        // A title slide, a freeze frame or an added movie between two lines is a silence
        // to the transcript, and one somebody put there. Shortened as a pause, the middle
        // of it — usually the whole slide — was cut out.
        let busy = busy + PaceSuggester.unmeasuredRanges(in: timeline)
        var cuts: [CMTimeRange] = []
        for (before, after) in zip(words, words.dropFirst()) {
            let gap = CMTimeRange(start: before.range.end, end: after.range.start)
            guard gap.duration.seconds > limit else { continue }
            guard !busy.contains(where: { !$0.intersection(gap).isEmpty }) else { continue }
            let margin = CMTime(seconds: kept / 2, preferredTimescale: 60_000)
            guard gap.duration.seconds - kept > smallestPauseCut else { continue }
            cuts.append(CMTimeRange(start: gap.start + margin, end: gap.end - margin))
        }
        return cuts
    }

    /// Ranges in time order with overlapping and touching ones merged.
    static func joined(_ ranges: [CMTimeRange]) -> [CMTimeRange] {
        var merged: [CMTimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) where range.duration > .zero {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = CMTimeRange(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

extension Timeline {
    /// Where stretches of the recording land on the timeline: every clip that shows part
    /// of them, clipped to what it shows.
    public func timelineRanges(ofSource source: ClosedRange<Double>) -> [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        var elapsed = CMTime.zero
        for clip in clips {
            defer { elapsed = elapsed + clip.duration }
            // An imported clip's source is another file, which the recording never reaches.
            guard clip.source == nil else { continue }
            let from = max(source.lowerBound, clip.sourceStart.seconds)
            let to = min(source.upperBound, clip.sourceEnd.seconds)
            guard to > from else { continue }
            let start = elapsed + CMTime(seconds: (from - clip.sourceStart.seconds) / clip.speed, preferredTimescale: 60_000)
            let end = elapsed + CMTime(seconds: (to - clip.sourceStart.seconds) / clip.speed, preferredTimescale: 60_000)
            ranges.append(CMTimeRange(start: start, end: end))
        }
        return ranges
    }
}

extension Commands {
    /// Several stretches cut out at once, as one edit.
    ///
    /// Cut from the last to the first, so each is still where it was measured: cutting the
    /// first one would move every one after it.
    public struct DeleteRanges: TimelineCommand {
        public let ranges: [CMTimeRange]
        public let name: String

        public init(_ ranges: [CMTimeRange], name: String) {
            self.ranges = ranges
            self.name = name
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            var changed = false
            for range in TranscriptEditing.joined(ranges).reversed() {
                changed = ClipSequence.delete(&timeline, range: range) || changed
            }
            return changed
        }
    }
}
