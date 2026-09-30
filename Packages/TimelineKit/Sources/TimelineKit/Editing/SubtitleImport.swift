import CoreMedia
import Foundation

/// Reading a subtitle file — SubRip or WebVTT — into captions.
///
/// The other half of `CaptionExport`. The times in the file are taken to be the *edit's*,
/// which is what `CaptionExport` writes and what a subtitle file made for this video
/// means: a transcript someone corrected elsewhere, or a translation, comes back to the
/// moments it left.
///
/// # Forgiving on purpose
///
/// Subtitle files are written by everything — editors, transcription services, scripts,
/// people in a text editor — and very few of them follow the format to the letter. So the
/// reader asks for one thing only, a line with `-->` in it between two times, and takes
/// everything else as it comes:
///
/// - a byte-order mark, Windows or old Mac line endings, tabs, trailing spaces;
/// - SubRip numbers that are missing, wrong, or run into the text with no blank line;
/// - a WebVTT header with text after `WEBVTT`, metadata lines under it, `NOTE`, `STYLE`
///   and `REGION` blocks, cue identifiers, and cue settings after the end time;
/// - times with or without hours, with a comma or a full stop, with any number of digits
///   after it;
/// - markup in the text — `<i>`, `<font color=…>`, `<c.yellow>`, `<v Speaker>`, timing
///   tags, the `{\an8}` placement codes some SubRip writers add — which is taken out, and
///   entities like `&amp;`, which are turned back into their characters.
///
/// A cue that cannot be read is counted and skipped rather than failing the file: one bad
/// time in line four hundred should cost that line, not the other three hundred and
/// ninety-nine.
///
/// # Cues over one moment
///
/// The captions lane shows one line at a time — where two cues overlap, the later one is
/// shown. A player shows both, stacked. So overlapping cues are laid out the way a player
/// would show them: the time is cut wherever a cue starts or ends, and each piece shows
/// every cue that is on then, one per line, earliest first. Two speakers talking at once
/// both stay on screen. An overlap shorter than a caption can be — the hundredth of a
/// second a rounding writer leaves between one cue and the next — is taken off the
/// earlier cue instead, so it does not become a flash of both.
public enum SubtitleImport {
    /// One line of the file, in seconds of the edit.
    public struct Cue: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// What a file came to.
    public struct Parsed: Equatable, Sendable {
        /// The cues, in order, overlaps resolved, empty ones gone.
        public var cues: [Cue]
        /// Timing lines that could not be read.
        public var skipped: Int
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// Not text, or text with no timing line in it.
        case notSubtitles
        /// Subtitles, but none of them inside the video.
        case nothingInside

        public var errorDescription: String? {
            switch self {
            case .notSubtitles:
                "That file has no subtitles in it that could be read. Choose a SubRip (.srt) or WebVTT (.vtt) file."
            case .nothingInside:
                "None of those subtitles fall inside this video. They start after it ends."
            }
        }
    }

    // MARK: - Reading

    /// Reads the bytes of a file, whatever its encoding turns out to be.
    ///
    /// UTF-8 first, which is almost every file; then UTF-16 when it says so with a mark;
    /// then Windows Latin-1, which is what an old SubRip file from a European editor is,
    /// and which reads any byte at all — so a file is never refused for its encoding alone.
    public static func text(of data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    public static func parse(_ data: Data) throws(Failure) -> Parsed {
        guard let text = text(of: data) else { throw .notSubtitles }
        return try parse(text)
    }

    public static func parse(_ text: String) throws(Failure) -> Parsed {
        let lines = normalised(text).components(separatedBy: "\n")
        var raw: [Cue] = []
        var skipped = 0
        var sawTiming = false

        /// The cue being read: its times, and its lines so far.
        var current: (start: Double, end: Double, lines: [String])?
        /// Inside a WebVTT block that is not a cue — the header, a note, a style sheet.
        var skippingBlock = false
        /// Whether the line before this one was blank, or this is the first line — where a
        /// WebVTT keyword starts a block rather than being a caption's words.
        var atBlockStart = true

        func finish() {
            guard let cue = current else { return }
            current = nil
            let body = cue.lines.map(cleaned).filter { !$0.isEmpty }.joined(separator: "\n")
            guard !body.isEmpty, cue.end > cue.start else { return }
            raw.append(Cue(start: cue.start, end: cue.end, text: body))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                finish()
                skippingBlock = false
                atBlockStart = true
                continue
            }
            defer { atBlockStart = false }

            // An arrow in a line that is not two times, inside a cue, is the cue's words:
            // "Open File --> Export" is how half of all tutorials say where to click. Read
            // as a broken timing line it ended the cue there, lost every line after it,
            // and was counted as a time that could not be read.
            if trimmed.contains("-->"), current == nil || looksTimed(trimmed) {
                sawTiming = true
                // A SubRip file with no blank line before the next number has read that
                // number as the last line of the cue before. It is the next cue's, and not
                // anybody's words.
                if var cue = current, let last = cue.lines.last,
                   !last.isEmpty, last.allSatisfy(\.isNumber) {
                    cue.lines.removeLast()
                    current = cue
                }
                finish()
                skippingBlock = false
                guard let (start, end) = timing(trimmed) else {
                    skipped += 1
                    continue
                }
                current = (start, end, [])
                continue
            }
            if skippingBlock { continue }
            if atBlockStart, current == nil, startsNonCueBlock(trimmed) {
                skippingBlock = true
                continue
            }
            // Before a timing line, a line is a cue's number or identifier, not its words.
            guard current != nil else { continue }
            current?.lines.append(trimmed)
        }
        finish()

        guard sawTiming else { throw .notSubtitles }
        return Parsed(cues: laidOut(raw), skipped: skipped)
    }

    /// One kind of line ending, and no byte-order mark or stray nulls.
    static func normalised(_ text: String) -> String {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: "\t", with: " ")
    }

    /// The WebVTT blocks that carry no caption: the header, notes, style sheets, regions.
    private static func startsNonCueBlock(_ line: String) -> Bool {
        let first = line.prefix { !$0.isWhitespace }
        return first == "WEBVTT" || first == "NOTE" || first == "STYLE" || first == "REGION"
            || line.hasPrefix("WEBVTT")
    }

    // MARK: - Times

    /// The two times on a timing line, in seconds. Whatever follows the end time — WebVTT's
    /// cue settings, SubRip's rarely-used coordinates — is placement, and ignored.
    static func timing(_ line: String) -> (Double, Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        // The last word on the left, in case an identifier shares the line.
        guard let startWord = left.split(separator: " ").last,
              let endWord = right.split(separator: " ").first,
              let start = seconds(String(startWord)),
              let end = seconds(String(endWord)) else { return nil }
        return (start, end)
    }

    /// Whether a line with an arrow in it is meant as a timing line, read or not: a time,
    /// or something shaped like one, just before the arrow. A timing line with a typo in it
    /// is still a timing line — the cue it starts is skipped, and counted — while
    /// "Settings --> Privacy" is somebody's words.
    static func looksTimed(_ line: String) -> Bool {
        if timing(line) != nil { return true }
        guard let arrow = line.range(of: "-->") else { return false }
        let left = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let stamp = left.split(separator: " ").last else { return false }
        return stamp.contains(":") && stamp.first?.isNumber == true
    }

    /// `01:02:03,456`, `02:03.456`, `1:02:03.4` — hours optional, either separator, any
    /// number of digits after it. `nil` for anything else.
    static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        let last = parts[parts.count - 1].replacingOccurrences(of: ",", with: ".")
        let whole = last.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(whole.count),
              let secs = Int(whole[0]), (0..<60).contains(secs) else { return nil }
        var fraction = 0.0
        if whole.count == 2 {
            let digits = whole[1]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Double("0.\(digits)") else { return nil }
            fraction = value
        }
        guard let minutes = Int(parts[parts.count - 2]), minutes >= 0 else { return nil }
        var hours = 0
        if parts.count == 3 {
            guard let h = Int(parts[0]), h >= 0 else { return nil }
            hours = h
            // With hours given, minutes are a clock's.
            guard minutes < 60 else { return nil }
        }
        return Double(hours * 3_600 + minutes * 60 + secs) + fraction
    }

    // MARK: - Words

    /// A line of a cue with its markup taken out and its entities put back.
    static func cleaned(_ line: String) -> String {
        var out = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            // A tag: `<i>`, `</b>`, `<c.yellow>`, `<v Joe>`, `<00:00:01.000>`. Only when it
            // closes before the line ends — a lone `<` is somebody's words.
            if character == "<", let close = line[index...].firstIndex(of: ">"),
               !line[line.index(after: index)..<close].contains("<") {
                index = line.index(after: close)
                continue
            }
            // SubRip's placement codes, borrowed from ASS: `{\an8}`, `{\i1}`.
            if character == "{", line[index...].dropFirst().first == "\\",
               let close = line[index...].firstIndex(of: "}") {
                index = line.index(after: close)
                continue
            }
            out.append(character)
            index = line.index(after: index)
        }
        return decoded(out)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// `&amp;` and friends, named and numbered, as their characters. The direction marks
    /// WebVTT allows are dropped: they steer the layout of text this lane lays out itself.
    static func decoded(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
                                       "nbsp": " ", "lrm": "", "rlm": ""]
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                let name = String(text[text.index(after: index)..<semicolon])
                var replacement: String?
                if let value = named[name.lowercased()] {
                    replacement = value
                } else if name.hasPrefix("#x") || name.hasPrefix("#X"),
                          let code = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                } else if name.hasPrefix("#"), let code = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                }
                if let replacement {
                    out += replacement
                    index = text.index(after: semicolon)
                    continue
                }
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }

    // MARK: - Laying cues out on one lane

    /// The cues as one line at a time can show them. See the note on the type.
    static func laidOut(_ cues: [Cue]) -> [Cue] {
        let shortest = Clip.minimumDuration.seconds
        var sorted = cues.enumerated()
            .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map(\.element)
        // The same line twice, as some converters write it, is one line.
        var seen: Set<String> = []
        sorted = sorted.filter { seen.insert("\($0.start)|\($0.end)|\($0.text)").inserted }
        // A sliver of overlap is rounding, not two things said at once.
        for index in sorted.indices.dropLast() {
            let next = sorted[index + 1]
            let overlap = sorted[index].end - next.start
            if overlap > 0, overlap < shortest, next.start - sorted[index].start >= shortest {
                sorted[index].end = next.start
            }
        }

        let edges = Set(sorted.flatMap { [$0.start, $0.end] }).sorted()
        var pieces: [Cue] = []
        for (from, to) in zip(edges, edges.dropFirst()) where to > from {
            let on = sorted.filter { $0.start < to && $0.end > from }
            guard !on.isEmpty else { continue }
            var lines: [String] = []
            for cue in on where !lines.contains(cue.text) { lines.append(cue.text) }
            let text = lines.joined(separator: "\n")
            if var last = pieces.last, last.text == text, abs(last.end - from) < 1e-9 {
                last.end = to
                pieces[pieces.count - 1] = last
            } else {
                pieces.append(Cue(start: from, end: to, text: text))
            }
        }
        // A piece too short to be a caption joins the one before it when they touch.
        var kept: [Cue] = []
        for piece in pieces {
            if piece.end - piece.start < shortest, let last = kept.last, abs(last.end - piece.start) < 1e-9 {
                kept[kept.count - 1].end = piece.end
            } else {
                kept.append(piece)
            }
        }
        return kept
    }

    // MARK: - Onto the timeline

    /// The cues as captions on an edit of `duration`: those that start after it ends are
    /// left out, and one running past it is cut at it.
    public static func captions(from parsed: Parsed, within duration: CMTime) throws(Failure) -> [CaptionCue] {
        let end = duration.seconds
        let cues: [CaptionCue] = parsed.cues.compactMap { cue in
            let start = max(0, cue.start)
            let finish = min(cue.end, end)
            guard finish - start >= Clip.minimumDuration.seconds else { return nil }
            return CaptionCue(start: CMTime(seconds: start, preferredTimescale: 600),
                              duration: CMTime(seconds: finish - start, preferredTimescale: 600),
                              text: cue.text)
        }
        guard !cues.isEmpty else { throw .nothingInside }
        return cues
    }
}

extension Commands {
    /// A subtitle file's lines as the captions, in place of whatever was there.
    ///
    /// In place of rather than beside: a subtitle file is a whole transcript, and laid over
    /// generated captions the two would take turns line by line. Shown, too, if the
    /// captions had been hidden — somebody who just chose a file wants to see it. One
    /// step, so one ⌘Z puts the old captions back as they were.
    public struct ImportSubtitles: TimelineCommand {
        public let cues: [CaptionCue]
        public var name: String { "Import Subtitles" }

        public init(_ cues: [CaptionCue]) { self.cues = cues }

        public func apply(to timeline: inout Timeline) -> Bool {
            let sorted = cues.sorted { $0.start < $1.start }
            guard !sorted.isEmpty,
                  timeline.captions != sorted || !timeline.captionStyle.isVisible else { return false }
            timeline.captions = sorted
            timeline.captionStyle.isVisible = true
            return true
        }
    }
}
