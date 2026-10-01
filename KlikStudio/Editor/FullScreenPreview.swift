import AVFoundation
import CoreMedia
import SwiftUI

/// The edit, filling the screen, the way somebody watching the export will see it.
///
/// Nothing of the editor is left: no timeline, no inspector, no handles over the picture —
/// only the frame on black and a small player bar that gets out of the way. The bar fades
/// once the picture has played untouched for a moment, and the pointer goes with it; moving
/// the mouse brings both back. Click the picture to play or pause, double-click it or press
/// Esc to come back to the editor.
///
/// The picture is the same render as the editor's preview — the same `EditorModel`, the
/// same playhead — so leaving full screen lands on exactly the frame that was showing.
struct FullScreenPreview: View {
    let model: EditorModel
    let session: EditorSession

    @State private var controlsShown = true
    @State private var isOverControls = false
    /// Bumped by every sign of somebody being there, which restarts the countdown to
    /// hiding the bar.
    @State private var activity = 0

    /// How long the bar stays after the last movement while the picture plays.
    private static let linger: Duration = .seconds(2.5)

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .background {
                            if model.hasTransparentBackground { Checkerboard() }
                        }
                        .frame(width: stage(in: proxy.size).width, height: stage(in: proxy.size).height)
                        .accessibilityLabel("Preview")
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { session.present(false) }
            .onTapGesture { model.togglePlayback(); wake() }
            .overlay(alignment: .bottom) {
                if controlsShown {
                    PlayerBar(model: model, session: session) { wake() }
                        .onHover { isOverControls = $0; wake() }
                        .padding(.bottom, 28)
                        .padding(.horizontal, 24)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .onChange(of: stage(in: proxy.size).size, initial: true) { _, size in
                model.previewPaneResized(to: size)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onContinuousHover { phase in
            if case .active = phase { wake() }
        }
        .onChange(of: model.isPlaying) { wake() }
        .task(id: activity) {
            // Hidden only while it plays: a paused picture is being looked at, and the bar
            // is how to carry on.
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled, model.isPlaying, !isOverControls else { return }
            withAnimation(StudioMotion.state) { controlsShown = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func wake() {
        if !controlsShown { withAnimation(StudioMotion.state) { controlsShown = true } }
        activity &+= 1
    }

    /// The whole screen, at the picture's shape.
    private func stage(in size: CGSize) -> CGRect {
        let available = CGRect(origin: .zero, size: size)
        let ratio = model.previewSize
        guard ratio.width > 0, ratio.height > 0, size.width > 0, size.height > 0 else { return available }
        return AVMakeRect(aspectRatio: ratio, insideRect: available)
    }
}

/// The floating bar: where you are, play and pause, and the way out.
private struct PlayerBar: View {
    let model: EditorModel
    let session: EditorSession
    /// Called on any use, so the bar is not hidden from under the hand using it.
    let touched: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                time(Timecode.short(model.playhead))
                Scrubber(model: model, touched: touched)
                time("-" + Timecode.short(max(.zero, model.duration - model.playhead)))
            }

            ZStack {
                HStack(spacing: 6) {
                    sound
                    Spacer()
                    PlayerButton(symbol: "arrow.down.right.and.arrow.up.left",
                                 name: "Exit full screen", help: "Exit full screen (Esc)") {
                        session.present(false)
                    }
                }

                HStack(spacing: 14) {
                    PlayerButton(symbol: "gobackward.5", name: "Back 5 seconds", help: "Back 5 seconds") {
                        model.step(-5); touched()
                    }
                    PlayerButton(symbol: model.isPlaying ? "pause.fill" : "play.fill",
                                 name: model.isPlaying ? "Pause" : "Play",
                                 help: model.isPlaying ? "Pause (Space)" : "Play (Space)",
                                 size: 20, diameter: 44) {
                        model.togglePlayback(); touched()
                    }
                    PlayerButton(symbol: "goforward.5", name: "Forward 5 seconds", help: "Forward 5 seconds") {
                        model.step(5); touched()
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: 680)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(red: 0.05, green: 0.055, blue: 0.08).opacity(0.72))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player controls")
    }

    private func time(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.75))
            .frame(minWidth: 40)
            .accessibilityHidden(true)
    }

    /// Left out for a recording with no sound, as on the transport bar.
    @ViewBuilder
    private var sound: some View {
        if let audio = model.audio, audio.hasSound {
            PlayerButton(symbol: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                         name: audio.isMuted ? "Unmute" : "Mute",
                         help: audio.isMuted ? "Turn the sound on" : "Silence the preview") {
                audio.isMuted.toggle(); touched()
            }
        }
    }
}

/// A round glyph button on the dark bar: white, with a soft disc under it on hover.
private struct PlayerButton: View {
    let symbol: String
    let name: String
    let help: String
    var size: CGFloat = 15
    var diameter: CGFloat = 34
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(.white.opacity(isHovering ? 0.16 : diameter > 40 ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressDown())
        .onHover { isHovering = $0 }
        .animation(StudioMotion.state, value: isHovering)
        .help(help)
        .accessibilityLabel(name)
    }

    private struct PressDown: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}

/// Where the playhead is, out of the whole edit, and a place to drag it.
///
/// Thin until the pointer is on it, so at rest it is a line of progress rather than a
/// control; it thickens and grows a knob when reached for, like every video player's.
private struct Scrubber: View {
    let model: EditorModel
    let touched: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private var fraction: Double {
        let total = model.duration.seconds
        guard total > 0, total.isFinite else { return 0 }
        return min(max(model.playhead.seconds / total, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let raised = isHovering || isDragging
            let track: CGFloat = raised ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                    .frame(height: track)
                Capsule().fill(.white)
                    .frame(width: max(track, width * fraction), height: track)
                Circle().fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .scaleEffect(raised ? 1 : 0.01)
                    .offset(x: width * fraction - 7)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            model.beginScrub()
                        }
                        seek(to: gesture.location.x / max(width, 1))
                    }
                    .onEnded { _ in
                        isDragging = false
                        model.endScrub()
                    }
            )
        }
        .frame(height: 18)
        .onHover { isHovering = $0 }
        .animation(StudioMotion.state, value: isHovering || isDragging)
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(Timecode.short(model.playhead)) of \(Timecode.short(model.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.step(5)
            case .decrement: model.step(-5)
            @unknown default: break
            }
        }
    }

    private func seek(to fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        model.scrub(to: CMTime(seconds: model.duration.seconds * clamped, preferredTimescale: 600))
        touched()
    }
}
