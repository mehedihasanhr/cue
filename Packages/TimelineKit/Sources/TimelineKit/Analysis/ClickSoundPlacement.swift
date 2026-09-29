import CoreGraphics
import CoreMedia

/// One click, heard: when in the edit, and which button.
public struct ClickSoundMoment: Equatable, Sendable {
    public let time: CMTime
    public let isSecondary: Bool

    public init(time: CMTime, isSecondary: Bool) {
        self.time = time
        self.isSecondary = isSecondary
    }
}

extension Timeline {
    /// Two clicks closer than this are heard as one. Only a sped-up stretch gets them this
    /// close, and a sound for each is a buzz rather than two clicks.
    public static let clickSoundSpacing = 0.04

    /// Where each click is heard in the edit.
    ///
    /// A click is a moment in the recording, and the edit may have cut it, sped it up or
    /// used it twice. It is heard wherever it is *seen*: once for every clip that shows it,
    /// at that clip's pace, and not at all where it was cut. The sound's own length is not
    /// sped up with the clip — a click at twice the speed is still a click.
    ///
    /// The picture decides, not the sound lane. A click is something that happens on the
    /// screen, so detaching the recording's sound and sliding it about does not move the
    /// clicks with it.
    ///
    /// Silent where the pointer is hidden, by the project or by a stretch that hides it:
    /// the viewer is being asked to look at something else, and a click out of nowhere
    /// pulls them back.
    public func clickSoundMoments(for clicks: [CursorTrack.Click]) -> [ClickSoundMoment] {
        guard cursor.isVisible, cursor.clickSound, !clicks.isEmpty else { return [] }

        var heard: [ClickSoundMoment] = []
        for click in clicks {
            let source = CMTime(seconds: click.t, preferredTimescale: 60_000)
            var elapsed = CMTime.zero
            for clip in clips {
                defer { elapsed = elapsed + clip.duration }
                // Never over an imported clip: its source times are another file's.
                guard clip.playsRecording, source >= clip.sourceStart, source < clip.sourceEnd else { continue }
                let time = elapsed + CMTimeMultiplyByFloat64(source - clip.sourceStart, multiplier: 1 / clip.speed)
                guard cursorOverride(at: time).hiding < 0.5 else { continue }
                heard.append(ClickSoundMoment(time: time, isSecondary: click.isSecondary))
            }
        }
        heard.sort { $0.time < $1.time }

        var spaced: [ClickSoundMoment] = []
        for moment in heard {
            if let last = spaced.last, (moment.time - last.time).seconds < Self.clickSoundSpacing { continue }
            spaced.append(moment)
        }
        return spaced
    }

    /// The clicks a viewer can see: those inside the crop.
    ///
    /// A click on a part of the screen the edit has cropped away draws no ring and no
    /// pointer — `SceneBuilder` drops both there — so its sound would be a click out of
    /// nowhere. The same test the renderer makes, so the two cannot disagree about which
    /// clicks are in the picture.
    ///
    /// - Parameter frame: the recording's size in the points the clicks are measured in.
    public func visibleClicks(_ clicks: [CursorTrack.Click], frame: CGSize) -> [CursorTrack.Click] {
        let crop = style.crop?.rect ?? CropRect.full.rect
        guard frame.width > 0, frame.height > 0, crop.width > 0, crop.height > 0 else { return clicks }
        return clicks.filter { click in
            let u = (click.point.x / frame.width - crop.minX) / crop.width
            let v = (click.point.y / frame.height - crop.minY) / crop.height
            return (0...1).contains(u) && (0...1).contains(v)
        }
    }
}
