import AppKit

/// Blinks the menu bar mark now and then, and on demand (a capture).
///
/// Cheap on purpose: an earlier blink drove a display link at the screen's refresh
/// and kept Klik near 9% of a core at rest. This one sleeps on a single timer between
/// blinks, and a blink is seven image swaps over about a quarter of a second, from
/// frames drawn once and cached. Nothing runs between blinks.
@MainActor
final class MarkBlinker {
    private weak var button: NSStatusBarButton?
    private let height: CGFloat
    private var idle: Timer?
    private var frames: Timer?

    /// How open the eyes are at each step of a blink: down quickly, up a little slower.
    private static let steps: [CGFloat] = [0.55, 0.15, 0, 0.15, 0.45, 0.8, 1]
    private static let stepInterval: TimeInterval = 1.0 / 28
    private static let restRange: ClosedRange<TimeInterval> = 4...8

    init(button: NSStatusBarButton, height: CGFloat) {
        self.button = button
        self.height = height
        // Drawn up front, so a blink never draws mid-animation.
        for open in Self.steps { _ = KlikMarkImage.template(height: height, eyesOpen: open) }
        scheduleIdle()
    }

    func stop() {
        idle?.invalidate()
        idle = nil
        frames?.invalidate()
        frames = nil
        button?.image = KlikMarkImage.template(height: height)
    }

    /// One blink now (unless one is under way), then back to the idle rhythm.
    func blink() {
        guard frames == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        idle?.invalidate()
        var step = 0
        let timer = Timer(timeInterval: Self.stepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard step < Self.steps.count else {
                    self.frames?.invalidate()
                    self.frames = nil
                    self.scheduleIdle()
                    return
                }
                self.button?.image = KlikMarkImage.template(height: self.height, eyesOpen: Self.steps[step])
                step += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frames = timer
    }

    private func scheduleIdle() {
        idle?.invalidate()
        let timer = Timer(timeInterval: .random(in: Self.restRange), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.blink() }
        }
        // Lets the system fold the wake-up in with others.
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        idle = timer
    }
}
