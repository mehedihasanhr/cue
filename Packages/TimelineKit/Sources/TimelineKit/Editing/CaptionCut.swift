import CoreMedia

extension CaptionCue {
    /// This caption once a stretch of the timeline has been cut out, or `nil` if nothing
    /// of it is left.
    ///
    /// Done word by word rather than as a region: a caption is text measured against time,
    /// and cutting the middle out of a line must take the words that were said in that
    /// middle with it, and bring the words after it forward, or every word from there on
    /// lights up at the wrong moment. A line with no word timings of its own — one typed by
    /// hand — keeps its text and is moved and shortened like any other region.
    func cut(_ range: CMTimeRange) -> CaptionCue? {
        // Entirely inside the cut: gone. Entirely before or after: moved, words and all.
        if start >= range.start && end <= range.end { return nil }
        if end <= range.start { return self }
        if start >= range.end {
            var moved = self
            moved.start = start - range.duration
            return moved
        }

        func place(_ time: CMTime) -> CMTime {
            if time <= range.start { return time }
            if time >= range.end { return time - range.duration }
            return range.start
        }
        var cut = self
        cut.start = place(start)
        let length = place(end) - cut.start
        guard length >= Clip.minimumDuration else { return nil }
        cut.duration = length

        let recorded = !words.isEmpty && words == timedWords
        guard recorded else { return cut }
        let seconds = duration.seconds
        let kept: [(text: String, from: CMTime, to: CMTime)] = words.compactMap { word in
            let from = start + CMTime(seconds: word.from * seconds, preferredTimescale: 60_000)
            let to = start + CMTime(seconds: word.to * seconds, preferredTimescale: 60_000)
            // A word said mostly inside the cut is gone with it.
            let middle = CMTimeMultiplyByFloat64(from + to, multiplier: 0.5)
            guard !CMTimeRangeContainsTime(range, time: middle) else { return nil }
            return (word.text, place(from), place(to))
        }
        guard !kept.isEmpty else { return nil }
        let total = length.seconds
        cut.words = kept.map {
            Word(text: $0.text,
                 from: max(0, min(1, ($0.from - cut.start).seconds / total)),
                 to: max(0, min(1, ($0.to - cut.start).seconds / total)))
        }
        cut.text = kept.map(\.text).joined(separator: " ")
        return cut
    }
}

extension CaptionCue {
    /// Whether the words carry the recogniser's own timings, and so are statements about
    /// when each word is heard rather than a spread of the text across the cue.
    var hasRecordedWords: Bool { !words.isEmpty && words == timedWords }

    /// When each recorded word is said, on the timeline.
    private var wordTimes: [(text: String, from: CMTime, to: CMTime)] {
        let seconds = duration.seconds
        return words.map { word in
            (word.text,
             start + CMTime(seconds: word.from * seconds, preferredTimescale: 60_000),
             start + CMTime(seconds: word.to * seconds, preferredTimescale: 60_000))
        }
    }

    /// The words, placed again as fractions of this cue's current span.
    private func placing(_ times: [(text: String, from: CMTime, to: CMTime)]) -> [Word] {
        let total = duration.seconds
        guard total > 0 else { return [] }
        return times.map {
            Word(text: $0.text,
                 from: max(0, min(1, ($0.from - start).seconds / total)),
                 to: max(0, min(1, ($0.to - start).seconds / total)))
        }
    }

    /// This caption with every moment of it moved through a time mapping that never runs
    /// backwards — a speed change, or time opened up inside it.
    ///
    /// Word by word, for the reason `cut(_:)` is: the words are fractions of the cue, so
    /// moving only its two ends rescales every word uniformly. Where the mapping is not
    /// uniform — half the line in footage that now plays twice as fast, or footage pushed
    /// in between two words — the words then drift off the moments they are heard at, and
    /// a later cut that goes by them (Remove Filler Words) cuts the wrong sound.
    func retimed(_ place: (CMTime) -> CMTime) -> CaptionCue {
        var moved = self
        moved.start = place(start)
        moved.duration = max(Clip.minimumDuration, place(end) - moved.start)
        guard hasRecordedWords else { return moved }
        moved.words = moved.placing(wordTimes.map { ($0.text, place($0.from), place($0.to)) })
        return moved
    }

    /// This caption after one of its edges has been dragged to make `resized`.
    ///
    /// A recorded word is heard when it is heard, whatever the cue around it does, so the
    /// words keep their times and a word left mostly outside the cue goes — the rule `cut`
    /// keeps. Kept as fractions instead, trimming a line's end squeezed every word towards
    /// its start: "um" at 3.0 s in a five-second cue trimmed to three was then placed at
    /// 1.8 s, and removing fillers cut the wrong sound. A move that keeps the length is not
    /// a resize, and the words go with the cue, as they always have.
    ///
    /// A cue whose recorded words have all been trimmed away keeps its text as typed words
    /// with no timings — deleting the caption is not what dragging its edge asked for.
    func carryingWords(to resized: CaptionCue) -> CaptionCue {
        guard hasRecordedWords, resized.duration != duration else {
            var kept = resized
            kept.words = words
            return kept
        }
        // Where one edge stayed put, the words stay put. Where neither did — a resize
        // clamped against the end of the edit moves both — they go with the start.
        let shift = resized.start == start || resized.end == end ? .zero : resized.start - start
        let range = CMTimeRange(start: resized.start, end: resized.end)
        let kept = wordTimes.compactMap { word -> (text: String, from: CMTime, to: CMTime)? in
            let from = word.from + shift
            let to = word.to + shift
            let middle = CMTimeMultiplyByFloat64(from + to, multiplier: 0.5)
            guard CMTimeRangeContainsTime(range, time: middle) else { return nil }
            return (word.text, max(from, range.start), min(to, range.end))
        }
        var cue = resized
        guard !kept.isEmpty else {
            cue.words = []
            return cue
        }
        cue.words = cue.placing(kept)
        cue.text = kept.map(\.text).joined(separator: " ")
        return cue
    }
}
