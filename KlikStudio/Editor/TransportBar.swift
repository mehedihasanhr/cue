import CoreMedia
import RecordKit
import SwiftUI
import TimelineKit

/// The slim bar between the picture and the timeline: playing it, where you are in it,
/// cutting it, and how loud and how close the work is.
///
/// It used to be a column in the corner beside the timeline — play controls at the top,
/// then a tall empty gap, then the volume and the timeline zoom at the bottom — which cost
/// the timeline the width of the settings column and said nothing at all with most of its
/// height. One row across the full window is how Final Cut and Screen Studio do it, and
/// for the same reason: every control here acts on the strip directly beneath it, and the
/// strip gets the whole width of the window, which is the one measurement that decides how
/// finely an edit can be placed.
///
/// Left to right in the order the hand reaches for them: move through the edit, read where
/// you are, act at the playhead, then — set apart at the far end — the two settings that
/// change what you are looking at rather than the edit itself.
///
/// What is *not* here: the aspect menu and the Crop button. Both are a frame setting, both
/// already live in the inspector, and a control duplicated across the window is a control
/// somebody has to check.
struct TransportBar: View {
    let model: EditorModel
    /// Plays the edit with the screen to itself. See `FullScreenPreview`.
    var presentFullScreen: () -> Void = {}
    @Environment(StudioSettings.self) private var settings

    /// Tall enough for a row of 28-point glyphs with a little air, and no taller: this bar
    /// is a seam between the picture and the timeline, not a third panel.
    static let height: CGFloat = 40

    var body: some View {
        HStack(spacing: 0) {
            playback
            timecode
                .padding(.leading, 10)

            divider

            editing

            Spacer(minLength: 16)

            if let audio = model.audio, audio.hasSound {
                level(audio)
                divider
            }
            zoom
            divider
            StudioIconButton(systemImage: "arrow.up.left.and.arrow.down.right",
                             help: "Play full screen (⇧⌘F)",
                             accessibilityName: "Full screen preview",
                             size: .small,
                             iconSize: 11,
                             action: presentFullScreen)
        }
        .padding(.horizontal, SidebarMetrics.contentInset - 4)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .studioSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transport")
    }

    private var divider: some View {
        StudioDivider(axis: .vertical, length: 16)
            .padding(.horizontal, 10)
    }

    // MARK: - Moving through it

    /// One size, all ghost squircles — nothing drawn round a glyph until the pointer is on
    /// it. Controls that all act at the playhead should look like the same kind of thing.
    /// Play is the exception, filled in the accent: it is the control the hand goes to
    /// first, and the one this bar is for.
    private var playback: some View {
        HStack(spacing: 2) {
            glyph("backward.end.fill", help: tip("Previous frame", .previousFrame), name: "Previous frame") {
                model.stepFrame(forward: false)
            }

            glyph(model.isPlaying ? "pause.fill" : "play.fill",
                  help: tip(model.isPlaying ? "Pause" : "Play", .playPause),
                  name: model.isPlaying ? "Pause" : "Play",
                  variant: .primary,
                  size: 12) { model.togglePlayback() }
                .padding(.horizontal, 2)

            glyph("forward.end.fill", help: tip("Next frame", .nextFrame), name: "Next frame") {
                model.stepFrame(forward: true)
            }

            // The rate, whenever it is not the ordinary one: J and L run the playhead at
            // 2× and 4×, either way, and a picture moving at the wrong speed with nothing
            // saying so reads as a fault.
            if let rate = model.playbackRateLabel {
                Text(rate)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(StudioPalette.brand)
                    .padding(.horizontal, 5)
                    .frame(height: 18)
                    .background(StudioPalette.brand.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(.leading, 4)
                    .help("\(model.playbackRateDescription ?? rate). K stops; Space pauses.")
                    .accessibilityLabel(model.playbackRateDescription ?? rate)
            }
        }
    }

    /// Where the playhead is, out of how long the edit is.
    ///
    /// Hundredths on both sides, because frame-stepping is one of the three buttons beside
    /// it: a clock that only counts whole seconds does not move when you press Next Frame,
    /// and a button that changes nothing reads as a button that is broken. Monospaced
    /// digits so the numbers tick in place instead of shuffling the bar sideways while the
    /// edit plays, and fixed in size so the row never truncates it.
    private var timecode: some View {
        HStack(spacing: 4) {
            Text(Timecode.precise(model.playhead))
                .foregroundStyle(.primary)
            Text("/")
                .foregroundStyle(.tertiary)
            Text(Timecode.precise(model.duration))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(Timecode.precise(model.playhead)) of \(Timecode.precise(model.duration))")
    }

    // MARK: - Acting at the playhead

    private var editing: some View {
        HStack(spacing: 2) {
            glyph("scissors", help: tip("Split at the playhead", .splitAtPlayhead), name: "Split") {
                model.splitAtPlayhead()
            }

            StudioActionMenu(actions: [
                .init("Add Zoom at Playhead", systemImage: "plus.magnifyingglass") { model.addZoomAtPlayhead() },
                .init("Auto-Zoom from Clicks", systemImage: "cursorarrow.click.2") { model.suggestZooms() },
            ], style: .studio(.ghost, isIconOnly: true)) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
            }
            .help("Push in on part of the picture")
            .accessibilityLabel("Add zoom")
        }
    }

    /// A tooltip with the shortcut as it is set now, which Settings can change — or none,
    /// rather than a key written into the string that stops being true the day somebody
    /// rebinds it.
    private func tip(_ text: String, _ command: EditorCommand) -> String {
        settings.editorShortcuts[command].map { "\(text) (\($0.displayString))" } ?? text
    }

    /// One control: a `StudioIconButton`, the same 28-point squircle as the title bar's
    /// glyphs, so the rows of icons in this window are one size.
    private func glyph(_ symbol: String,
                       help: String,
                       name: String,
                       variant: StudioButtonStyle.Variant = .ghost,
                       size: CGFloat = 13,
                       action: @escaping () -> Void) -> some View {
        StudioIconButton(systemImage: symbol,
                         help: help,
                         accessibilityName: name,
                         variant: variant,
                         iconSize: size,
                         action: action)
    }

    // MARK: - How loud the preview is

    /// Not a document setting — it changes what this Mac plays while you work and nothing
    /// about the exported file — so it is not undoable and it does not make the project
    /// dirty. Left out entirely for a recording with no sound, rather than shown dead: a
    /// volume slider that does nothing is a question somebody has to ask.
    @ViewBuilder
    private func level(_ audio: PreviewAudio) -> some View {
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

            StudioSlider(value: $audio.volume, in: 0...1, size: .small, defaultValue: 1)
                .frame(width: Self.sliderWidth)
                .disabled(audio.isMuted)
                .help("How loud the preview is")
                .accessibilityLabel("Preview volume")
        }
    }

    // MARK: - How much of the edit is on screen

    /// The timeline's scale. Its glyph is the fit button rather than a magnifying glass:
    /// the glass is already on this bar meaning a *camera* zoom, and two magnifiers a hand
    /// apart meaning two different things is exactly the confusion this row exists to
    /// avoid.
    private var zoom: some View {
        HStack(spacing: 4) {
            StudioIconButton(systemImage: "arrow.left.and.right",
                             help: tip("Fit the whole edit", .fitTimeline),
                             accessibilityName: "Fit timeline",
                             size: .small,
                             iconSize: 11) {
                model.viewport.fit(model.duration)
            }

            StudioSlider(value: zoomLevel,
                         in: log2(TimelineViewport.minimumPointsPerSecond)...log2(TimelineViewport.maximumPointsPerSecond),
                         size: .small)
                .frame(width: Self.sliderWidth)
                .help("How much of the edit the timeline shows")
                .accessibilityLabel("Timeline scale")
        }
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
