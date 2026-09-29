import CoreMedia
import Foundation

/// One word — or one short phrase — as some transcriber heard it, in the *recording's* clock.
///
/// Deliberately not the shape of any one speech API. Whatever recognises the audio hands
/// back its own class full of its own timings; this is the flat value everything
/// downstream agrees on, which is what lets two engines of very different ages produce
/// the same captions. It also means the interesting part — deciding where a caption
/// begins and ends — can be tested without a microphone, a model or a machine new enough
/// to run either.
public struct TranscribedWord: Sendable, Equatable {
    public var text: String
    public var start: CMTime
    public var duration: CMTime

    public var end: CMTime { start + duration }

    public init(text: String, start: CMTime, duration: CMTime) {
        self.text = text
        self.start = start
        self.duration = duration
    }

    /// The same thing from seconds, which is what the older recognisers deal in.
    public init(text: String, start: Double, duration: Double) {
        self.init(text: text,
                  start: CMTime(seconds: start, preferredTimescale: 600),
                  duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    /// Whether this word closes a sentence.
    ///
    /// Trailing quotes and brackets are stepped over first, so `he said "stop."` still
    /// ends a sentence.
    var closesSentence: Bool { lastMeaningfulCharacter.map(Self.sentenceEnders.contains) ?? false }
    /// Whether this word closes a clause — a weaker seam, used only when a line has to be
    /// broken somewhere and no sentence ends inside it.
    var closesClause: Bool { lastMeaningfulCharacter.map(Self.clauseEnders.contains) ?? false }

    private var lastMeaningfulCharacter: Character? {
        text.last {
            !$0.isWhitespace && !Self.trailingDecoration.contains($0)
        }
    }

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let clauseEnders: Set<Character> = [",", ";", ":", "—", "–", "、", "，"]
    private static let trailingDecoration: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "»"]
}

/// Timed words into readable lines.
///
/// This is the whole difference between a transcript and captions. A recogniser gives you
/// words and the moments they were said; a caption is a thing a person reads in a glance
/// while also watching a screen recording. So the rules here are about reading, not about
/// speech: break where the speaker broke, keep lines short enough to be taken in whole,
/// and never end a line mid-clause when a comma sits two words back.
///
/// Kept in `TimelineKit`, away from any speech framework, because it is the part with
/// opinions in it — and therefore the part worth testing.
public enum CaptionShaper {
    /// What "readable" means, in numbers.
    public struct Shape: Sendable, Equatable {
        /// How long a single caption may run before it is broken in two. Short: a
        /// ten-second line means the viewer is reading the beginning of a sentence while
        /// hearing the end of it.
        public var maximumDuration: CMTime
        /// A pause longer than this ends the line whatever its length — it is where the
        /// speaker themselves stopped.
        public var sentenceGap: CMTime
        public var maximumWords: Int
        /// Below this, a full stop is not worth breaking on: "Yes." on a line of its own
        /// flashes past before it can be read.
        public var minimumWords: Int
        /// Cues shorter than this are dropped rather than flickered on screen.
        public var minimumDuration: CMTime

        public init(maximumDuration: CMTime = CMTime(value: 35, timescale: 10),
                    sentenceGap: CMTime = CMTime(value: 55, timescale: 100),
                    maximumWords: Int = 12,
                    minimumWords: Int = 3,
                    minimumDuration: CMTime = CMTime(value: 1, timescale: 10)) {
            self.maximumDuration = maximumDuration
            self.sentenceGap = sentenceGap
            self.maximumWords = maximumWords
            self.minimumWords = minimumWords
            self.minimumDuration = minimumDuration
        }

        public static let `default` = Shape()
    }

    /// Words into lines, with nothing dropped and no clock but the recording's.
    ///
    /// Split out from `cues(from:on:shape:)` because grouping and mapping onto an edit are
    /// two separate ideas, and only one of them needs a timeline to talk about.
    public static func lines(from recognised: [TranscribedWord],
                            shape: Shape = .default) -> [[TranscribedWord]] {
        var lines: [[TranscribedWord]] = []
        var line: [TranscribedWord] = []

        for word in recognised {
            // The speaker's own boundaries come first: a pause, or a sentence that has
            // just finished and is long enough to stand as a line.
            if let previous = line.last,
               word.start - previous.end > shape.sentenceGap
                   || (previous.closesSentence && line.count >= shape.minimumWords) {
                lines.append(line)
                line = []
            }
            line.append(word)

            // Only then the limits. Checked after appending, so a line is as full as it
            // is allowed to be before anything is cut, and looped because one enormous
            // word can leave a remainder that is still too long.
            while overruns(line, shape) {
                let cut = breakPoint(in: line, shape)
                lines.append(Array(line[..<cut]))
                line = Array(line[cut...])
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// Lines onto the edit, as cues.
    ///
    /// The times come back in the recording's clock and are mapped through the timeline
    /// here, so captions still line up after a trim, a reorder or a speed change. A word
    /// spoken in footage that was cut has nowhere to go, and is dropped rather than shown
    /// at the wrong moment.
    public static func cues(from recognised: [TranscribedWord],
                            on timeline: Timeline,
                            shape: Shape = .default) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        for line in lines(from: recognised, shape: shape) {
            guard let first = line.first, let last = line.last,
                  let from = timeline.timelineTime(atSource: first.start),
                  let to = timeline.timelineTime(atSource: last.end),
                  to > from
            else { continue }

            // Joined with spaces because that is what the recognisers' word boundaries
            // mean in the languages they punctuate; each word is trimmed first, since a
            // modern transcriber hands back its spacing and an older one does not.
            let text = line
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { continue }
            cues.append(CaptionCue(start: from, duration: to - from, text: text,
                                   words: words(of: line, from: from, to: to, on: timeline)))
        }

        // Overlaps would put two lines on screen at once; the renderer shows only the
        // later one, so trimming here is what keeps what is drawn and what is stored the
        // same thing. A cut inside a line can pull two cues onto the same instant, which
        // is why this happens after the mapping rather than before it.
        for index in cues.indices.dropLast() where cues[index].end > cues[index + 1].start {
            let kept = (cues[index + 1].start - cues[index].start).seconds
            let was = cues[index].duration.seconds
            cues[index].duration = cues[index + 1].start - cues[index].start
            // The words were timed against the longer line; stretched onto the shorter
            // one they would all be said early, so they are put back on its clock.
            if was > 0, kept > 0 {
                cues[index].words = cues[index].words.map {
                    CaptionCue.Word(text: $0.text, from: min(1, $0.from * was / kept), to: min(1, $0.to * was / kept))
                }
            }
        }
        return cues.filter { $0.duration >= shape.minimumDuration }
    }

    /// When each word of a line is said, as fractions of the line, on the edit's clock.
    ///
    /// Through the timeline word by word rather than by proportion, because a line can
    /// have a change of speed inside it and the words either side of that are not spaced
    /// the way they were recorded. Empty if any word has nowhere to go — a half-timed line
    /// would light up some of its words and skip the rest.
    private static func words(of line: [TranscribedWord],
                              from: CMTime, to: CMTime,
                              on timeline: Timeline) -> [CaptionCue.Word] {
        let length = (to - from).seconds
        guard length > 0 else { return [] }
        var words: [CaptionCue.Word] = []
        for word in line {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // A recogniser's "word" can be two: it is drawn as the words it is.
            let pieces = text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let began = timeline.timelineTime(atSource: word.start),
                  let ended = timeline.timelineTime(atSource: word.end) else { return [] }
            let lower = (began - from).seconds / length
            let upper = (ended - from).seconds / length
            for (index, piece) in pieces.enumerated() {
                let share = (upper - lower) / Double(pieces.count)
                words.append(CaptionCue.Word(text: piece,
                                             from: lower + share * Double(index),
                                             to: lower + share * Double(index + 1)))
            }
        }
        return words
    }

    // MARK: - Where a line stops

    private static func overruns(_ line: [TranscribedWord], _ shape: Shape) -> Bool {
        guard let first = line.first, let last = line.last else { return false }
        return line.count > shape.maximumWords || last.end - first.start > shape.maximumDuration
    }

    /// How many words of an over-long line to keep, which is the one judgement call here.
    ///
    /// The largest prefix that fits is found first, and then the *last* punctuation inside
    /// it wins: a line that ends on a comma reads as writing, one that ends after exactly
    /// twelve words reads as a machine. Always at least one word, and never the whole
    /// line, so the caller's loop cannot spin.
    private static func breakPoint(in line: [TranscribedWord], _ shape: Shape) -> Int {
        var fits = line.count - 1
        while fits > 1, overruns(Array(line[..<fits]), shape) { fits -= 1 }

        if fits >= shape.minimumWords {
            for end in stride(from: fits, through: shape.minimumWords, by: -1)
            where line[end - 1].closesSentence || line[end - 1].closesClause {
                return end
            }
        }
        return max(1, fits)
    }
}
