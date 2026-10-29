import Foundation

/// What was said after "Hey Cue" as a command at its end: "done" types the words before
/// it, "cancel" drops everything. A command counts only on its own, after a pause (the
/// recogniser's stop or comma) or "okay" or "Cue", so "I'm done" in a sentence is words.
enum VoiceCommand: Equatable {
    case done(String)
    case cancel

    private static let lead = #"(?:^|[.,!?]\s*|\b(?:okay|ok|cue)[,.]?\s+)"#
    private static let tail = #"[.!]?\s*$"#
    private static let doneWords = #"(?:done|that's all|that is all|that's it|finished|stop listening|end dictation)"#
    private static let cancelWords = #"(?:cancel|never mind|nevermind|scratch that)"#

    init?(_ said: String) {
        if said.range(of: "(?i)" + Self.lead + Self.cancelWords + Self.tail, options: .regularExpression) != nil {
            self = .cancel
        } else if let range = said.range(of: "(?i)" + Self.lead + Self.doneWords + Self.tail, options: .regularExpression)
                    ?? said.range(of: #"(?i)\bstop listening[.!]?\s*$"#, options: .regularExpression) {
            let words = String(said[..<range.lowerBound])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            self = .done(words)
        } else {
            return nil
        }
    }
}
