import AppKit
import SwiftUI

/// The mark, blinking now and then — the idle motion Klik allows itself, and only
/// because this is the thing's face. A blink is short (see `Blink`: shut in 90 ms,
/// open again in 130) and rare (every 4–9 seconds, never in step with another mark
/// on screen), so it reads as life rather than as a beacon. Reduce Motion keeps the
/// eyes open.
struct KlikMarkView: View {
    /// Blink by itself. Off, the mark only blinks when `blinkNow` changes.
    var idle = true
    /// Flip this to blink on purpose — a copy landing, a note saved.
    var blinkNow: Int = 0

    @State private var eyesOpen: CGFloat = 1

    var body: some View {
        KlikMarkShape(eyesOpen: eyesOpen)
            .fill(style: FillStyle(eoFill: true))
            .task(id: idle) { await blinkForever() }
            .onChange(of: blinkNow) { _, _ in Task { await blink() } }
            .accessibilityHidden(true)
    }

    private func blinkForever() async {
        guard idle, !KlikMarkView.reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Blink.every())
            guard !Task.isCancelled else { return }
            await blink()
        }
    }

    /// Down, held for an instant, then up a little slower: the shape of a real blink.
    private func blink() async {
        guard !KlikMarkView.reduceMotion else { return }
        withAnimation(.timingCurve(0.4, 0, 0.6, 1, duration: Blink.down)) { eyesOpen = 0.04 }
        try? await Task.sleep(for: .seconds(Blink.down + Blink.hold))
        withAnimation(.easeOut(duration: Blink.up)) { eyesOpen = 1 }
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// The mark drawn into an `NSImage`, for the places AppKit owns — the status item
/// and its menu. A template image, so the system tints it for the menu bar.
@MainActor
enum KlikMarkImage {
    private static var frames: [String: NSImage] = [:]

    /// Every frame of a blink, drawn ahead of time.
    static func prepare(height: CGFloat) {
        for step in 0...Blink.steps { _ = template(height: height, eyesOpen: CGFloat(step) / CGFloat(Blink.steps)) }
    }

    static func template(height: CGFloat, eyesOpen: CGFloat = 1) -> NSImage {
        let key = "\(Int(height)).\(Int((min(max(eyesOpen, 0), 1) * CGFloat(Blink.steps)).rounded()))"
        if let cached = frames[key] { return cached }
        let width = (KlikMark.size.width / KlikMark.size.height * height).rounded()
        let size = CGSize(width: width, height: height)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(KlikMark.path(in: rect, eyesOpen: eyesOpen))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Klik"
        frames[key] = image
        return image
    }
}

/// Blinks the menu bar's mark: the status item's image is redrawn for the length of
/// a blink and left alone in between, so nothing is running while nothing is happening.
@MainActor
final class StatusItemBlinker {
    private weak var button: NSStatusBarButton?
    private let height: CGFloat
    private var idleTask: Task<Void, Never>?
    private var clock: BlinkClock?
    private var startedAt: CFTimeInterval = 0

    private var total: CFTimeInterval { Blink.length }

    init(button: NSStatusBarButton, height: CGFloat) {
        self.button = button
        self.height = height
        button.image = KlikMarkImage.template(height: height)
        startIdle()
    }

    deinit {
        idleTask?.cancel()
    }

    func stop() {
        idleTask?.cancel()
        idleTask = nil
        clock?.stop()
        clock = nil
        button?.image = KlikMarkImage.template(height: height)
    }

    /// A blink on purpose — a capture landing, say — on top of the idle ones.
    func blink() {
        guard !KlikMarkView.reduceMotion, clock == nil else { return }
        startedAt = CACurrentMediaTime()
        clock = BlinkClock(for: button?.window) { [weak self] in self?.step() }
    }

    /// One frame of a blink; the last one puts the eyes back and stops the clock.
    private func step() {
        let elapsed = CACurrentMediaTime() - startedAt
        guard elapsed < total else {
            clock?.stop()
            clock = nil
            button?.image = KlikMarkImage.template(height: height)
            return
        }
        button?.image = KlikMarkImage.template(height: height, eyesOpen: openness(at: elapsed))
    }

    private func openness(at elapsed: CFTimeInterval) -> CGFloat { Blink.openness(at: elapsed) }

    private func startIdle() {
        idleTask?.cancel()
        guard !KlikMarkView.reduceMotion else { return }
        idleTask = Task { [weak self] in
            guard let self else { return }
            KlikMarkImage.prepare(height: height) // drawn before the first blink, not during it
            while !Task.isCancelled {
                try? await Task.sleep(for: Blink.every())
                guard !Task.isCancelled else { return }
                blink()
            }
        }
    }
}
