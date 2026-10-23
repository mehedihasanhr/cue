import AppKit
import TimelineKit

/// J, K and L: play backwards, stop, play forwards — faster with each press.
///
/// **How backwards works.** This player draws its own frames: every frame shown is a
/// seek into the recording through `FrameSource`, forwards or backwards, and the sound is
/// a separate `AVPlayer` that is only the clock while playing forwards at normal speed.
/// `AVPlayer` cannot play a composition backwards, and a decoder cannot run a group of
/// pictures in reverse, so backwards playback is not smooth playback: it is the playhead
/// stepping backwards in time at the asked-for rate, on the wall clock, with the picture
/// seeking to whichever frame it can decode in time. It reads as a fast scrub, which is
/// what J is for.
///
/// **Sound.** Silent at every rate but 1× forwards. At 2× the sound would have to be
/// time-stretched, which is not what the file will sound like; at 4× it is noise; and
/// backwards it cannot be played at all. One rule — sound only at the speed the film
/// plays at — is easier to trust than three, and the wall clock keeps time in its place,
/// exactly as it already does for a recording with no sound in it.
extension EditorModel {
    /// One press of a shuttle key.
    ///
    /// Refused while a voiceover is being recorded — the take is being spoken against the
    /// picture at normal speed, and a picture at 4× would give the narration nothing to be
    /// against — except for stop, which ends the take as any stop does.
    func shuttle(_ key: PlaybackShuttle.Key) {
        if isRecordingVoiceover, key != .stop { return }
        guard let rate = PlaybackShuttle.rate(after: key, running: isPlaying ? playbackRate : nil) else {
            if isPlaying { togglePlayback() }
            return
        }
        setPlaybackRate(rate)
    }

    /// What the transport shows while the rate is not 1×, or nothing while it is.
    ///
    /// The sign is spelled as a minus rather than an arrow, because "−2×" is what every
    /// editor's transport says and a glyph would need explaining.
    var playbackRateLabel: String? {
        guard isPlaying, playbackRate != 1 else { return nil }
        let magnitude = Int(abs(playbackRate).rounded())
        return playbackRate < 0 ? "−\(magnitude)×" : "\(magnitude)×"
    }

    /// The same, in words, for anyone hearing rather than reading it.
    var playbackRateDescription: String? {
        guard isPlaying, playbackRate != 1 else { return nil }
        let magnitude = Int(abs(playbackRate).rounded())
        return playbackRate < 0 ? "Playing backwards at \(magnitude) times speed"
                                : "Playing at \(magnitude) times speed"
    }
}

/// Whether a letter belongs to a text field right now.
///
/// The shuttle keys are plain letters, as Space and the arrows already are. AppKit hands a
/// key without a modifier to the first responder before it looks for a menu item with that
/// key, so a letter typed into a caption or a label never reaches these menu items — the
/// same ordering Space relies on. This is the belt to that pair of braces: should a menu
/// item ever be reached while a field is being typed into, the letter is handed to the
/// field instead, and playback is left alone.
enum TypingGuard {
    /// Gives `letter` to the text being edited, if there is one. `true` when it did.
    @MainActor
    static func consumed(_ letter: String) -> Bool {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable else { return false }
        text.insertText(letter, replacementRange: text.selectedRange())
        return true
    }
}
