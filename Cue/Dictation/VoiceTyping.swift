import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Talking into any app: hold the talk key (or tap it), speak, and what was said is tidied
/// and pasted where the caret was. The critter shows in a small pill at the bottom of the
/// screen while Cue listens, and goes when the words are in.
///
/// - Hold the key: listens for as long as it is held, pauses and all; letting go ends it.
/// - Tap the key: listens hands-free until a pause; a second tap ends it sooner.
/// - Esc: stops and throws it away, while listening or while the words are worked out.
///
/// The key is watched with event monitors, which cost nothing while no key changes; the
/// microphone and the recogniser run only while Cue listens (see `DictationService`).
@MainActor
final class VoiceTyping {
    static let shared = VoiceTyping()

    private let id = UUID()
    private weak var preferences: AppPreferences?
    private var monitors: [Any] = []
    private var keyIsDown = false
    private var pressedAt = Date.distantPast
    /// Another key went down while the talk key was held: a shortcut, not talking.
    private var interrupted = false
    private var holdTask: Task<Void, Never>?
    /// The microphone is being opened (the first time, macOS asks whether it may be).
    private var starting = false
    /// The current dictation is the key being held: letting go ends it, a pause does not.
    private var heldDictation = false
    /// Counts dictations, so one that was cancelled while its words were worked out does
    /// not hide the pill of the next or paste anything.
    private var dictation = 0
    private var field: FrontField?
    private var panel: NSPanel?
    private let model = VoiceTypingModel()
    private var hotkey: TalkHotkey?

    /// How long the key is held before Cue starts listening; a shorter press is a tap.
    private static let holdDelay: Duration = .milliseconds(280)
    private static let tapLength: TimeInterval = 0.28
    /// Let go this soon after being pressed, a hold that had only just begun listening was
    /// meant as a tap: Cue carries on hands-free instead of typing a fraction of a word.
    private static let shortHold: TimeInterval = 0.5

    private var service: DictationService { .shared }

    func configure(_ preferences: AppPreferences) {
        self.preferences = preferences
        update()
    }

    /// What dictation is set to and whether it is listening for the key, for
    /// `cue://debug/dictation` — written where a test can read it, since Cue's own
    /// settings live inside its sandbox.
    var debugSummary: String {
        let preferences = preferences
        let key = preferences?.voiceTypingKey
        return """
        voice typing on: \(preferences?.voiceTypingEnabled ?? false)
        key monitors installed: \(monitors.count)
        talk key: \(key.map { String(describing: $0) } ?? "none")  shortcut: \(preferences?.voiceTypingShortcut.map { String(describing: $0) } ?? "none")  hotkey registered: \(hotkey != nil)
        key down: \(keyIsDown)  starting: \(starting)  held dictation: \(heldDictation)
        accessibility trusted: \(AXIsProcessTrusted())
        pill on screen: \(panel?.isVisible ?? false)
        """
    }

    /// Follows Settings › Dictation: the key watched or not.
    func update() {
        guard let preferences else { return }
        if preferences.voiceTypingEnabled { installMonitors() } else { removeMonitors(); cancel() }
        // A recorded shortcut is a Carbon hot key of its own, which reports its release too.
        hotkey = nil
        if preferences.voiceTypingEnabled, preferences.voiceTypingKey == .shortcut, let combo = preferences.voiceTypingShortcut {
            hotkey = TalkHotkey(combo, pressed: { [weak self] in self?.pressed() }, released: { [weak self] in self?.released() })
        }
    }

    // MARK: The key

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let flags: (NSEvent) -> Void = { [weak self] event in MainActor.assumeIsolated { self?.flagsChanged(event) } }
        let keys: (NSEvent) -> Void = { [weak self] event in MainActor.assumeIsolated { self?.keyDown(event) } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(global) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(local) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func flagsChanged(_ event: NSEvent) {
        guard let key = preferences?.voiceTypingKey, let code = key.keyCode, let flag = key.flag else {
            // A recorded shortcut: another modifier changing while it is held is just part of it.
            return
        }
        guard event.keyCode == code else {
            if keyIsDown { interrupt() }
            return
        }
        let down = event.modifierFlags.contains(flag)
        if down, !keyIsDown { pressed() } else if !down, keyIsDown { released() }
    }

    /// The talk key went down: listening starts if it is still held a moment later.
    private func pressed() {
        guard !keyIsDown else { return }
        keyIsDown = true
        interrupted = false
        pressedAt = .now
        holdTask?.cancel()
        // Already listening (a tap started it): letting go ends it.
        guard service.state == .idle, !starting else { return }
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled, let self, keyIsDown, !interrupted, service.state == .idle else { return }
            await startListening(held: true)
        }
    }

    /// The talk key came up: done talking after a hold or a second tap; a first tap
    /// starts listening hands-free.
    private func released() {
        guard keyIsDown else { return }
        keyIsDown = false
        holdTask?.cancel()
        guard !interrupted else { return }
        let held = Date.now.timeIntervalSince(pressedAt)
        if service.isListening(id) {
            if heldDictation, held < Self.shortHold {
                listenHandsFree()
            } else {
                Task { await finishAndPaste() }
            }
        } else if starting {
            // `startListening` sees the key is up once the microphone is open.
        } else if held < Self.tapLength, service.state == .idle {
            Task { await startListening(held: false) }
        }
    }

    private func keyDown(_ event: NSEvent) {
        if keyIsDown { interrupt() }
        // Esc stops listening, or drops the words still being worked out.
        if Int(event.keyCode) == kVK_Escape, service.owner == id { cancel() }
    }

    /// The talk key was part of a shortcut: whatever it started is not talking.
    private func interrupt() {
        interrupted = true
        holdTask?.cancel()
        if service.isListening(id), Date.now.timeIntervalSince(pressedAt) < 1 { cancel() }
    }

    // MARK: Listening

    /// "Hey Siri, talk to Cue" (`TalkToCueIntent`). A beat first, for Siri's panel to go and
    /// for Siri to let go of the microphone, so the words go to the app that was in front.
    func startFromSiri() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, service.state == .idle else { return }
            await startListening(held: false)
        }
    }

    /// Opens the microphone. `held`: for as long as the key is held; otherwise until a pause.
    private func startListening(held: Bool) async {
        guard service.state == .idle, !starting else { return }
        starting = true
        dictation += 1
        heldDictation = held
        // Where the words go: the app in front and its focused field, before anything changes.
        field = FrontField.capture()
        model.phase = .listening
        showPanel()
        let started = await service.start(for: id, onPause: held ? nil : endOnPause)
        starting = false
        guard started else {
            heldDictation = false
            hidePanel()
            return
        }
        // Let go while the microphone was opening (macOS asking for it the first time):
        // nothing would end a held dictation now, so it carries on hands-free.
        if held, !keyIsDown { listenHandsFree() }
    }

    /// The current dictation ends at the next pause rather than when the key comes up.
    private func listenHandsFree() {
        heldDictation = false
        service.endOnPause(for: id, endOnPause)
    }

    private var endOnPause: () -> Void {
        { [weak self] in Task { await self?.finishAndPaste() } }
    }

    private func finishAndPaste() async {
        guard service.isListening(id) else { return }
        let current = dictation
        heldDictation = false
        model.phase = .writing
        let text = await service.finish(for: id)
        // Cancelled while the words were worked out: the pill went then, and may be the next one's.
        guard current == dictation else { return }
        hidePanel()
        if let text { paste(text) }
    }

    func cancel() {
        holdTask?.cancel()
        heldDictation = false
        dictation += 1
        if service.owner == id { service.cancel() }
        hidePanel()
    }

    /// The words at the caret: through the pasteboard and ⌘V, as a snippet is, with
    /// what was on the pasteboard put back afterwards. Without Accessibility Cue cannot
    /// press ⌘V for you, so the words stay on the pasteboard to paste yourself.
    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard PermissionManager.hasAccessibilityAccess else {
            FeedbackHUD.show("Copied what you said", symbol: "doc.on.clipboard",
                             subtitle: "Allow Cue in Accessibility to paste it for you.")
            return
        }
        // Cue never took the keyboard (the pill does not activate), so the app that was in
        // front when the talking started is still there, unless the person moved on while
        // the words were worked out. Then macOS will not hand the keyboard back to it, and
        // ⌘V would land in whatever is in front now: the words wait on the pasteboard.
        if let app = field?.app, NSWorkspace.shared.frontmostApplication != app {
            FeedbackHUD.show("Copied what you said", symbol: "doc.on.clipboard",
                             subtitle: "\(app.localizedName ?? "The app") is no longer in front. Paste it with ⌘V.")
            return
        }
        // The history need not keep it: it is already where it was meant to go.
        pasteboard.setData(Data(), forType: Clipboard.ownMarker)
        let ours = pasteboard.changeCount
        ClipboardHistory.pressCommandV(returningTo: field) {
            // A beat for the app to read it, counted from the ⌘V itself (handing focus back
            // to another app can take most of a second); then what was there goes back,
            // unless something else has been copied meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard !previous.isEmpty, pasteboard.changeCount == ours else { return }
                pasteboard.clearContents()
                pasteboard.writeObjects(previous)
            }
        }
    }

    #if DEBUG
    /// For diagnostics: the pill as while listening, then writing, without the microphone.
    func debugShowPill() {
        model.phase = .listening
        showPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.model.phase = .writing }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.hidePanel() }
    }

    /// `cue://debug/dictate`: what the talk key does, without a key. `start` holds it
    /// (or taps it, hands-free), `stop` lets go, `cancel` is Esc.
    func debugDictate(_ action: String, handsFree: Bool, clip: URL? = nil) {
        switch action {
        case "start": Task { await startListening(held: !handsFree) }
        case "stop":
            service.debugClip = clip
            Task { await finishAndPaste() }
        case "cancel": cancel()
        default: break
        }
    }
    #endif

    // MARK: The pill

    private func showPanel() {
        let panel = panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let size = VoiceTypingPill.windowSize
        let frame = screen.visibleFrame
        panel.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.minY + 16, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 52),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // A fixed window with the pill centred in it: placed before SwiftUI has measured
        // anything, it is still where it should be, and the pill can change width inside it.
        let host = NSHostingView(rootView: VoiceTypingPill(model: model)
            .frame(width: VoiceTypingPill.windowSize.width, height: VoiceTypingPill.windowSize.height))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

extension AppPreferences.VoiceTypingKey {
    /// The modifier key's code; nil for a recorded shortcut.
    var keyCode: UInt16? {
        switch self {
        case .fn: UInt16(kVK_Function)
        case .rightOption: UInt16(kVK_RightOption)
        case .rightCommand: UInt16(kVK_RightCommand)
        case .rightControl: UInt16(kVK_RightControl)
        case .rightShift: UInt16(kVK_RightShift)
        case .leftOption: UInt16(kVK_Option)
        case .leftControl: UInt16(kVK_Control)
        case .shortcut: nil
        }
    }

    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .fn: .function
        case .rightOption, .leftOption: .option
        case .rightCommand: .command
        case .rightControl, .leftControl: .control
        case .rightShift: .shift
        case .shortcut: nil
        }
    }
}

/// The recorded talk shortcut, as a Carbon hot key of its own: unlike an event monitor it
/// keeps the keys from reaching the app in front, and it says when they are let go.
@MainActor
private final class TalkHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    let pressed: () -> Void
    let released: () -> Void

    /// 'CUEV': apart from Cue's other hot keys ('CUE', 'KSTU').
    nonisolated fileprivate static let signature: OSType = 0x4355_4556

    init?(_ combo: Hotkey, pressed: @escaping () -> Void, released: @escaping () -> Void) {
        self.pressed = pressed
        self.released = released
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == TalkHotkey.signature else { return OSStatus(eventNotHandledErr) }
            let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let owner = Unmanaged<TalkHotkey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { isPress ? owner.pressed() : owner.released() }
            return noErr
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

@MainActor
@Observable
final class VoiceTypingModel {
    enum Phase { case listening, writing }
    var phase: Phase = .listening
}

/// The pill at the bottom of the screen: the critter playing while Cue listens, a meter
/// that moves with the voice, then "Writing" while the words are worked out.
private struct VoiceTypingPill: View {
    static let windowSize = CGSize(width: 560, height: 72)

    let model: VoiceTypingModel
    private var service: DictationService { .shared }

    var body: some View {
        let listening = model.phase == .listening
        HStack(spacing: 10) {
            CueCritter(side: 26, mood: listening ? .guitar : .lookAround)
            if listening {
                LevelBars(level: service.level)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(listening ? "Listening" : "Writing")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 9)
        .background(.black.opacity(0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(listening ? "Cue is listening" : "Cue is writing")
    }
}

/// Five bars that rise with the voice, the middle ones most.
private struct LevelBars: View {
    let level: Double
    private static let weights: [Double] = [0.45, 0.75, 1, 0.75, 0.45]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 3, height: 4 + 16 * level * Self.weights[index])
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
