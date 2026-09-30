import CoreMedia
import Foundation

extension TranscriptEditing {
    /// One word of the transcript: which line it is in, and where in that line.
    ///
    /// By position rather than by text, because the same word is said many times and only
    /// one of them was picked. A cut changes the positions, so a selection held by these is
    /// let go of after every edit.
    public struct WordID: Hashable, Sendable {
        public let cue: UUID
        public let index: Int

        public init(cue: UUID, index: Int) {
            self.cue = cue
            self.index = index
        }
    }

    /// How far past a word's recorded edges a cut reaches, in seconds.
    ///
    /// A recogniser marks where a word's sound is loudest to it, and the breath into the
    /// word and the tail of its last consonant sit a little outside that. Cut exactly at the
    /// marks and a click of the word is left at each end. Thirty milliseconds is under a
    /// frame at 30 fps and takes those with it; the neighbours still bound it, below.
    public static let wordPadding = 0.03

    /// The stretches of the timeline to cut so that the chosen words are gone.
    ///
    /// Only words the recogniser timed can be chosen: a line typed or corrected by hand has
    /// its words spread across it by length, and cutting where a guess puts a word would cut
    /// a real one. Words next to each other in the order they are heard become one cut,
    /// silence between them included, so taking out a phrase leaves no crumbs of pause
    /// behind. Each cut reaches `padding` past its words and never into a word that was not
    /// chosen: where two words run into each other, the one that stays keeps every moment
    /// of its sound.
    public static func wordCutRanges(_ chosen: Set<WordID>,
                                     in timeline: Timeline,
                                     padding: Double = wordPadding) -> [CMTimeRange] {
        let cuts = wordCutRanges(chosen, among: spokenWords(in: timeline), padding: padding, end: timeline.duration)
        return keepingHolds(cuts, in: timeline)
    }

    /// Cuts with the clips that are not the recording taken back out of them.
    ///
    /// A cut worked out from what was said reaches across the silence between words, and
    /// a title slide, a freeze frame or an added movie put in between two lines is exactly
    /// such a silence to the transcript — nobody speaks over it. Picking the last word
    /// before a title and the first after it made one run of them, and the cut took the
    /// title with it. What was said can only ever cut what was recorded.
    public static func keepingHolds(_ cuts: [CMTimeRange], in timeline: Timeline) -> [CMTimeRange] {
        let unrecorded = PaceSuggester.unmeasuredRanges(in: timeline)
        guard !unrecorded.isEmpty else { return cuts }
        return cuts.flatMap { PaceSuggester.subtract(unrecorded, from: $0) }
            .filter { $0.duration > .zero }
    }

    /// The same, over words already worked out — `words` in the order they are heard.
    static func wordCutRanges(_ chosen: Set<WordID>,
                              among words: [SpokenWord],
                              padding: Double,
                              end: CMTime) -> [CMTimeRange] {
        guard !chosen.isEmpty else { return [] }
        let pad = CMTime(seconds: padding.isFinite ? max(0, padding) : 0, preferredTimescale: 60_000)
        var cuts: [CMTimeRange] = []
        var first = 0
        while first < words.count {
            guard chosen.contains(words[first].id) else {
                first += 1
                continue
            }
            var last = first
            while last + 1 < words.count, chosen.contains(words[last + 1].id) { last += 1 }
            // The words either side that stay. Their sound is the limit, not their start or
            // end alone: a word that overlaps the next one in the recogniser's timings
            // bounds the cut by the part of it that reaches furthest.
            let floor = first > 0 ? words[..<first].map(\.range.end).max() ?? .zero : .zero
            let ceiling = last + 1 < words.count ? words[last + 1].range.start : end
            let start = max(.zero, max(floor, words[first].range.start - pad))
            let stop = min(end, min(ceiling, words[last].range.end + pad))
            if stop > start { cuts.append(CMTimeRange(start: start, end: stop)) }
            first = last + 1
        }
        return joined(cuts)
    }

    /// The word being said at `time`, if a timed one is.
    ///
    /// The later word wins where two overlap, as the later caption does on screen: it is
    /// the one being said now.
    public static func word(at time: CMTime, among words: [SpokenWord]) -> SpokenWord? {
        words.last { $0.range.start <= time && time < $0.range.end }
    }
}

extension Commands {
    /// Cuts the chosen words out of the video — picture, sound, captions and everything
    /// laid over them — as one edit.
    public static func cutWords(_ chosen: Set<TranscriptEditing.WordID>,
                                in timeline: Timeline) -> DeleteRanges? {
        let ranges = TranscriptEditing.wordCutRanges(chosen, in: timeline)
        guard !ranges.isEmpty else { return nil }
        return DeleteRanges(ranges, name: chosen.count == 1 ? "Cut Word" : "Cut \(chosen.count) Words")
    }
}
