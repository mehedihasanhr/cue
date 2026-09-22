import AppKit
import SwiftUI

/// The app icon, drawn rather than shipped flat, so its eyes can close like the
/// mark's do. The tile and the chrome face are bundled separately (Brand/); a blink
/// is the eye holes losing their height, with the face's own light filling in behind
/// them — the lid is the same material as the face.
@MainActor
enum KlikIcon {
    /// Apple's grid: an 824 pt body on a 1024 pt canvas, the rest left for the shadow.
    private static let canvas: CGFloat = 1024, body: CGFloat = 824
    /// Where the face sits on the tile, from the Figma frame (tile at 8, 4.7; face at 229, 195).
    private static let tileSize = CGSize(width: 1099.503, height: 1090.671)
    private static let faceOrigin = CGPoint(x: 221, y: 190.301)
    private static let faceSize = CGSize(width: 669.789, height: 704.215)
    /// The eye holes in the chrome face, measured from the artwork itself (fractions
    /// of the face image, top-left origin). The face is drawn with more detail than
    /// the flat mark, and its holes do not sit exactly where the mark's eyes do.
    private static let holes = [
        CGRect(x: 0.4639, y: 0.3254, width: 0.1892, height: 0.3104),
        CGRect(x: 0.7166, y: 0.2739, width: 0.1695, height: 0.2948),
    ]

    /// A hole's rect inside `face`, in drawing coordinates (which count up, not down).
    private static func hole(_ index: Int, in face: CGRect) -> CGRect {
        let unit = holes[index]
        return CGRect(x: face.minX + unit.minX * face.width,
                      y: face.maxY - (unit.minY + unit.height) * face.height,
                      width: unit.width * face.width, height: unit.height * face.height)
    }

    /// Both eyes at `open`, placed in the face's own holes.
    private static func eyes(in face: CGRect, open: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for index in holes.indices {
            path.addPath(KlikMark.eye(index, fitting: hole(index, in: face), open: open))
        }
        return path
    }

    private static let tile = NSImage(contentsOf: Bundle.main.url(forResource: "icon-tile", withExtension: "png") ?? URL(fileURLWithPath: "/"))
    private static let face = NSImage(contentsOf: Bundle.main.url(forResource: "icon-mark", withExtension: "png") ?? URL(fileURLWithPath: "/"))
    /// Rendered frames, keyed by size and how open the eyes are: a blink walks the
    /// same dozen values every time, so each one is drawn once and kept.
    private static var frames: [String: NSImage] = [:]

    /// Draws every frame of a blink ahead of time. Rendering one mid-blink is what
    /// made it stutter: the work lands between two frames instead of before them.
    static func prepare(side: CGFloat) {
        for step in 0...Blink.steps {
            _ = image(side: side, eyesOpen: CGFloat(step) / CGFloat(Blink.steps))
        }
    }

    /// The icon at `side` points, with the eyes `open` from 0 (shut) to 1. Falls back
    /// to the flat icon in the asset catalog if the pieces are missing.
    static func image(side: CGFloat, eyesOpen open: CGFloat) -> NSImage {
        let open = min(max(open, 0), 1)
        let key = "\(Int(side)).\(Int((open * CGFloat(Blink.steps)).rounded()))"
        if let cached = frames[key] { return cached }
        guard let tile, let face else { return NSImage(named: "AppIcon") ?? NSApp.applicationIconImage }

        let scale = side / canvas
        let bodyScale = body / max(tileSize.width, tileSize.height) * scale
        let tileRect = CGRect(x: (side - tileSize.width * bodyScale) / 2, y: (side - tileSize.height * bodyScale) / 2,
                              width: tileSize.width * bodyScale, height: tileSize.height * bodyScale)
        // Core Graphics counts up from the bottom; Figma counts down from the top.
        let faceRect = CGRect(x: tileRect.minX + faceOrigin.x * bodyScale,
                              y: tileRect.maxY - (faceOrigin.y + faceSize.height) * bodyScale,
                              width: faceSize.width * bodyScale, height: faceSize.height * bodyScale)

        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.interpolationQuality = .high
            tile.draw(in: tileRect)
            guard open < 0.999 else {
                // Eyes open is the artwork untouched: the face's own holes, nothing
                // painted over them (painting would thicken the eyes by a hair).
                face.draw(in: faceRect)
                return true
            }
            // The lid is the face's own chrome, borrowed from just above the eye, so a
            // closing eye keeps the material rather than turning into a grey patch.
            context.saveGState()
            // A hair wider than the hole, so no rim of it survives the lid.
            context.addPath(eyes(in: faceRect.insetBy(dx: -faceRect.width * 0.004, dy: -faceRect.height * 0.004), open: 1))
            context.clip(using: .evenOdd)
            face.draw(in: faceRect.offsetBy(dx: 0, dy: -faceRect.height * 0.16))
            context.restoreGState()
            face.draw(in: faceRect)
            // What is left of the holes at this moment.
            context.addPath(eyes(in: faceRect, open: open))
            context.setFillColor(NSColor(white: 0.04, alpha: 1).cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        frames[key] = image
        return image
    }
}

/// The app icon in SwiftUI, blinking like the mark does.
struct BlinkingAppIcon: View {
    var side: CGFloat = 28
    /// Below this the icon is a signpost in a list: it stays still.
    var blinks = true

    @State private var eyesOpen: CGFloat = 1

    var body: some View {
        // The frames are cached, so animating the openness is a lookup per frame.
        Image(nsImage: KlikIcon.image(side: side * 2, eyesOpen: eyesOpen))
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .animation(nil, value: eyesOpen) // the value is animated, not the picture
            .task(id: blinks) { await blinkForever() }
    }

    private func blinkForever() async {
        guard blinks, !KlikMarkView.reduceMotion else { return }
        KlikIcon.prepare(side: side * 2) // every frame drawn before the first blink
        while !Task.isCancelled {
            try? await Task.sleep(for: Blink.every())
            guard !Task.isCancelled else { return }
            // SwiftUI walks the curve itself, so the frames land with the screen.
            withAnimation(.timingCurve(0.4, 0, 0.6, 1, duration: Blink.down + Blink.hold)) { eyesOpen = 0.04 }
            try? await Task.sleep(for: .seconds(Blink.down + Blink.hold))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Blink.up)) { eyesOpen = 1 }
        }
    }
}

/// Blinks the Dock tile: `NSApp.applicationIconImage` is redrawn for the length of a
/// blink and left alone in between. Idle blinks are rare and never in step with the
/// menu bar's; Reduce Motion keeps the eyes open.
@MainActor
final class AppIconBlinker {
    static let shared = AppIconBlinker()

    private var idleTask: Task<Void, Never>?
    private var timer: BlinkClock?
    private var startedAt: CFTimeInterval = 0
    private let side: CGFloat = 256 // the Dock never shows it larger than this

    private init() {}

    func start() {
        guard !KlikMarkView.reduceMotion, idleTask == nil else { return }
        NSApp.applicationIconImage = KlikIcon.image(side: side, eyesOpen: 1)
        idleTask = Task { [weak self] in
            guard let self else { return }
            // The first blink is the one that used to stutter: every frame of it is
            // drawn now, while nothing is moving.
            KlikIcon.prepare(side: side)
            while !Task.isCancelled {
                try? await Task.sleep(for: Blink.every())
                guard !Task.isCancelled else { return }
                blink()
            }
        }
    }

    func stop() {
        idleTask?.cancel()
        idleTask = nil
        timer?.stop()
        timer = nil
        NSApp.applicationIconImage = NSImage(named: "AppIcon")
    }

    /// A blink on purpose — the icon reacting to what the app just did.
    func blink() {
        guard !KlikMarkView.reduceMotion, timer == nil, NSApp.activationPolicy() == .regular else { return }
        startedAt = CACurrentMediaTime()
        timer = BlinkClock(for: window) { [weak self] in self?.step() }
    }

    /// Where the Dock tile's frames come from: any window will do as a clock.
    private var window: NSWindow? { NSApp.windows.first { $0.isVisible } }

    /// The Dock redraws its tile on every assignment, so a frame is only handed over
    /// when it is a different one: the blink walks whole steps, not fractions.
    private var shownStep = Blink.steps

    private func step() {
        let elapsed = CACurrentMediaTime() - startedAt
        guard elapsed < Blink.length else {
            timer?.stop()
            timer = nil
            shownStep = Blink.steps
            NSApp.applicationIconImage = KlikIcon.image(side: side, eyesOpen: 1)
            return
        }
        let step = Int((Blink.openness(at: elapsed) * CGFloat(Blink.steps)).rounded())
        guard step != shownStep else { return }
        shownStep = step
        NSApp.applicationIconImage = KlikIcon.image(side: side, eyesOpen: CGFloat(step) / CGFloat(Blink.steps))
    }
}

/// A clock for a blink: the display's own refresh where one is to be had, a timer
/// otherwise. A `Timer` fires near the frame rather than with it, which is what a
/// blink looks like when it stutters.
@MainActor
final class BlinkClock {
    private var link: CADisplayLink?
    private var timer: Timer?
    private let tick: () -> Void

    init(for window: NSWindow?, tick: @escaping () -> Void) {
        self.tick = tick
        // A view's link, a window's, or the screen's — a menu bar app often has no
        // window at all, and the screen keeps the beat just as well.
        if let link = window?.contentView?.displayLink(target: self, selector: #selector(fire))
            ?? NSScreen.main?.displayLink(target: self, selector: #selector(fire)) {
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    @objc private func fire() { tick() }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }
}

/// One blink, shared by everything that has eyes: shut, hold, open a little slower —
/// the shape of a real one, taken at an unhurried pace so it reads as a blink rather
/// than a flicker. `every` is the gap between idle blinks.
enum Blink {
    static let down = 0.13, hold = 0.05, up = 0.17
    static var length: CFTimeInterval { down + hold + up }
    /// The steps the frame cache holds: a blink only ever asks for these.
    static let steps = 24
    static func every() -> Duration { .milliseconds(Int.random(in: 3200...6500)) }
    /// How open the eyes are, `elapsed` into a blink.
    static func openness(at elapsed: CFTimeInterval) -> CGFloat {
        if elapsed < down { return 1 - ease(elapsed / down) * 0.96 }
        if elapsed < down + hold { return 0.04 }
        return 0.04 + ease((elapsed - down - hold) / up) * 0.96
    }

    private static func ease(_ time: CFTimeInterval) -> CGFloat {
        CGFloat(1 - pow(1 - min(max(time, 0), 1), 3))
    }
}
