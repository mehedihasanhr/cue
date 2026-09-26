import CoreMedia
import SwiftUI
import TimelineKit

/// What can be cut, and how much of the edit the timeline is showing.
///
/// A column in the corner beside the timeline rather than a bar across the window. Every
/// control here acts on the strip to its right — the playhead, the split, how far the
/// ruler is zoomed — so it sits against it, and the timeline keeps the full width of the
/// window, which is the one measurement that decides how finely an edit can be placed.
///
/// What is *not* here: the aspect menu and the Crop button. Both are a frame setting,
/// both already live in the panel directly above this one, and a control duplicated eight
/// inches away is a control somebody has to check.
struct TransportBar: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls
            Spacer(minLength: 0)
            if let audio = model.audio, audio.hasSound {
                level(audio)
            }
            zoom
        }
        .padding(.horizontal, SidebarMetrics.contentInset)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .studioSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline tools")
    }

    // MARK: - Playing it, and cutting it

    /// One row, one size, all glyphs — no capsules, no discs, nothing outlined. Five
    /// controls that all act at the playhead should look like five of the same thing,
    /// and the chrome around each one was more pixels than the icons it framed.
    private var controls: some View {
        HStack(spacing: 4) {
            glyph("backward.end.fill", help: "Previous frame") { model.step(-1 / 30) }

            glyph(model.isPlaying ? "pause.fill" : "play.fill",
                  help: model.isPlaying ? "Pause (Space)" : "Play (Space)",
                  tint: StudioPalette.brand,
                  size: 15) { model.togglePlayback() }

            glyph("forward.end.fill", help: "Next frame") { model.step(1 / 30) }

            StudioDivider(axis: .vertical, length: 16).padding(.horizontal, 4)

            glyph("scissors", help: "Split at the playhead (⌘B)", name: "Split") {
                model.splitAtPlayhead()
            }

            Menu {
                Button("Add Zoom at Playhead") { model.addZoomAtPlayhead() }
                Button("Auto-Zoom from Clicks") { model.suggestZooms() }
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Push in on part of the picture")
            .accessibilityLabel("Zoom")

            Spacer(minLength: 0)
        }
    }

    /// One control: a glyph that lights up under the pointer. The same 28-point square
    /// the editor's title bar uses, so the two rows of icons in this window are one size.
    private func glyph(_ symbol: String,
                       help: String,
                       name: String? = nil,
                       tint: Color? = nil,
                       size: CGFloat = 13,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: 28, height: 28)
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .help(help)
        .accessibilityLabel(name ?? help)
    }

    // MARK: - How loud the preview is

    /// Not a document setting — it changes what this Mac plays while you work and nothing
    /// about the exported file — so it is not undoable and it does not make the project
    /// dirty.
    @ViewBuilder
    private func level(_ audio: PreviewAudio) -> some View {
        @Bindable var audio = audio

        HStack(spacing: 8) {
            Button { audio.isMuted.toggle() } label: {
                Image(systemName: audio.isMuted || audio.volume == 0
                      ? "speaker.slash.fill"
                      : audio.volume < 0.4 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(BarButtonStyle())
            .help(audio.isMuted ? "Turn the sound on" : "Silence the preview")

            StudioSlider(value: $audio.volume, in: 0...1)
                .disabled(audio.isMuted)
                .help("How loud the preview is")
        }
    }

    // MARK: - How much of the edit is on screen

    private var zoom: some View {
        HStack(spacing: 8) {
            Button { model.viewport.fit(model.duration) } label: {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(BarButtonStyle())
            .help("Fit the whole edit (⌘0)")

            StudioSlider(value: zoomLevel,
                         in: log2(TimelineViewport.minimumPointsPerSecond)...log2(TimelineViewport.maximumPointsPerSecond))
                .help("How much of the edit the timeline shows")
        }
    }

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
