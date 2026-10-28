import CoreMedia
import RecordKit
import SwiftUI
import TimelineKit

/// The bar between the picture and the timeline, in three parts: acting at the playhead on
/// the left, playing it in the middle, and how much of the edit is on screen on the right.
///
/// Every control here acts on the strip directly beneath it, so it takes the middle
/// column's width with the timeline. Play sits in the middle of the column between where
/// you are and how long the edit is, the way a player lays it out, so the one control
/// pressed most is always in the same place whatever the column's width. Undo and redo are
/// about the edit as a whole, not the strip, and live in the title bar.
struct TransportBar: View {
    let model: EditorModel
    /// Plays the edit with the screen to itself. See `FullScreenPreview`.
    var presentFullScreen: () -> Void = {}
    @Environment(StudioSettings.self) private var settings

    static let height: CGFloat = 46

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
            player
            // The right end gives way when the column is narrow, sliders first — rather
            // than the bar refusing to shrink. It did refuse: at the window's narrowest,
            // or back from the full-screen preview in a window that size, the bar was
            // wider than its column and pushed everything beside it, the inspector
            // included, out past the window's edge, where it was cut off.
            ViewThatFits(in: .horizontal) {
                trailing(volumeSlider: true, scaleSlider: true)
                trailing(volumeSlider: false, scaleSlider: true)
                trailing(volumeSlider: false, scaleSlider: false)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        // On the window's ground, like the reference's: the strip of controls belongs to
        // the timeline under it, not to a panel of its own.
        .background(StudioTheme.Surface.seam)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transport")
    }

    /// What acts at the playhead: split, a zoom, zooms where it was clicked.
    private var leading: some View {
        HStack(spacing: 6) {
            barIcon("scissors", help: tip("Split at the playhead", .splitAtPlayhead), name: "Split") {
                model.splitAtPlayhead()
            }
            addZoom
            barIcon("wand.and.stars", help: "Add zooms where the recording was clicked", name: "Auto-zoom") {
                model.suggestZooms()
            }
        }
    }

    /// Where you are, back a cut, play, on a cut, how long it is.
    private var player: some View {
        HStack(spacing: 4) {
            Text(Timecode.precise(model.playhead))
                .foregroundStyle(StudioTheme.Surface.ink)
                .frame(minWidth: 64, alignment: .trailing)
                .accessibilityLabel("Playhead")
            ghost("backward.end.fill", help: tip("Back to the previous cut", .previousCut), name: "Previous cut", isEnabled: true) {
                model.stepToBoundary(forward: false)
            }
            .padding(.leading, 6)
            playButton
            ghost("forward.end.fill", help: tip("On to the next cut", .nextCut), name: "Next cut", isEnabled: true) {
                model.stepToBoundary(forward: true)
            }
            .padding(.trailing, 6)
            Text(Timecode.precise(model.duration))
                .foregroundStyle(StudioTheme.Surface.label.opacity(0.8))
                .frame(minWidth: 64, alignment: .leading)
                .accessibilityLabel("Length")
            if let rate = model.playbackRateLabel {
                rateBadge(rate)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    /// Sound, the timeline's scale and the full-screen preview — with or without their
    /// sliders.
    private func trailing(volumeSlider: Bool, scaleSlider: Bool) -> some View {
        HStack(spacing: 6) {
            if let audio = model.audio, audio.hasSound {
                level(audio, slider: volumeSlider)
                    .padding(.trailing, 6)
            }
            zoom(slider: scaleSlider)
            // At the far end, after the timeline's scale: about the whole window, not
            // the picture, so it sits with the bar rather than on the canvas.
            barIcon("arrow.up.left.and.arrow.down.right",
                    help: "Play full screen (⇧⌘F)",
                    name: "Full screen preview",
                    action: presentFullScreen)
                .padding(.leading, 2)
        }
    }

    // MARK: - Moving through it

    private var playButton: some View {
        Button { model.togglePlayback() } label: {
            // An outlined disc, the reference's player: the one control here that is
            // pressed more than any other is the biggest, without a field round it.
            Image(systemName: model.isPlaying ? "pause.circle" : "play.circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(StudioTheme.Surface.ink)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressStyle())
        .help(tip(model.isPlaying ? "Pause" : "Play", .playPause))
        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
    }

    /// The rate, whenever it is not the ordinary one: J and L run the playhead at 2× and
    /// 4×, either way, and a picture moving at the wrong speed with nothing saying so
    /// reads as a fault.
    private func rateBadge(_ rate: String) -> some View {
        Text(rate)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(StudioTheme.Surface.playhead)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(StudioTheme.Surface.playhead.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("\(model.playbackRateDescription ?? rate). K stops; Space pauses.")
            .accessibilityLabel(model.playbackRateDescription ?? rate)
    }

    // MARK: - Acting at the playhead

    private var addZoom: some View {
        Button { model.addZoomAtPlayhead() } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Zoom")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(StudioTheme.Surface.ink)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(StudioTheme.Surface.field,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressStyle())
        .help("Push in on part of the picture, at the playhead")
        .accessibilityLabel("Add zoom")
    }

    /// A bare glyph, the reference's bar: no field until the pointer is over it.
    private func barIcon(_ symbol: String,
                         help: String,
                         name: String,
                         action: @escaping () -> Void) -> some View {
        StudioIconButton(systemImage: symbol,
                         help: help,
                         accessibilityName: name,
                         iconSize: 14,
                         action: action)
    }

    /// A glyph with nothing round it: previous and next cut.
    private func ghost(_ symbol: String,
                       help: String,
                       name: String,
                       isEnabled: Bool,
                       action: @escaping () -> Void) -> some View {
        StudioIconButton(systemImage: symbol,
                         help: help,
                         accessibilityName: name,
                         size: .small,
                         iconSize: 12.5,
                         action: action)
            .disabled(!isEnabled)
    }

    /// A tooltip with the shortcut as it is set now, which Settings can change — or none,
    /// rather than a key written into the string that stops being true the day somebody
    /// rebinds it.
    private func tip(_ text: String, _ command: EditorCommand) -> String {
        settings.editorShortcuts[command].map { "\(text) (\($0.displayString))" } ?? text
    }

    // MARK: - How loud the preview is

    /// Not a document setting — it changes what this Mac plays while you work and nothing
    /// about the exported file — so it is not undoable and it does not make the project
    /// dirty. Left out entirely for a recording with no sound, rather than shown dead: a
    /// volume slider that does nothing is a question somebody has to ask.
    @ViewBuilder
    private func level(_ audio: PreviewAudio, slider: Bool = true) -> some View {
        @Bindable var audio = audio

        HStack(spacing: 4) {
            // A square button, so the slider beside it does not shift when the speaker's
            // waves change width.
            StudioIconButton(systemImage: audio.isMuted || audio.volume == 0
                                 ? "speaker.slash.fill"
                                 : audio.volume < 0.4 ? "speaker.wave.1.fill" : "speaker.wave.2.fill",
                             help: audio.isMuted ? "Turn the sound on" : "Silence the preview",
                             accessibilityName: audio.isMuted ? "Unmute preview" : "Mute preview",
                             size: .small,
                             iconSize: 11) {
                audio.isMuted.toggle()
            }

            if slider {
                StudioSlider(value: $audio.volume, in: 0...1, size: .small, defaultValue: 1)
                    .frame(width: Self.sliderWidth)
                    .disabled(audio.isMuted)
                    .help("How loud the preview is")
                    .accessibilityLabel("Preview volume")
            }
        }
    }

    // MARK: - How much of the edit is on screen

    /// The timeline's scale. Its glyph is the fit button rather than a magnifying glass:
    /// the glass is already on this bar meaning a *camera* zoom, and two magnifiers a hand
    /// apart meaning two different things is exactly the confusion this row exists to
    /// avoid.
    private func zoom(slider: Bool = true) -> some View {
        HStack(spacing: 8) {
            Button { model.viewport.fit(model.duration) } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(StudioTheme.Surface.inkSoft)
                    .contentShape(Rectangle())
            }
            .buttonStyle(StudioPressStyle())
            .help(tip("Fit the whole edit", .fitTimeline))
            .accessibilityLabel("Fit timeline")

            if slider {
                StudioSlider(value: zoomLevel,
                             in: log2(TimelineViewport.minimumPointsPerSecond)...log2(TimelineViewport.maximumPointsPerSecond),
                             size: .small)
                    .frame(width: 128)
                    .help("How much of the edit the timeline shows")
                    .accessibilityLabel("Timeline scale")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    /// Both sliders one length, so the right end of the bar is two matching controls
    /// rather than a long one and a short one. Long enough to place a value by eye, short
    /// enough to leave the left of the bar its room at the window's narrowest.
    private static let sliderWidth: CGFloat = 96

    /// Bound over the logarithm, so the slider's travel feels even instead of spending
    /// nine tenths of itself in the last few seconds of zoom.
    private var zoomLevel: Binding<Double> {
        Binding {
            log2(model.viewport.pointsPerSecond)
        } set: { level in
            model.viewport.setPointsPerSecond(pow(2, level),
                                              anchoring: model.playhead,
                                              duration: model.duration)
        }
    }
}
