import AppKit
import AVFoundation
import RecordKit
import SwiftUI

/// The floating recorder bar.
///
/// What the app *is* when it opens: one strip over whatever you are about to record. It
/// has two shapes — the full set of choices before a take, and, once recording, nothing
/// but the timer and the two things you might do next. A bar that keeps offering
/// "Window / Area / Device" while it is recording is offering decisions that no longer
/// apply, and taking up the screen it is recording to do it.
struct RecorderBar: View {
    @Environment(StudioService.self) private var studio
    @Environment(StudioSettings.self) private var settings
    let model: RecorderModel
    let close: () -> Void
    let showLibrary: () -> Void
    let openSettings: () -> Void
    /// Raises the screen-filling overlay that names what was chosen. Record lives there
    /// now, so choosing a mode and starting a take are two halves of one gesture.
    let showTargets: (RecorderModel.Mode) -> Void
    @Namespace private var modeChip
    @State private var setupWidth: CGFloat?
    @State private var recordingWidth: CGFloat?

    /// The bar has two shapes, and it should travel between them rather than cut.
    ///
    /// An `if`/`else` inside the `HStack` made the two shapes *neighbours* for the length
    /// of the transition: the outgoing wide layout and the incoming narrow one sat side by
    /// side, so the bar visibly slid left rather than closing in. Both layouts live here
    /// permanently instead — the unused one transparent and untouchable — which lets the
    /// bar know both of its widths and animate an explicit one between them. A `ZStack`
    /// centres what it holds, so the wide shape now contracts from both edges onto the
    /// small one.
    var body: some View {
        ZStack {
            setupControls
                .padding(.horizontal, 10)
                .fixedSize()
                .background(BarSizeReporter { setupWidth = $0.width })
                .opacity(isRecording ? 0 : 1)
                .allowsHitTesting(!isRecording)
                .accessibilityHidden(isRecording)

            recordingControls
                .padding(.horizontal, 10)
                .fixedSize()
                .background(BarSizeReporter { recordingWidth = $0.width })
                .opacity(isRecording ? 1 : 0)
                .allowsHitTesting(isRecording)
                .accessibilityHidden(!isRecording)
        }
        .frame(width: barWidth, height: StudioPalette.barHeight)
        .background {
            // Behind everything and hit-testable, so a drag anywhere the controls do not
            // claim moves the panel.
            WindowDragBackground()
        }
        .studioGlass(cornerRadius: StudioPalette.barRadius)
        .clipShape(RoundedRectangle(cornerRadius: StudioPalette.barRadius, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 26, y: 12)
        .animation(StudioMotion.shape, value: isRecording)
        // Also covers the quieter change: the display's name arriving from
        // ScreenCaptureKit widens the setup bar a second after it opens.
        .animation(StudioMotion.shape, value: barWidth)
    }

    /// Nil until the two halves have measured themselves, so the very first frame is the
    /// bar's own ideal width rather than nothing at all.
    private var barWidth: CGFloat? {
        isRecording ? recordingWidth : setupWidth
    }

    private var isRecording: Bool {
        switch studio.session.state {
        case .recording, .paused, .finishing: true
        default: false
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.11))
            .frame(width: 1, height: 42)
            .padding(.horizontal, 10)
    }

    // MARK: - Before a take

    private var setupControls: some View {
        HStack(spacing: 0) {
            closeButton
            separator
            modes
            separator
            inputs
            separator
            settingsMenu
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.9), in: Circle())
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.88))
        .help("Close the recorder")
        .padding(.leading, 4)
    }

    private var modes: some View {
        HStack(spacing: 4) {
            ForEach(RecorderModel.Mode.allCases) { mode in
                ModeButton(mode: mode,
                           isSelected: model.mode == mode,
                           isAvailable: mode.isAvailable,
                           chip: modeChip) {
                    model.choose(mode)
                    showTargets(mode)
                }
            }
        }
        // The highlight used to vanish from one tile and appear on another, which reads
        // as two events. One chip that slides says the same thing as a single move, and
        // points at where the choice went.
        .animation(StudioMotion.selection, value: model.mode)
    }

    /// Camera, microphone and system audio — each saying what it is doing.
    ///
    /// These were icon-only, on the argument that a slash reads as "no" everywhere on the
    /// system. It does; what it does not do is say *which* microphone, or distinguish "no
    /// system audio" from "no camera" at a glance on a bar you only look at for a second
    /// before pressing record. The words cost width the bar can now afford, because the
    /// display picker and the record button moved to the overlay.
    private var inputs: some View {
        HStack(spacing: 4) {
            InputChip(symbol: "video.slash",
                      onSymbol: "video.fill",
                      size: 15,
                      isOn: settings.recordsCamera,
                      isAvailable: false,
                      label: model.cameraLabel) {}

            InputChipMenu(symbol: "mic.slash",
                          onSymbol: "mic.fill",
                          size: 15,
                          isOn: settings.recordsMicrophone,
                          label: model.microphoneLabel) {
                microphoneMenu
            }

            InputChip(symbol: "music.note.tv",
                      onSymbol: "music.note.tv.fill",
                      size: 16,
                      isOn: settings.recordsSystemAudio,
                      isAvailable: true,
                      label: settings.recordsSystemAudio ? "System audio" : "No system audio") {
                settings.recordsSystemAudio.toggle()
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var microphoneMenu: some View {
        @Bindable var settings = settings
        Toggle("Record microphone", isOn: $settings.recordsMicrophone)
        if !model.microphones.isEmpty {
            Divider()
            Picker("Input", selection: $settings.microphoneID) {
                Text("System default").tag("")
                ForEach(model.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            .pickerStyle(.inline)
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button("Recordings…") { showLibrary() }
            Button("Settings…") { openSettings() }
            Divider()
            Picker("Countdown", selection: countdown) {
                Text("No countdown").tag(0)
                ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15))
                .foregroundStyle(StudioPalette.offered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .frame(width: 44)
        .padding(.trailing, 6)
    }

    private var countdown: Binding<Int> {
        Binding { settings.countdownSeconds } set: { settings.countdownSeconds = $0 }
    }

    // MARK: - During a take

    /// Timer, pause, stop, discard — and nothing else.
    private var recordingControls: some View {
        HStack(spacing: 10) {
            timer
            separator
            Button { studio.togglePause() } label: {
                Image(systemName: studio.session.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(StudioMotion.state, value: studio.session.isPaused)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(BarButtonStyle())
            .help(studio.session.isPaused ? "Resume" : "Pause")

            Button { studio.stop() } label: {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white)
                    .frame(width: 13, height: 13)
                    .frame(width: 38, height: 38)
                    .background(.red, in: Circle())
            }
            .buttonStyle(BarButtonStyle())
            .help("Stop and keep this recording")

            Button { studio.cancel() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(BarButtonStyle())
            .help("Discard this recording")
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var timer: some View {
        switch studio.session.state {
        case .recording(let started):
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                elapsed(RecorderModel.elapsed(since: started, at: context.date), blinking: true)
            }
        case .paused(let started, let pausedAt):
            elapsed(RecorderModel.elapsed(since: started, at: pausedAt), blinking: false)
        case .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finishing…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 8)
        default:
            // Laid out but never drawn. The recording layout now lives in the hierarchy
            // full time so the bar can measure it, and without this it measures ~70pt
            // narrower than it will be the instant a take starts — so pressing Record
            // contracted the bar too far and then popped it back open.
            elapsed("0:00", blinking: false).hidden()
        }
    }

    private func elapsed(_ text: String, blinking: Bool) -> some View {
        HStack(spacing: 9) {
            RecordingDot(color: studio.session.isPaused ? Color.orange : Color.red,
                         isBreathing: blinking)
            Text(text)
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                // A slot wide enough for "00:00". Without it the bar grows by a digit at
                // ten seconds and again at ten minutes — and now that it holds its own
                // centre, it would step sideways on both edges each time it did.
                .frame(minWidth: 48, alignment: .leading)
        }
        .padding(.leading, 8)
    }
}

// MARK: - Pieces

/// One of Display / Window / Area / Device.
private struct ModeButton: View {
    let mode: RecorderModel.Mode
    let isSelected: Bool
    let isAvailable: Bool
    let chip: Namespace.ID
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: mode.symbol)
                    .font(.system(size: mode.symbolSize, weight: .regular))
                    // One slot for four glyphs of four shapes. Without it each sets its
                    // own row height and the labels beneath stop sharing a line.
                    .frame(width: 26, height: 19)
                Text(mode.title).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(isAvailable ? (isSelected ? StudioPalette.chosen : StudioPalette.offered)
                                         : StudioPalette.unavailable)
            .frame(width: 62, height: 56)
            .background {
                if isSelected {
                    // The one chip, matched across the row: choosing a mode moves it
                    // rather than extinguishing one tile and lighting another.
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.white.opacity(0.14))
                        .matchedGeometryEffect(id: "selected", in: chip)
                } else if isHovering, isAvailable {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.white.opacity(0.07))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!isAvailable)
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
        .help(isAvailable ? mode.help : "\(mode.title) isn't built yet")
    }
}

/// Camera / microphone / system audio: an icon, and what it is doing.
private struct InputChip: View {
    let symbol: String
    let onSymbol: String
    let size: CGFloat
    let isOn: Bool
    let isAvailable: Bool
    let label: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            InputChipLabel(symbol: isOn ? onSymbol : symbol, size: size,
                           isOn: isOn, isAvailable: isAvailable, isHovering: isHovering, label: label)
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.97))
        .disabled(!isAvailable)
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
        .help(isAvailable ? label : "\(label) — not built yet")
    }
}

/// The same chip, where the choice is a device rather than on/off.
private struct InputChipMenu<Content: View>: View {
    let symbol: String
    let onSymbol: String
    let size: CGFloat
    let isOn: Bool
    let label: String
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        Menu {
            content
        } label: {
            InputChipLabel(symbol: isOn ? onSymbol : symbol, size: size,
                           isOn: isOn, isAvailable: true, isHovering: isHovering, label: label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
        .help(label)
    }
}

private struct InputChipLabel: View {
    let symbol: String
    /// Per input, not per row. A camcorder, a microphone and a screen with a note on it
    /// are drawn to different heights at one point size, and the row read as three sizes.
    /// 15 inks the camera and the microphone at 15.75pt tall; the audio glyph needs 16 to
    /// reach the same line. Both faces of one input share a size, so toggling it never
    /// resizes the glyph.
    let size: CGFloat
    let isOn: Bool
    let isAvailable: Bool
    let isHovering: Bool
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(isAvailable ? (isOn ? StudioPalette.chosen : StudioPalette.offered)
                                     : StudioPalette.unavailable)
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(isHovering && isAvailable ? AnyShapeStyle(.white.opacity(0.08)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .animation(StudioMotion.state, value: isOn)
    }
}

/// The "this is live" dot.
///
/// It was a hard 0.35 ⇄ 1 step sampled off the timer's clock. At two flips a second that
/// is a strobe, not a pulse: it pulls the eye off the thing being recorded, and it is the
/// shape of oscillation the motion-sensitivity guidance exists to discourage. A breath of
/// the same period says the same thing and stops asking for attention.
private struct RecordingDot: View {
    let color: Color
    let isBreathing: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .opacity(dim ? 0.4 : 1)
            .animation(breath, value: dim)
            .onAppear { dim = isBreathing }
            .onChange(of: isBreathing) { _, breathing in dim = breathing }
    }

    private var breath: Animation {
        isBreathing && !StudioMotion.reduceMotion
            ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.2)
    }
}


/// Makes the bar draggable by its own background.
///
/// `isMovableByWindowBackground` alone is not enough: SwiftUI's hosting view swallows the
/// mouse-down before AppKit can treat it as a window drag. A plain `NSView` that says its
/// area can move the window — and hands any drag straight to the panel — restores the
/// behaviour anyone expects from a floating strip.
private struct WindowDragBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
