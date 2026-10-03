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
    /// Whether the bar has arrived on screen — false for the instant before it springs in.
    @State private var hasArrived = false

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
        /// Restart was asked for a take long enough to be worth asking about.
        case confirmRestart
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
            layer(.confirmRestart) { confirmRestartControls }
        }
        .frame(width: barWidth, height: StudioPalette.barHeight)
        .background {
            ZStack {
                // Behind everything and hit-testable, so a drag anywhere the controls do
                // not claim moves the panel.
                WindowDragBackground()
                // Coloured smoke in the glass, saying what the bar is doing before a word
                // of it is read — once there is something to say. Before a take the glass is
                // plain and neutral: a tint over somebody's desktop while nothing is
                // happening read as decoration, not information.
                if mood != .ready { BarSmoke(mood: mood) }
            }
        }
        .studioGlass(cornerRadius: StudioPalette.barRadius)
        .clipShape(RoundedRectangle(cornerRadius: StudioPalette.barRadius, style: .continuous))
        .overlay {
            if mood != .ready { BarEdgeLight(mood: mood, cornerRadius: StudioPalette.barRadius) }
        }
        // One soft shadow, small enough to end inside the window. A wide one was cut off
        // flat at the window's edges, and a coloured one spread a smudge over a white page.
        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        .animation(StudioMotion.shape, value: shape)
        // Also covers the quieter change: the display's name arriving from
        // ScreenCaptureKit widens the setup bar a second after it opens.
        .animation(StudioMotion.shape, value: barWidth)
        .animation(.easeInOut(duration: 0.8), value: mood)
        // Springs in each time it is shown, rather than being there all at once.
        .scaleEffect(hasArrived ? 1 : 0.94, anchor: .bottom)
        .offset(y: hasArrived ? 0 : 10)
        .opacity(hasArrived ? 1 : 0)
        .blur(radius: hasArrived ? 0 : 6)
        .onAppear(perform: arrive)
        .onChange(of: model.presentations) { _, _ in arrive() }
    }

    private func arrive() {
        guard !StudioMotion.reduceMotion else {
            hasArrived = true
            return
        }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { hasArrived = false }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { hasArrived = true }
        }
    }

    /// The light's colour for what the session is doing.
    private var mood: BarMood {
        switch shape {
        case .setup: .ready
        case .starting: .live
        case .take: studio.session.isPaused ? .held : .live
        case .failure, .confirmRestart: .alert
        }
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
        // Asked over the take it would throw away, which is paused while it asks.
        if studio.restartPending, studio.session.state.isTaking { return .confirmRestart }
        return switch studio.session.state {
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
            .fill(.white.opacity(0.1))
            .frame(width: 1, height: 38)
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
            recordButton
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            // A solid white disc with a dark cross, the system's own close for a floating
            // HUD: the one control on the bar that is not about the recording, set apart by
            // being the one solid thing on it.
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Color(white: 0.12))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.92), in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.88))
        .help("Close the recorder")
        .padding(.leading, 8)
        .padding(.trailing, 2)
    }

    /// The four modes in one inset strip, with one glass chip that slides to the choice.
    private var modes: some View {
        HStack(spacing: 6) {
            ForEach(RecorderModel.Mode.allCases) { mode in
                ModeButton(mode: mode,
                           accent: mood.accent,
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
            InputChipMenu(accent: mood.accent,
                          symbol: "video.slash",
                          onSymbol: "video.fill",
                          isOn: settings.recordsCamera,
                          label: model.cameraLabel) {
                cameraMenu
            }

            InputChipMenu(accent: mood.accent,
                          symbol: "mic.slash",
                          onSymbol: "mic.fill",
                          isOn: settings.recordsMicrophone,
                          label: model.microphoneLabel) {
                microphoneMenu
            }
            // Only once a microphone is on and allowed: the meter listens to it, and this
            // bar never opens a microphone nobody chose.
            if let meter = RecorderCenter.shared?.meter, meter.isListening, !studio.session.state.isTaking {
                MicrophoneMeterView(source: meter, length: 24, thickness: 5, vertical: true)
                    .padding(.trailing, 6)
                    .help("Microphone level")
                    .transition(.opacity)
            }

            InputChipMenu(accent: mood.accent,
                          symbol: "music.note.tv",
                          onSymbol: "music.note.tv.fill",
                          isOn: settings.recordsSystemAudio,
                          label: SystemAudioApps.label(isOn: settings.recordsSystemAudio,
                                                       chosen: settings.systemAudioAppIDs)) {
                systemAudioMenu
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
    /// only moment: the preview beside the bar shows a camera already allowed, and asks
    /// nothing itself.
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
            // Toggles rather than a picker: a take can record several microphones, each to
            // its own file and its own lane in the editor, so "which one" is the wrong
            // question. Nothing ticked means the system's default input.
            Section("Inputs") {
                ForEach(model.microphones, id: \.uniqueID) { device in
                    Toggle(device.localizedName, isOn: Binding(
                        get: { settings.microphoneIDs.contains(device.uniqueID) },
                        set: { settings.setMicrophone(device.uniqueID, isOn: $0) }
                    ))
                }
            }
            .disabled(!settings.recordsMicrophone)
        }
    }

    /// On or off, and whose sound.
    ///
    /// A menu for the reason the microphone's is one: "system audio" is everything the Mac
    /// plays, and the take that wants the demo's sound usually does not want the chat
    /// app's notification or the music in the background. Ticking apps narrows it to
    /// them; "Every App" puts it back. An app that is not running is still listed once
    /// chosen, marked as such, so it can be unticked — it is not heard in a take that
    /// starts without it, because ScreenCaptureKit can only listen to an app that exists.
    @ViewBuilder
    private var systemAudioMenu: some View {
        @Bindable var settings = settings
        Toggle("Record system audio", isOn: $settings.recordsSystemAudio)
        Divider()
        Section("Hear") {
            Toggle("Every App", isOn: Binding(
                get: { settings.systemAudioAppIDs.isEmpty },
                set: { if $0 { settings.systemAudioAppIDs = [] } }
            ))
            ForEach(SystemAudioApps.entries(chosen: settings.systemAudioAppIDs)) { app in
                Toggle(app.isRunning ? app.name : "\(app.name) (not running)", isOn: Binding(
                    get: { settings.systemAudioAppIDs.contains(app.bundleID) },
                    set: { settings.setSystemAudioApp(app.bundleID, isOn: $0) }
                ))
            }
        }
        .disabled(!settings.recordsSystemAudio)
    }

    /// The way forward from here, always in the same place: records straight away when
    /// there is something to record, and otherwise asks what — the same as choosing the
    /// mode again.
    private var recordButton: some View {
        Button {
            if model.canRecord {
                model.record()
            } else {
                model.choose(model.mode)
                showTargets(model.mode)
            }
        } label: {
            RecordGlyph()
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.9))
        .disabled(studio.session.state.isBusy)
        .help(model.canRecord ? settings.recorder.help("Start recording", .record)
                              : "Choose what to record")
        .padding(.leading, 4)
        .padding(.trailing, 4)
    }

    private var settingsMenu: some View {
        Menu {
            Button("Recordings…") { showLibrary() }
            Button("Settings…") { openSettings() }
            Divider()
            Toggle("Speaker Notes", isOn: Binding { settings.recorder.showsSpeakerNotes }
                   set: { settings.recorder.showsSpeakerNotes = $0 })
            Toggle("Hide Desktop Icons", isOn: Binding { settings.recorder.hidesDesktopIcons }
                   set: { settings.recorder.hidesDesktopIcons = $0 })
            Divider()
            Picker("Countdown", selection: countdown) {
                Text("No countdown").tag(0)
                ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            // The whole round button is the label, in the button menu style with a plain
            // button, as the input chips are: as a borderless menu with the circle drawn
            // behind it, only the glyph took the click, and often not even that.
            SettingsGlyph()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recordings, settings and countdown")
        .padding(.trailing, 4)
    }

    private var countdown: Binding<Int> {
        Binding { settings.countdownSeconds } set: { settings.countdownSeconds = $0 }
    }

    // MARK: - During a take

    /// Timer, pause, stop, discard — and nothing else.
    ///
    /// Three groups, in the order a take is thought about: how long and what is live; the
    /// two things that decide the take, pause and a red Stop that is plainly the way out;
    /// and the quieter extras — a marker, a restart, the bin — as matching round glass.
    private var recordingControls: some View {
        HStack(spacing: 8) {
            timer
            takeMeter
            cameraLive
            diskWarning
            separator
            Button { studio.togglePause() } label: {
                BarCircleIcon(symbol: studio.session.isPaused ? "play.fill" : "pause.fill",
                              size: 13, prominent: true)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(StudioMotion.state, value: studio.session.isPaused)
            }
            .buttonStyle(BarButtonStyle())
            .disabled(!studio.session.state.isTaking)
            .help(settings.recorder.help(studio.session.isPaused ? "Resume" : "Pause", .pause))

            Button { studio.stop() } label: {
                StopPill()
            }
            .buttonStyle(BarButtonStyle(pressedScale: 0.95))
            // The same property the bridge's `stop()` guards on, which is the whole point of
            // it having a name. These two used to disagree about `.paused`: the button was
            // live, the guard refused, and the take went to the bin.
            .disabled(!studio.session.state.isTaking)
            .help(settings.recorder.help("Stop and keep this recording", .record))

            separator

            markerButton
            restartButton

            Button { studio.cancel() } label: {
                BarCircleIcon(symbol: "trash", size: 12, hoverTint: .red)
            }
            .buttonStyle(BarButtonStyle())
            // The same predicate again, and for a sharper reason than the other two: this
            // layout also covers `.finishing`, where the manifest is being written and the
            // file closed. Discarding the package out from under that is a race, and it was
            // reachable before — nothing here was ever disabled. Abandoning a *countdown*
            // is a different button, on the layout that owns that state.
            .disabled(!studio.session.state.isTaking)
            .help("Discard this recording")
            .padding(.trailing, 2)
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
    /// Read off the session's own apparatus rather than off `recordsCamera`: a host's
    /// request can switch the camera off for one take while the preference still says yes,
    /// and an indicator about a camera that is right most of the time is worse than none.
    /// Dimmed while paused, because the session is still open but nothing is reaching the
    /// file.
    @ViewBuilder
    private var cameraLive: some View {
        // `isTaking` as well, so this goes away the moment Stop is pressed: `.finishing` is
        // the file being closed, and the camera has already been let go of by then.
        if studio.session.isRecordingCamera, studio.session.state.isTaking {
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
            // Once a second, on the second the take began: the clock shows whole seconds, and
            // four redraws a second of a glass bar over the thing being recorded is three
            // that change nothing.
            TimelineView(.periodic(from: started, by: 1)) { context in
                elapsed(RecorderModel.elapsed(since: started, at: context.date))
            }
        case .paused(let started, let pausedAt):
            elapsed(RecorderModel.elapsed(since: started, at: pausedAt))
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
            elapsed("0:00").hidden()
        }
    }

    /// The time, in a capsule of the take's own colour: red while it runs, amber while it
    /// is held — with the word, because a stopped clock alone looks like a stuck one.
    private func elapsed(_ text: String) -> some View {
        let paused = studio.session.isPaused
        let tint = paused ? BarMood.held.accent : BarMood.live.accent
        return HStack(spacing: 8) {
            RecordingDot(color: tint)
            Text(text)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                // A slot wide enough for "00:00". Without it the bar grows by a digit at
                // ten seconds and again at ten minutes — and now that it holds its own
                // centre, it would step sideways on both edges each time it did.
                .frame(minWidth: 46, alignment: .leading)
            if paused {
                Text("PAUSED")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(tint)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(tint.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
        .animation(StudioMotion.state, value: paused)
        .padding(.leading, 4)
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
            Circle().stroke(.white.opacity(0.12), lineWidth: 2.5)
            // What is left of the countdown, draining a step each second.
            if let remaining = studio.session.state.countdownRemaining {
                Circle()
                    .trim(from: 0, to: Double(remaining) / Double(max(1, settings.countdownSeconds)))
                    .stroke(BarMood.live.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: remaining)
            }
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
            // A device is woken and asked for its first picture here, which can take a
            // moment longer than the Mac's own screen — worth saying which is happening.
            return model.mode == .device ? "Waiting for the device\u{2019}s picture." : "Setting up the screen and the encoder."
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
                BarCircleIcon(symbol: "xmark", size: 10.5)
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
                .background(.white.opacity(0.1), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.96))
    }
}

// MARK: - Markers, restart and the meter

extension RecorderBar {
    /// Drops a marker, and says how many this take has.
    fileprivate var markerButton: some View {
        Button { studio.addMarker() } label: {
            BarCircleIcon(symbol: "flag.fill", size: 12, count: studio.session.markerCount)
                .animation(StudioMotion.state, value: studio.session.markerCount)
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!studio.session.state.isTaking)
        .help(settings.recorder.help("Add a marker here, to find this moment in the editor", .marker))
    }

    /// Throws this take away and starts again with the same target and settings.
    fileprivate var restartButton: some View {
        Button { studio.requestRestart() } label: {
            BarCircleIcon(symbol: "arrow.counterclockwise", size: 12.5)
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!studio.session.state.isTaking)
        .help(settings.recorder.help("Start this take again", .restart))
    }

    /// The microphone, while it is being recorded: the same meter the setup bar shows,
    /// read off the take itself.
    @ViewBuilder
    fileprivate var takeMeter: some View {
        if let meter = RecorderCenter.shared?.meter, meter.source == .take, studio.session.state.isTaking {
            HStack(spacing: 5) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(studio.session.isPaused ? Color.orange : .white.opacity(0.75))
                MicrophoneMeterView(source: meter, length: 40, thickness: 5)
                    .opacity(studio.session.isPaused ? 0.4 : 1)
            }
            .help(studio.session.isPaused ? "Microphone level \u{2014} not recorded while paused" : "Microphone level")
            .transition(.opacity)
        }
    }

    /// Asked before a take longer than ten seconds is thrown away. The take is paused
    /// while this is up, so the time spent deciding is not in it if it is kept.
    fileprivate var confirmRestartControls: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(.orange)
                .padding(.leading, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text("Start this take again?")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("The \(RecorderModel.length(studio.session.state.recordedSeconds(at: .now))) recorded so far will be thrown away.")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioPalette.offered)
            }
            .lineLimit(1)
            .frame(width: 250, alignment: .leading)

            separator

            pill("Keep Recording") { studio.keepTake() }
                .help("Carry on with this take")
            Button { studio.restart() } label: {
                Text("Restart")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(LinearGradient(colors: [Color(red: 1, green: 0.33, blue: 0.35), Color(red: 0.86, green: 0.13, blue: 0.17)],
                                               startPoint: .top, endPoint: .bottom),
                                in: Capsule())
            }
            .buttonStyle(BarButtonStyle(pressedScale: 0.96))
            .help(settings.recorder.help("Throw this take away and count down again", .restart))
            .padding(.trailing, 2)
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Pieces

/// One of Display / Window / Area / Device.
private struct ModeButton: View {
    let mode: RecorderModel.Mode
    /// The bar's colour, which the chosen mode wears.
    let accent: Color
    let isSelected: Bool
    let isAvailable: Bool
    let chip: Namespace.ID
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // A square tile with the glyph alone: the four shapes say which is which, and a
            // bar of icons sits more quietly over somebody's work than one of words. Fitted
            // to one height rather than set at a point size: a monitor, a window, a dashed box
            // and a phone are four shapes, and at one size each inks to a different height.
            Image(systemName: mode.symbol)
                .resizable()
                .scaledToFit()
                .fontWeight(.light)
                .frame(height: BarIcon.mode)
                .frame(width: 30)
            .foregroundStyle(isAvailable ? (isSelected ? Color.white.opacity(0.95) : StudioPalette.offered)
                                         : StudioPalette.unavailable)
            .frame(width: 44, height: 44)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if isSelected {
                    // The one chip, matched across the row: choosing a mode moves it rather
                    // than extinguishing one tile and lighting another. A pane of lighter
                    // glass and nothing more — no colour, so the choice reads without
                    // shouting over the desktop behind the bar.
                    shape
                        .fill(.white.opacity(0.1))
                        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.02)],
                                                                   startPoint: .top, endPoint: .bottom)))
                        .matchedGeometryEffect(id: "selected", in: chip)
                } else if isHovering, isAvailable {
                    shape.fill(.white.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!isAvailable)
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
        .help(mode.title)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Camera / microphone / system audio: an icon, what it is doing, and a menu of which
/// device — or, for system audio, which apps.
private struct InputChipMenu<Content: View>: View {
    let accent: Color
    let symbol: String
    let onSymbol: String
    let isOn: Bool
    let label: String
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        // The button menu style with a plain button: the label is drawn by SwiftUI, as
        // written. The borderless menu style hands its label to AppKit, which keeps only a
        // glyph and a title — the lit pane and the dimmed "off" went missing — and an
        // invisible menu laid over the chip instead never took the click.
        Menu {
            content
        } label: {
            InputChipLabel(accent: accent, symbol: isOn ? onSymbol : symbol,
                           isOn: isOn, isAvailable: true, isHovering: isHovering, label: label)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // One element for VoiceOver — "No camera, menu button" — rather than the glyph and
        // the words as two.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
        .help(label)
    }
}

private struct InputChipLabel: View {
    let accent: Color
    let symbol: String
    let isOn: Bool
    let isAvailable: Bool
    let isHovering: Bool
    let label: String

    var body: some View {
        HStack(spacing: 9) {
            // One height for the three, for the reason the modes' glyphs have one.
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .fontWeight(.light)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: BarIcon.input)
                .frame(width: 26)
        }
        // Words and a glyph on the glass, with no pane: on is plain white, off is the
        // same dimmed white the unchosen modes are. What will be recorded still reads
        // across the room — by brightness and by the glyph losing its slash — without three
        // coloured boxes competing with the one thing the bar is for.
        .foregroundStyle(isAvailable ? (isOn ? Color.white : StudioPalette.offered)
                                     : StudioPalette.unavailable)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(isHovering && isAvailable ? 0.07 : 0))
        }
        .contentShape(Rectangle())
        .animation(StudioMotion.state, value: isOn)
    }
}

/// A round glass button's face: the bar's secondary actions, all one size and one
/// manner, brightening under the pointer. A count rides alongside when there is one —
/// the markers dropped so far — and widens the circle into a capsule to hold it.
private struct BarCircleIcon: View {
    let symbol: String
    var size: CGFloat = 12.5
    /// Pause: the one secondary action that decides the take, a step brighter.
    var prominent = false
    /// The colour it turns under the pointer, for the one that destroys something.
    var hoverTint: Color?
    var count = 0
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(isHovering ? (hoverTint ?? .white) : .white.opacity(prominent ? 0.95 : 0.8))
        .padding(.horizontal, count > 0 ? 10 : 0)
        .frame(minWidth: 34, minHeight: 34)
        .background(fill, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.07)))
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering && isEnabled }
        }
    }

    private var fill: Color {
        if isHovering, let hoverTint { return hoverTint.opacity(0.18) }
        let base = prominent ? 0.14 : 0.08
        return .white.opacity(isHovering ? base + 0.07 : base)
    }
}

/// Stop: a red capsule with the stop square and the word, so the way out of a take is the
/// one unmistakable thing on the bar.
private struct StopPill: View {
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(.white)
                .frame(width: 10, height: 10)
            Text("Stop")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(LinearGradient(colors: [Color(red: 1, green: 0.33, blue: 0.35), Color(red: 0.86, green: 0.13, blue: 0.17)],
                                   startPoint: .top, endPoint: .bottom),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        .shadow(color: .red.opacity(isHovering ? 0.5 : 0.25), radius: isHovering ? 8 : 4)
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
    }
}

/// The heights the bar's glyphs are fitted to.
private enum BarIcon {
    static let mode: CGFloat = 22
    static let input: CGFloat = 18
}

/// The red record button: a red disc in a fine white ring, brightening under the pointer.
private struct RecordGlyph: View {
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.white.opacity(isHovering ? 0.95 : 0.8), lineWidth: 2)
            Circle()
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.3, blue: 0.3), Color(red: 0.86, green: 0.1, blue: 0.13)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(isHovering ? 4 : 5)
        }
        .frame(width: 34, height: 34)
        // A small, tight glow: a lamp on the control, not a light thrown over the desktop.
        .shadow(color: .red.opacity(isHovering ? 0.45 : 0.2), radius: isHovering ? 6 : 3)
        .contentShape(Circle())
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
    }
}

/// The settings menu's face: a gear and a chevron, bare on the glass like the inputs, so
/// it reads as "more choices" rather than as one more button.
private struct SettingsGlyph: View {
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gearshape")
                .font(.system(size: 19, weight: .light))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.white.opacity(isHovering ? 0.95 : 0.7))
        .padding(.horizontal, 9)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(isHovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
    }
}

/// The "this is live" dot: red while recording, amber while held.
///
/// Still, not breathing. A repeating animation redraws the whole bar at the display's rate
/// for the length of the take, and the clock beside it already says the take is live.
private struct RecordingDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
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
