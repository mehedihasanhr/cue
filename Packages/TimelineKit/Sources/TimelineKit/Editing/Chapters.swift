import CoreMedia
import Foundation

/// One chapter of the finished video: where it starts, and what it is called.
public struct Chapter: Equatable, Sendable {
    public var time: CMTime
    public var title: String

    public init(time: CMTime, title: String) {
        self.time = time
        self.title = title
    }
}

/// The video's chapters, from what the edit already says about where things begin.
///
/// Two things mark a new part of a video without anybody having to say so again: a marker
/// dropped while recording ("something starts here") and a title slide ("this is what
/// comes next"). Both are placed on the finished video's own clock — markers through
/// `RecordedMarkers`, which moves them with every cut — so the chapters are the edit's.
///
/// # Names
///
/// A title slide names its chapter with its title. A marker has no words of its own, so it
/// borrows the first caption said at or just after it — usually the sentence that
/// introduces what the marker marks — and is "Chapter 2" when nothing is said there. The
/// first chapter is always at the very start, as YouTube requires: a marker or a title
/// within a second of the start is moved there, and otherwise an "Intro" is put there.
///
/// # YouTube's rules
///
/// A description's timestamps become chapters only when the first is `0:00`, there are at
/// least three, and each lasts at least ten seconds — the last one included, up to the end
/// of the video. The list is not bent to fit: merging or dropping somebody's chapters to
/// satisfy a rule would publish a list they did not make. `youTubeProblem` says what is
/// wrong instead, and the menu says it beside the command.
public enum Chapters {
    /// What the first chapter is called when nothing marks the start.
    public static let introTitle = "Intro"
    /// YouTube's shortest chapter, in seconds.
    public static let shortestChapter = 10
    /// YouTube's fewest chapters.
    public static let fewestChapters = 3
    /// How far from the start something may be and still be the first chapter.
    static let startTolerance = 1.0
    /// How long after a marker a caption may begin and still be what the marker is about.
    static let captionReach = 5.0
    /// The longest a chapter's name is kept.
    static let longestTitle = 60

    /// The chapters, earliest first, the first at zero.
    ///
    /// - Parameter markers: the recording's markers on the timeline — see
    ///   `RecordedMarkers.times(of:in:)`.
    public static func list(for timeline: Timeline, markers: [CMTime]) -> [Chapter] {
        var found: [(seconds: Double, title: String?, isTitle: Bool)] = []
        var elapsed = CMTime.zero
        for clip in timeline.clips {
            if let card = clip.title {
                let words = [card.title, card.subtitle]
                    .map { oneLine($0) }
                    .first { !$0.isEmpty }
                found.append((elapsed.seconds, words, true))
            }
            elapsed = elapsed + clip.duration
        }
        for marker in markers where marker >= .zero && marker < timeline.duration {
            found.append((marker.seconds, captionTitle(at: marker.seconds, in: timeline), false))
        }
        found.sort { $0.seconds < $1.seconds }

        var chapters: [Chapter] = []
        for item in found {
            let seconds = item.seconds < startTolerance ? 0 : item.seconds
            // One chapter per second of the video: a marker dropped on a title slide's
            // first frame is the same chapter, and the slide's words name it.
            if let last = chapters.last, Int(last.time.seconds) == Int(seconds) {
                if item.isTitle, let title = item.title { chapters[chapters.count - 1].title = title }
                continue
            }
            chapters.append(Chapter(time: CMTime(seconds: seconds, preferredTimescale: 600),
                                    title: item.title ?? ""))
        }
        if chapters.first.map({ $0.time.seconds > 0 }) ?? true {
            chapters.insert(Chapter(time: .zero, title: introTitle), at: 0)
        }
        for index in chapters.indices where chapters[index].title.isEmpty {
            chapters[index].title = index == 0 ? introTitle : "Chapter \(index + 1)"
        }
        return chapters
    }

    /// Whether a list is only the "Intro" this puts at the start of any video — nothing
    /// the edit marked.
    public static func isOnlyIntro(_ chapters: [Chapter]) -> Bool { chapters.count < 2 }

    /// The first caption said at `seconds` or shortly after, as a chapter's name.
    private static func captionTitle(at seconds: Double, in timeline: Timeline) -> String? {
        let cue = timeline.captions
            .filter { $0.end.seconds > seconds && $0.start.seconds <= seconds + captionReach }
            .min { $0.start < $1.start }
        guard let cue else { return nil }
        let words = oneLine(cue.text)
        return words.isEmpty ? nil : words
    }

    /// Words on one line, as a chapter's name has to be: YouTube reads a line break as the
    /// end of the chapter.
    static func oneLine(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard words.count > longestTitle else { return words }
        let cut = words.prefix(longestTitle)
        // At a word's end, not in the middle of one.
        let trimmed = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return trimmed.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    // MARK: - YouTube

    /// Why YouTube would not show these as chapters.
    public enum Problem: Equatable, Sendable {
        case tooFew(Int)
        case firstNotAtStart
        /// A chapter that lasts less than ten seconds: its title, where it starts, and how
        /// long it lasts, all as YouTube would count them.
        case tooShort(title: String, at: Int, seconds: Int)

        /// The reason, as the menu says it beside the command.
        public var reason: String {
            switch self {
            case .tooFew(let count):
                let have = count <= 1 ? "only the start" : "\(count)"
                return "YouTube needs at least three chapters, and this video has \(have). "
                    + "Drop markers while recording or add title slides to mark where parts begin."
            case .firstNotAtStart:
                return "YouTube needs the first chapter at 0:00."
            case .tooShort(let title, let at, let seconds):
                return "YouTube needs every chapter to last ten seconds, and “\(title)” at \(Chapters.stamp(at)) lasts \(seconds == 1 ? "a second" : "\(seconds) seconds"). "
                    + "Move or remove the marker or title slide that starts it or the next one."
            }
        }
    }

    /// The first rule a list breaks, or `nil` when YouTube would show it as chapters.
    ///
    /// Measured in whole seconds, as the timestamps in the description say them: two
    /// chapters 10.4 seconds apart are written ten seconds apart, and that is what counts.
    public static func youTubeProblem(_ chapters: [Chapter], duration: CMTime) -> Problem? {
        guard chapters.count >= fewestChapters else { return .tooFew(chapters.count) }
        let starts = chapters.map { Int($0.time.seconds.rounded(.down)) }
        guard starts.first == 0 else { return .firstNotAtStart }
        let end = Int(duration.seconds.rounded(.down))
        for index in chapters.indices {
            let next = index + 1 < starts.count ? starts[index + 1] : end
            let length = next - starts[index]
            if length < shortestChapter {
                return .tooShort(title: chapters[index].title, at: starts[index], seconds: max(0, length))
            }
        }
        return nil
    }

    // MARK: - Words

    /// The chapters as a video description lists them: `0:00 Intro`, one to a line.
    public static func text(_ chapters: [Chapter]) -> String {
        let long = chapters.contains { $0.time.seconds >= 3_600 }
        return chapters
            .map { "\(stamp(Int($0.time.seconds.rounded(.down)), withHours: long)) \($0.title)" }
            .joined(separator: "\n")
    }

    /// `0:00`, `1:23`, `12:05`, and `1:02:03` past the hour. `withHours` writes `0:01:23`
    /// so a list that runs past an hour lines up.
    public static func stamp(_ seconds: Int, withHours: Bool = false) -> String {
        let seconds = max(0, seconds)
        let hours = seconds / 3_600
        let minutes = (seconds / 60) % 60
        let rest = seconds % 60
        if hours > 0 || withHours {
            return String(format: "%d:%02d:%02d", hours, minutes, rest)
        }
        return String(format: "%d:%02d", minutes, rest)
    }
}
