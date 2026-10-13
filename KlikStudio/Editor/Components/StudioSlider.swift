import AppKit
import SwiftUI
import TimelineKit

/// The editor's slider.
///
/// The system's is built for a settings window: a tall bar and a large knob, sized to be
/// found on a page full of text. This panel is nine of them in a column, so the track is a
/// slim trough, the part you have set is the accent — the same colour that marks the chosen
/// tool, because a slider's fill is the same statement — and the knob is the only thing with
/// any weight, because the knob is the part you aim at.
///
/// It does what a hand-built slider usually forgets:
/// - **Grabbing the knob does not move it.** A press on the knob holds it where the pointer
///   took hold; a press anywhere else on the track jumps the knob there and carries on
///   dragging.
/// - **Double-clicking the knob resets it**, when there is a default to go back to.
/// - **Keyboard.** Focused from the keyboard (Tab, with keyboard navigation on), the arrows
///   step it — Shift for a bigger step — Home and End go to the ends, and the scroll wheel
///   steps it while the pointer is over it. It is not focused by a click, the way the
///   system's slider is not, so arrows go on stepping the playhead after a drag.
/// - **One undo per gesture.** `onEditingChanged` is called with `true` when a drag starts
///   and `false` when it ends, exactly as `Slider`'s is — the editor brackets an undo
///   interaction with it. A run of key presses or scroll ticks is one gesture too: it opens
///   on the first and closes when they stop, so holding an arrow down is one entry, not
///   forty.
/// - **VoiceOver** reads it as an adjustable element with its value in words.
///
/// The arithmetic — positions, steps, increments — is `SliderMath`, in TimelineKit, where it
/// is tested.
struct StudioSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var size: StudioTheme.ControlSize
    /// Where a double-click on the knob puts it. Nil when nothing is a sensible default.
    var defaultValue: Double?
    /// Used instead of `defaultValue` when resetting is more than writing a number — a
    /// setting whose default depends on something else.
    var reset: (() -> Void)?
    /// What VoiceOver reads. The share of the range when not given.
    var valueText: ((Double) -> String)?
    /// Told at the start and end of a gesture, which is how one drag becomes one undo.
    var onEditingChanged: (Bool) -> Void
    /// Drawn as a scrub field — a filled row whose set part is a lighter grey ending in a
    /// thin white bar, its name and value written inside it — instead of a track and knob.
    var scrub: Scrub?

    struct Scrub {
        let title: String
        let value: String
    }

    init(value: Binding<Double>,
         in range: ClosedRange<Double>,
         step: Double? = nil,
         size: StudioTheme.ControlSize = .regular,
         defaultValue: Double? = nil,
         reset: (() -> Void)? = nil,
         valueText: ((Double) -> String)? = nil,
         scrub: Scrub? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.scrub = scrub
        _value = value
        self.range = range
        self.step = step
        self.size = size
        self.defaultValue = defaultValue
        self.reset = reset
        self.valueText = valueText
        self.onEditingChanged = onEditingChanged
    }

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var drag: DragState?
    @State private var isHovering = false
    @State private var bracket = EditingBracket()

    private enum DragState: Equatable {
        /// Following the pointer, `grab` points to the right of the knob's centre.
        case dragging(grab: CGFloat)
        /// The press was a double-click that reset the value; the rest of it is ignored.
        case resetting
    }

    private var metrics: SliderMetrics { scrub == nil ? SliderMetrics(size) : .scrub }

    private var fraction: Double { SliderMath.fraction(of: value, in: range) }

    var body: some View {
        // Refreshed every render, so the bracket always reports to the closure the caller
        // handed in most recently.
        bracket.report = onEditingChanged

        return GeometryReader { proxy in
            let width = proxy.size.width
            let knobX = SliderMath.knobOffset(fraction: fraction, trackLength: width, knob: metrics.knob)

            ZStack(alignment: .leading) {
                if let scrub {
                    ScrubFace(scrub: scrub,
                              fillTo: knobX + metrics.knob,
                              isLit: isHovering || drag != nil,
                              isFocused: isFocused)
                } else {
                    SliderTrack(metrics: metrics,
                                fillFrom: 0,
                                fillTo: knobX + metrics.knob / 2,
                                isLit: isHovering || drag != nil)

                    SliderKnob(metrics: metrics,
                               isDragging: drag != nil,
                               isFocused: isFocused)
                        .offset(x: knobX)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width, knobX: knobX))
        }
        .frame(height: metrics.height)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 && isEnabled }
        .background {
            SliderScrollCatcher(isActive: isFocused && isHovering) { direction in
                nudge(direction, large: false)
            }
        }
        .focusable(isEnabled, interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]) { press in
            switch press.key {
            case .leftArrow, .downArrow: nudge(-1, large: press.modifiers.contains(.shift))
            case .rightArrow, .upArrow: nudge(1, large: press.modifiers.contains(.shift))
            case .home: write(range.lowerBound, keyed: true)
            case .end: write(range.upperBound, keyed: true)
            default: return .ignored
            }
            return .handled
        }
        .onDisappear { bracket.close() }
        .animation(StudioMotion.hover, value: isHovering)
        .animation(StudioMotion.selection, value: drag != nil)
        .accessibilityElement()
        .accessibilityValue(Text(valueText?(value) ?? "\(Int((fraction * 100).rounded())) percent"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1, large: true)
            case .decrement: nudge(-1, large: true)
            @unknown default: break
            }
        }
    }

    // MARK: - Pointer

    private func dragGesture(width: CGFloat, knobX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isEnabled else { return }
                if drag == nil {
                    let centre = knobX + metrics.knob / 2
                    // A little slack around the knob, because a 14-point circle is a
                    // small thing to hit exactly and missing it should not jump the value.
                    let onKnob = abs(gesture.startLocation.x - centre) <= metrics.knob / 2 + (scrub == nil ? 3 : 6)
                    if onKnob, canReset, NSApp.currentEvent?.clickCount == 2 {
                        drag = .resetting
                        resetToDefault()
                        return
                    }
                    drag = .dragging(grab: onKnob ? gesture.startLocation.x - centre : 0)
                    bracket.open()
                }
                guard case .dragging(let grab) = drag else { return }
                follow(gesture.location.x - grab, width: width)
            }
            .onEnded { gesture in
                if case .dragging(let grab) = drag {
                    follow(gesture.location.x - grab, width: width)
                    bracket.close()
                }
                drag = nil
            }
    }

    private func follow(_ x: CGFloat, width: CGFloat) {
        let at = SliderMath.fraction(atPointer: x, trackLength: width, knob: metrics.knob)
        write(SliderMath.value(atFraction: at, in: range, step: step), keyed: false)
    }

    // MARK: - Keys, wheel and reset

    private var canReset: Bool { reset != nil || defaultValue != nil }

    private func resetToDefault() {
        // Bracketed, so the reset is one undo entry named for this slider rather than an
        // anonymous write.
        bracket.open()
        if let reset {
            reset()
        } else if let defaultValue {
            write(SliderMath.snapped(defaultValue, in: range, step: step), keyed: false)
        }
        bracket.close()
    }

    private func nudge(_ direction: Int, large: Bool) {
        guard isEnabled else { return }
        write(SliderMath.nudged(value, direction: direction, in: range, step: step, large: large), keyed: true)
    }

    /// Every write goes through here, so an unchanged value is never written — a drag that
    /// sits still should not be a stream of identical edits.
    private func write(_ newValue: Double, keyed: Bool) {
        if keyed { bracket.touch() }
        guard newValue != value else { return }
        value = newValue
    }
}

// MARK: - A labelled slider

/// A slider with its name, as one scrub row: the name and value written inside a filled
/// field whose set part is lighter. The whole width of the panel is the track, so nothing
/// is lost to a name column beside it.
struct StudioLabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var defaultValue: Double?
    let format: (Double) -> String
    var onEditingChanged: (Bool) -> Void

    @State private var isEditing = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String,
         value: Binding<Double>,
         in range: ClosedRange<Double>,
         step: Double? = nil,
         defaultValue: Double? = nil,
         format: @escaping (Double) -> String,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.format = format
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        // One filled row with the name and value written inside it, the set part a
        // lighter grey: the row is the slider, so a column of them is a column of rows the
        // same height as the switches and pop-ups around them.
        StudioSlider(value: $value,
                     in: range,
                     step: step,
                     defaultValue: defaultValue,
                     valueText: format,
                     scrub: .init(title: title, value: format(value))) { editing in
            isEditing = editing
            onEditingChanged(editing)
        }
        .accessibilityLabel(title)
    }
}

/// A scrub slider's face: the field, its set part, the bar at the end of it, and the name
/// and value over both.
struct ScrubFace: View {
    let scrub: StudioSlider.Scrub
    let fillTo: CGFloat
    var isLit = false
    var isFocused = false

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InspectorMetrics.fieldRadius, style: .continuous)
        ZStack(alignment: .leading) {
            shape.fill(isLit ? StudioTheme.Surface.fieldHover : StudioTheme.Surface.field)
            Rectangle()
                .fill(StudioTheme.Surface.scrubFill)
                .brightness(isLit ? -0.03 : 0)
                .frame(width: max(0, fillTo))
            // The bar the value ends at: the one bright mark in the row.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(StudioTheme.Surface.scrubMark)
                .frame(width: 2, height: 14)
                .offset(x: max(0, fillTo - 2))
            HStack(spacing: 8) {
                Text(scrub.title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(StudioTheme.Surface.label.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(scrub.value)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(isLit ? StudioTheme.Surface.ink : StudioTheme.Surface.value)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, InspectorMetrics.fieldInset)
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(StudioTheme.Palette.focusRing, lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .animation(StudioMotion.hover, value: isLit)
    }
}

// MARK: - Shared drawing

/// The two sizes a slider comes in: the panel's, and the bars' slightly smaller one.
struct SliderMetrics {
    let track: CGFloat
    let knob: CGFloat
    let height: CGFloat

    /// A scrub field: the whole row is the track, and the knob is the two-point bar.
    static let scrub = SliderMetrics(track: InspectorMetrics.scrubHeight, knob: 2, height: InspectorMetrics.scrubHeight)

    init(track: CGFloat, knob: CGFloat, height: CGFloat) {
        self.track = track
        self.knob = knob
        self.height = height
    }

    init(_ size: StudioTheme.ControlSize) {
        switch size {
        case .regular:
            track = 4
            knob = 14
            height = 18
        case .small:
            track = 3
            knob = 12
            height = 16
        }
    }
}

/// The trough, and the accent run along it between two points.
struct SliderTrack: View {
    let metrics: SliderMetrics
    let fillFrom: CGFloat
    let fillTo: CGFloat
    var isLit = false

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(StudioTheme.Palette.track)
                .frame(height: metrics.track)
            Capsule()
                .fill(isEnabled ? StudioTheme.Palette.accent.opacity(isLit ? 1 : 0.9)
                                : StudioTheme.Palette.textTertiary)
                .frame(width: max(0, fillTo - fillFrom), height: metrics.track)
                .offset(x: fillFrom)
        }
    }
}

/// The knob: white in both appearances, with a hairline edge and the kit's one shadow.
struct SliderKnob: View {
    let metrics: SliderMetrics
    var isDragging = false
    var isFocused = false

    var body: some View {
        Circle()
            .fill(StudioTheme.Palette.knob)
            .overlay { Circle().strokeBorder(StudioTheme.Palette.knobEdge, lineWidth: 0.5) }
            .shadow(color: StudioTheme.Palette.knobShadow, radius: 1.5, y: 0.5)
            .overlay {
                Circle()
                    .strokeBorder(StudioTheme.Palette.focusRing, lineWidth: 2)
                    .padding(-3)
                    .opacity(isFocused ? 1 : 0)
            }
            .frame(width: metrics.knob, height: metrics.knob)
            .scaleEffect(isDragging && !StudioMotion.reduceMotion ? 1.12 : 1)
    }
}

// MARK: - Gesture bookkeeping

/// Turns a gesture into exactly one `true` and one `false`.
///
/// A drag has a start and an end the gesture reports. A run of key presses or scroll
/// ticks does not, so `touch()` opens the bracket on the first and closes it once they
/// have stopped for a moment — which is what makes holding an arrow key one undo entry.
@MainActor
final class EditingBracket {
    /// Who hears about it. Set on every render by the control that owns this.
    var report: (Bool) -> Void = { _ in }

    private(set) var isOpen = false
    private var closing: Task<Void, Never>?

    func open() {
        closing?.cancel()
        closing = nil
        guard !isOpen else { return }
        isOpen = true
        report(true)
    }

    func close() {
        closing?.cancel()
        closing = nil
        guard isOpen else { return }
        isOpen = false
        report(false)
    }

    func touch(idle: Duration = .milliseconds(450)) {
        open()
        closing = Task { [weak self] in
            try? await Task.sleep(for: idle)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }
}

// MARK: - The scroll wheel

/// Hands scroll-wheel ticks to a focused slider while the pointer is over it.
///
/// A local event monitor, for the reason `TimelineEventCatcher` gives: a SwiftUI overlay
/// that lets clicks through lets scrolls through too. Only installed while the slider is
/// both focused and under the pointer — the panel is a scroll view, and a slider that ate
/// the wheel every time the pointer crossed it would make the panel impossible to scroll.
private struct SliderScrollCatcher: NSViewRepresentable {
    let isActive: Bool
    let step: (Int) -> Void

    func makeNSView(context: Context) -> CatchingView { CatchingView() }

    func updateNSView(_ view: CatchingView, context: Context) {
        view.step = step
        view.setActive(isActive)
    }

    final class CatchingView: NSView {
        var step: ((Int) -> Void)?
        private let monitor = SliderMonitorBox()
        /// Precise (trackpad) deltas arrive a point or two at a time; they are gathered
        /// until they add up to one step, so a gentle swipe is not twenty steps.
        private var gathered: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func setActive(_ active: Bool) {
            if active, !monitor.isInstalled {
                monitor.token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.handle(event) == true ? nil : event
                }
            } else if !active {
                monitor.clear()
                gathered = 0
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { monitor.clear() }
        }

        deinit { monitor.clear() }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                ? -event.scrollingDeltaX : event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                gathered += delta
                while abs(gathered) >= 6 {
                    step?(gathered > 0 ? 1 : -1)
                    gathered -= gathered > 0 ? 6 : -6
                }
            } else if delta != 0 {
                step?(delta > 0 ? 1 : -1)
            }
            return true
        }
    }
}

/// Somewhere to keep an event monitor that `deinit` is allowed to reach.
private final class SliderMonitorBox: @unchecked Sendable {
    nonisolated(unsafe) var token: Any?

    nonisolated var isInstalled: Bool { token != nil }

    nonisolated func clear() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
