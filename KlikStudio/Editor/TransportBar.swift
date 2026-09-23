import CoreMedia
import SwiftUI
import TimelineKit

/// Play, step, cut, and how much of the edit the timeline is showing.
///
/// Three zones with the transport laid *over* the middle rather than between two
/// spacers, so the play button sits in the centre of the window instead of the centre of
/// whatever space the other two happen to leave.
struct TransportBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 120)
            trailing
        }
        .overlay { transport }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Leading

    @ViewBuilder
    private var leading: some View {
        Menu {
            ForEach(AspectPreset.allCases, id: \.self) { preset in
                Button {
                    // The same undo name the inspector's Shape picker uses: two controls
                    // for one setting must not produce two words in the Undo menu.
                    model.apply(Commands.Restyle("Shape") { $0.style.aspect = preset })
                } label: {
                    Label(preset.displayName, systemImage: preset.symbolName)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.timeline.style.aspect.symbolName)
                Text(model.timeline.style.aspect.displayName)
            }
        }
        .menuStyle(.button)
        .studioButton()
        .fixedSize()
        .help("The shape of the finished video")

        Button {
            model.tool = model.tool == .crop ? .frame : .crop
        } label: {
            Label("Crop", systemImage: "crop")
        }
        .studioButton()
        .background {
            if model.tool == .crop {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
            }
        }
        .help("Choose the part of the recording to show")

        if model.timeline.style.crop != nil {
            Button {
                model.setCrop(nil)
            } label: {
                HStack(spacing: 4) {
                    Text("Cropped")
                    Image(systemName: "xmark.circle.fill")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Show the whole recording again")
        }
    }

    // MARK: - Centre

    private var transport: some View {
        HStack(spacing: 14) {
            Button { model.step(-1 / 30) } label: { Image(systemName: "backward.frame.fill") }
                .studioButton()
                .help("Previous frame")

            Button { model.togglePlayback() } label: {
                ZStack {
                    Circle().fill(StudioPalette.brand)
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(BarButtonStyle())
            .help(model.isPlaying ? "Pause" : "Play")

            Button { model.step(1 / 30) } label: { Image(systemName: "forward.frame.fill") }
                .studioButton()
                .help("Next frame")

            Text("\(Timecode.precise(model.playhead)) / \(Timecode.precise(model.duration))")
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .fixedSize()
        }
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailing: some View {
        Button { model.splitAtPlayhead() } label: { Image(systemName: "scissors") }
            .studioButton()
            .help("Split at the playhead (⌘B)")

        Menu {
            Button("Add Zoom at Playhead") { model.addZoomAtPlayhead() }
            Button("Auto-Zoom from Clicks") { model.suggestZooms() }
        } label: {
            Image(systemName: "plus.magnifyingglass")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .studioButton()
        .fixedSize()
        .help("Push in on part of the picture")

        Divider().frame(height: 16)

        Button { model.viewport.fit(model.duration) } label: {
            Image(systemName: "arrow.left.and.right")
        }
        .studioButton()
        .help("Fit the whole edit (⌘0)")

        Slider(value: zoomLevel, in: log2(TimelineViewport.minimumPointsPerSecond)...log2(TimelineViewport.maximumPointsPerSecond))
            .controlSize(.small)
            .frame(width: 92)
            .help("How much of the edit the timeline shows")
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
