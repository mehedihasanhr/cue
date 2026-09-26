import AppKit
import AVFoundation
import RecordKit
import SwiftUI

/// The floating recorder bar.
///
/// What the app *is* when it opens: one strip over whatever you are about to record. It
/// has four shapes, and each one shows only what applies to it. A bar that keeps offering
/// "Window / Area / Device" while it is recording is offering decisions that no longer
/// apply, and taking up the screen it is recording to do it.
///
/// Two of the four are new, and they are new because the session had states the bar drew
/// nothing for. Pressing Record left the setup layout on screen with Record already dead
/// and the target overlay gone — three silent seconds in which nothing said a recording
/// was coming or offered to call it off. And a take that failed said nothing at all: the
/// bar went back to offering another one as though the first had never happened.
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
    /// What each shape measured itself at, so the bar can animate an explicit width
    /// between them. One entry per shape rather than a property each, because the shapes
    /// are a closed set and the widths are all the same kind of thing.
    @State private var widths: [Shape: CGFloat] = [:]

    /// The four things the bar can be. Every state of the session maps onto exactly one of
    /// them — `SessionStateTests` holds that to be true, because a state with no shape is
    /// precisely the bug this replaced: it draws the wrong layout and says nothing.
    private enum Shape: Hashable {
        /// Before a take: what to record, and with what.
        case setup
        /// Getting ready and counting down. Nothing is written yet.
        case starting
        /// Recording, held, or finishing.
        case take
        /// It went wrong, and the reason has to be readable.
        case failure
    }

    /// The bar travels between its shapes rather than cutting between them.
    ///
    /// An `if`/`else` inside the `HStack` made two shapes *neighbours* for the length of the
    /// transition: the outgoing wide layout and the incoming narrow one sat side by side, so
    /// the bar visibly slid left rather than closing in. The layouts live here permanently
    /// instead — the unused ones transparent and untouchable — which lets the bar know each
    /// of its widths and animate an explicit one between them. A `ZStack` centres what it
    /// holds, so a wide shape contracts from both edges onto a small one.
    var body: some View {
        ZStack {
            layer(.setup) { setupControls }
            layer(.take) { recordingControls }
            layer(.starting) { startingControls }
            // Mounted with a stand-in when nothing has failed, for the same reason the
            // hidden timer below exists: an unmeasured layer has no width, so the bar would
            // spend the frame a failure arrives at its own ideal width — the widest thing in
            // the stack — and then animate down from it. The message block is a fixed width
            // by design, so the stand-in measures within a few points of the real thing.
            layer(.failure) { failureControls(studio.session.state.failure ?? .targetDisappeared) }
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
        .animation(StudioMotion.shape, value: shape)
        // Also covers the quieter change: the display's name arriving from
        // ScreenCaptureKit widens the setup bar a second after it opens.
        .animation(StudioMotion.shape, value: barWidth)
    }

    /// One layer of the stack: laid out and measured whether or not it is the one showing,
    /// transparent and untouchable when it is not.
    @ViewBuilder
    private func layer<Content: View>(_ layerShape: Shape, @ViewBuilder content: () -> Content) -> some View {
        let showing = shape == layerShape
        content()
            .padding(.horizontal, 10)
            .fixedSize()
            .background(BarSizeReporter { widths[layerShape] = $0.width })
            .opacity(showing ? 1 : 0)
            .allowsHitTesting(showing)
            .accessibilityHidden(!showing)
    }

    /// Nil until that shape has measured itself, so the very first frame is the bar's own
    /// ideal width rather than nothing at all.
    private var barWidth: CGFloat? {
        widths[shape]
    }

    /// Written as an exhaustive switch on purpose. The old version asked "is this
    /// recording?" and let `default` answer for everything else, which is how `.preparing`,
    /// `.countdown` and `.failed` all ended up drawing the setup bar. A switch with no
    /// `default` makes a new state a build error here rather than a wrong layout.
    private var shape: Shape {
        switch studio.session.state {
        case .preparing, .countdown: .starting
        case .recording, .paused, .finishing: .take
        case .failed: .failure
        // `.finished` deliberately has no shape of its own. The take is written and the
        // editor is already coming up over the bar; what the bar owes the user at that
        // point is to be ready for the next one.
        case .idle, .finished: .setup
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
            InputChipMenu(symbol: "video.slash",
                          onSymbol: "video.fill",
                          size: 15,
                          isOn: settings.recordsCamera,
                          label: model.cameraLabel) {
                cameraMenu
            }

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

    /// On or off, and which camera.
    ///
    /// A menu rather than a plain toggle, because the device matters here even more than it
    /// does for the microphone: a Mac with a built-in camera, a display camera and an iPhone
    /// on the desk has three, and recording a face through the wrong one is not a mistake
    /// anybody notices until the export.
    ///
    /// The toggle goes through `model.setCamera` rather than binding straight at the
    /// setting, because turning the camera on is the moment to ask for permission — and the
    /// only moment, since nothing in this app opens a camera to preview it.
    @ViewBuilder
    private var cameraMenu: some View {
        @Bindable var settings = settings
        Toggle("Record camera", isOn: Binding { settings.recordsCamera } set: { model.setCamera($0) })
        if model.cameraDenied {
            Divider()
            Button("Allow Camera in Settings…") { model.openCameraSettings() }
        }
        if !model.cameras.isEmpty {
            Divider()
            Picker("Camera", selection: $settings.cameraID) {
                Text("System default").tag("")
                ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            .pickerStyle(.inline)
        }
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
            cameraLive
            diskWarning
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
            .disabled(!studio.session.state.isTaking)
            .help(studio.session.isPaused ? "Resume" : "Pause")

            Button { studio.stop() } label: {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white)
                    .frame(width: 13, height: 13)
                    .frame(width: 38, height: 38)
                    .background(.red, in: Circle())
            }
            .buttonStyle(BarButtonStyle())
            // The same property the bridge's `stop()` guards on, which is the whole point of
            // it having a name. These two used to disagree about `.paused`: the button was
            // live, the guard refused, and the take went to the bin.
            .disabled(!studio.session.state.isTaking)
            .help("Stop and keep this recording")

            Button { studio.cancel() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(BarButtonStyle())
            // The same predicate again, and for a sharper reason than the other two: this
            // layout also covers `.finishing`, where the manifest is being written and the
            // file closed. Discarding the package out from under that is a race, and it was
            // reachable before — nothing here was ever disabled. Abandoning a *countdown*
            // is a different button, on the layout that owns that state.
            .disabled(!studio.session.state.isTaking)
            .help("Discard this recording")
        }
        .padding(.horizontal, 6)
        .animation(StudioMotion.state, value: studio.session.diskWarning)
    }

    /// The camera, while it is filming.
    ///
    /// The bar's other chips say what *will* happen; this says what is happening, and it is
    /// here because a camera is a camera. The system's own green indicator is the ground
    /// truth, but it is a two-pixel dot next to the lens, and the user is looking at this
    /// strip. So while a take is running with the camera on, the bar says so in words, in
    /// the same place the elapsed time is.
    ///
    /// Read off the state, not off a flag of our own: the layout only exists in `.recording`,
    /// `.paused` and `.finishing`, and `recordsCamera` is what put a `webcamID` on the
    /// configuration this take is running under. Dimmed while paused, because the camera's
    /// session is still open but nothing is reaching the file.
    @ViewBuilder
    private var cameraLive: some View {
        if settings.recordsCamera, studio.session.state.isTaking || studio.session.state == .finishing {
            HStack(spacing: 5) {
                Image(systemName: "video.fill")
                    .font(.system(size: 11))
                Text(studio.session.isPaused ? "Camera held" : "Camera on")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(studio.session.isPaused ? Color.orange : Color.green)
            .transition(.opacity)
        }
    }

    /// The disk running out, said while there is still time to do something about it.
    ///
    /// The session has published this from the beginning and nothing has ever drawn it, so
    /// the first the user heard about a full disk was the recording stopping by itself. It
    /// sits next to the timer because that is where the eye already is during a take.
    @ViewBuilder
    private var diskWarning: some View {
        if let warning = studio.session.diskWarning {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 12))
                Text(warning)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.orange)
            .transition(.opacity)
        }
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

// MARK: - Getting ready

extension RecorderBar {
    /// What is about to happen, how long there is left, and a way out.
    ///
    /// The three seconds between pressing Record and the first frame used to show the setup
    /// bar with a dead Record button on it. The countdown exists so that everything
    /// expensive — permission, content, the writer, the encoder — happens while the user is
    /// getting out of the way; a bar that does not say so is a bar that looks broken for as
    /// long as it takes.
    fileprivate var startingControls: some View {
        HStack(spacing: 12) {
            startingDial

            VStack(alignment: .leading, spacing: 2) {
                Text(startingHeadline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(startingDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioPalette.offered)
            }
            .lineLimit(1)
            // A slot, not a fit: "Starts in 3 seconds" and "Starts in 1 second" are
            // different widths, and the bar must not step sideways once a second while it
            // counts.
            .frame(width: 210, alignment: .leading)

            separator

            // Cancel rather than Stop. Nothing has been written yet, so there is nothing to
            // keep and nothing to lose — and this is the only moment where changing your
            // mind costs the user nothing at all.
            pill("Cancel") { studio.cancel() }
                // Escape as well as the button, because that is what Escape means over a
                // screen that is about to be recorded — but gated on the state rather than
                // on the layout. Every layer of the stack stays mounted so the bar can
                // measure it, and `allowsHitTesting(false)` hides a button from the mouse
                // without hiding its shortcut from the keyboard: ungated, Escape would reach
                // this while a take was running and discard it.
                .keyboardShortcut(.cancelAction)
                .disabled(!studio.session.state.isStarting)
                .help("Don\u{2019}t record after all")
        }
        .padding(.horizontal, 6)
    }

    /// The number, or a spinner for the moment before there is a number.
    ///
    /// `.preparing` can last anything from nothing to a second — it is asking
    /// ScreenCaptureKit for the screen and building an encoder — and a bar that shows
    /// nothing at all through it is the same silence the countdown was added to break.
    private var startingDial: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: 2)
            if let remaining = studio.session.state.countdownRemaining {
                Text("\(remaining)")
                    .font(.system(size: 19, design: .monospaced).weight(.medium))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(StudioMotion.state, value: remaining)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 38, height: 38)
        .padding(.leading, 6)
    }

    private var startingHeadline: String {
        guard studio.session.state.countdownRemaining != nil else { return "Getting ready\u{2026}" }
        let target = model.targetLabel.isEmpty ? "the screen" : model.targetLabel
        return "Recording \(target)"
    }

    private var startingDetail: String {
        guard let remaining = studio.session.state.countdownRemaining else {
            return "Setting up the screen and the encoder."
        }
        return remaining == 1 ? "Starts in 1 second" : "Starts in \(remaining) seconds"
    }
}

// MARK: - When it goes wrong

extension RecorderBar {
    /// What failed, in the system's own words, and somewhere to go about it.
    ///
    /// `.failed` was drawn by nothing, so a recording that could not start — no screen
    /// permission, a window that closed, a full disk — put the bar back to offering another
    /// take with no explanation at all. `RecordingError` has always carried one case per
    /// thing a user can act on, and a recovery suggestion for the ones with an obvious next
    /// step; none of it had ever reached a screen.
    fileprivate func failureControls(_ error: RecordingError) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.orange)
                .padding(.leading, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(error.errorDescription ?? "The recording stopped.")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(error.recoverySuggestion ?? Self.fallbackSuggestion)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioPalette.offered)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Fixed, because the bar is a strip over someone's screen: a writer error
            // quoting AVFoundation verbatim would otherwise stretch it past the edge of
            // the display.
            .frame(width: 290, alignment: .leading)

            separator

            // The pane the user actually needs. Screen and microphone are two different
            // lists in System Settings, and sending someone to the wrong one means sending
            // them to a switch that is already on.
            switch error {
            case .permissionDenied:
                pill("Open Settings") { model.openScreenRecordingSettings() }
            case .microphoneDenied:
                pill("Open Settings") { model.openMicrophoneSettings() }
            case .cameraDenied:
                pill("Open Settings") { model.openCameraSettings() }
            default:
                // Somewhere to go even when there is nothing to fix. An interruption
                // finishes the file rather than discarding it, so for a good half of these
                // there is a take in the library to go and look at.
                pill("Recordings\u{2026}") { showLibrary() }
            }

            Button { studio.dismissFailure() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(BarButtonStyle())
            .help("Dismiss")
            .padding(.trailing, 2)
        }
        .padding(.horizontal, 6)
    }

    /// For the cases with no suggestion of their own — a window that closed, a device that
    /// went away. It says what became of the file, which is the question anyone asks first.
    private static var fallbackSuggestion: String {
        "Nothing was written. Choose what to record and try again."
    }

    /// The bar's one text button. Quiet enough to sit on glass over someone's screen, and
    /// the same shape wherever it appears.
    fileprivate func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.96))
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
