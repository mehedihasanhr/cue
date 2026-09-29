import CoreMedia
import Foundation

public extension Timeline {
    /// Where a voiceover take lands once the talking stops.
    ///
    /// Separated from the recorder on purpose. Everything about capturing narration —
    /// permission, a device, a count-in, a file being written — is untestable by nature,
    /// and the one part that can be silently wrong is this: which moment of the edit the
    /// first syllable belongs to, and what happens to the words spoken after the video
    /// has ended. So that part is arithmetic over values, here, where a test can ask it
    /// questions without a microphone.
    struct VoiceoverPlacement: Equatable, Sendable {
        /// The punch-in point, in timeline time: where the region begins.
        public let start: CMTime
        public let duration: CMTime
        /// Whether the take outran the edit and was cut off at its end.
        ///
        /// Worth reporting rather than swallowing: somebody who kept talking past the
        /// last frame has lost the tail of what they said, and would otherwise find out
        /// by listening back.
        public let wasTrimmed: Bool

        public init(start: CMTime, duration: CMTime, wasTrimmed: Bool) {
            self.start = start
            self.duration = duration
            self.wasTrimmed = wasTrimmed
        }

        /// The same two numbers said the way the rest of the timeline says them, so a
        /// placement can be compared against a clip or a region without unpacking it.
        public var end: CMTime { start + duration }
        public var range: CMTimeRange { CMTimeRange(start: start, duration: duration) }
    }

    /// Fits a take of `recorded` length, punched in at `punchIn`, onto this edit.
    ///
    /// `nil` means there is nowhere to put it — the playhead was at the very end, or the
    /// take was too short to be a region at all. The caller says so rather than dropping
    /// a sliver of sound on the lane that nobody can grab.
    ///
    /// The take is clamped to the end of the edit rather than lengthening it, which is
    /// what `addSound` already does with an imported file: a voiceover is laid *over* a
    /// recording, and a recording that grew because somebody was slow to press Stop
    /// would end on however many seconds of frozen last frame they took to reach for the
    /// mouse. The recorded file keeps its full length in the package, and the region can
    /// be resized from either end afterwards like any other, so nothing said is lost —
    /// it is only not heard past the end of the picture.
    func voiceoverPlacement(punchedInAt punchIn: CMTime, recorded: CMTime) -> VoiceoverPlacement? {
        guard recorded > .zero else { return nil }
        let start = max(.zero, min(punchIn, duration))
        let room = duration - start
        guard room >= Clip.minimumDuration else { return nil }
        return VoiceoverPlacement(start: start,
                                  duration: min(recorded, room),
                                  wasTrimmed: recorded > room)
    }
}
