import CoreMedia
import SwiftUI
import TimelineKit

/// The recording's own sound, on a lane of its own.
///
/// It used to be drawn inside the clips, which said something untrue: that the sound is a
/// property of the picture and goes wherever the picture goes. It *is* cut with the
/// picture — it is the same take — but it is a thing you work on, with its own level, its
/// own mute and its own place to click. Sharing a row with the video left nowhere to put
/// any of that.
///
/// The lane still follows the clips exactly, and deliberately: this is one recording, not
/// two, and a sound that could slide out from under its own footage would be a bug rather
/// than a feature. Sound that *is* free to move — music, a voiceover — is an
/// `AudioRegion`, and gets the ordinary region lane below.
struct TimelineSoundRow: View {
    let model: EditorModel
    let height: CGFloat

    private var viewport: TimelineViewport { model.viewport }
    private var isSelected: Bool { model.selection == .sound }
    private var isMuted: Bool { !model.timeline.sound.isAudible }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .frame(height: height)

            ForEach(Array(model.timeline.clips.enumerated()), id: \.element.id) { index, clip in
                slice(clip, at: index)
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture { model.select(.sound) }
        .contextMenu {
            Button(isMuted ? "Unmute Recording" : "Mute Recording") { toggleMute() }
            Button("Reset Level") { setGain(1) }
                .disabled(model.timeline.sound.gain == 1)
        }
        .help(isMuted ? "The recording's sound is muted" : "The recording's sound")
    }

    /// One clip's worth of sound. Drawn per clip rather than as one strip so a cut is as
    /// visible here as it is on the row above.
    private func slice(_ clip: Clip, at index: Int) -> some View {
        let left = viewport.x(for: model.timeline.start(ofClipAt: index))
        let width = max(4, clip.duration.seconds * viewport.pointsPerSecond)

        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.green.opacity(isSelected ? 0.4 : 0.26))
            .overlay {
                if let peaks = model.waveform.peaks {
                    TimelineWaveform(model: model, peaks: peaks, height: height)
                        .mask {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .frame(width: width)
                                .offset(x: left)
                        }
                        .offset(x: -left)
                        .frame(width: width, alignment: .leading)
                        .clipped()
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
            }
            // Only on the first slice, so a cut-up recording gets one label rather than
            // one per piece.
            .overlay(alignment: .leading) {
                if index == 0 { label.padding(.leading, 6) }
            }
            .opacity(isMuted ? 0.45 : 1)
            .frame(width: width, height: height)
            .offset(x: left)
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "waveform")
                .font(.system(size: 9, weight: .semibold))
            if model.timeline.sound.gain != 1, !isMuted {
                Text("\(Int((model.timeline.sound.gain * 100).rounded()))%")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.28), in: Capsule())
        .allowsHitTesting(false)
    }

    // MARK: - Edits

    private func toggleMute() {
        let muted = model.timeline.sound.isMuted
        model.apply(Commands.Restyle(muted ? "Unmute" : "Mute") { $0.sound.isMuted = !muted })
    }

    private func setGain(_ gain: Double) {
        model.apply(Commands.Restyle("Level") { $0.sound.gain = gain })
    }
}
