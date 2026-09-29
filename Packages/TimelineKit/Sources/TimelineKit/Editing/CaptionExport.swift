import CoreMedia
import Foundation

/// Captions as a file other things can read.
///
/// A video with its captions burnt in can be read by a person and by nothing else. A
/// subtitle file beside it is what a player switches on and off, what a site indexes, and
/// what a translator works from — and it is the one export every transcription tool is
/// asked for.
///
/// Times are the *edit's*, not the recording's: the file goes with the exported video,
/// which is the edit.
public enum CaptionExport {
    public enum Format: String, CaseIterable, Sendable {
        /// SubRip. The one every player and every site takes.
        case srt
        /// WebVTT. What a web page's `<track>` wants.
        case vtt

        public var title: String {
            switch self {
            case .srt: "SubRip (.srt)"
            case .vtt: "WebVTT (.vtt)"
            }
        }

        public var fileExtension: String { rawValue }
    }

    /// The cues as the text of a subtitle file.
    ///
    /// In order of time, numbered from one, with empty lines left out — a cue with
    /// nothing in it is a caption that shows nothing, and some players stop at one.
    public static func text(for cues: [CaptionCue], as format: Format) -> String {
        let spoken = cues
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.duration > .zero }
            .sorted { $0.start < $1.start }

        var lines: [String] = []
        if format == .vtt {
            lines.append("WEBVTT")
            lines.append("")
        }
        for (index, cue) in spoken.enumerated() {
            // SubRip numbers its cues; WebVTT may, and leaving the numbers out keeps the
            // file the text and its timings and nothing else.
            if format == .srt { lines.append(String(index + 1)) }
            lines.append("\(stamp(cue.start, format)) --> \(stamp(cue.end, format))")
            lines.append(contentsOf: body(of: cue, format))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// A time as `00:01:02,345` for SubRip and `00:01:02.345` for WebVTT. The comma is
    /// the only difference, and the reason the two cannot share a file.
    static func stamp(_ time: CMTime, _ format: Format) -> String {
        let total = max(0, Int((time.seconds * 1_000).rounded()))
        let milliseconds = total % 1_000
        let seconds = (total / 1_000) % 60
        let minutes = (total / 60_000) % 60
        let hours = total / 3_600_000
        let separator = format == .srt ? "," : "."
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, separator, milliseconds)
    }

    /// The words, one line of text per line of the cue.
    ///
    /// A blank line ends a cue in both formats, so one inside the text would cut the
    /// caption short; and WebVTT reads `-->` and markup in the text as its own, so those
    /// are made harmless.
    private static func body(of cue: CaptionCue, _ format: Format) -> [String] {
        cue.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                guard format == .vtt else { return line }
                return line
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
    }
}
