import AppKit
import QuartzCore

/// The island's pace, set by the display it moves on. A spring that settles nicely
/// at 60 frames a second looks sluggish on a 120 Hz ProMotion panel, where every
/// frame of it is seen; so the springs quicken as the refresh rate rises: their
/// response scales from 1 at 60 Hz to 0.93 at 90 Hz and 0.85 at 120 Hz.
///
/// Read from the screen under the pointer (where the island in use is), and looked
/// up at most every two seconds: the island asks on every animation it starts.
@MainActor
enum IslandMotion {
    /// The springs' response at 60 Hz; faster displays take less.
    private static let scaleByRate: [(minimumRate: Int, scale: Double)] = [
        (100, 0.24 / 0.2832),
        (75, 0.264 / 0.2832),
    ]
    private static var cached: (scale: Double, at: CFTimeInterval)?

    /// 1 on a 60 Hz display, less (quicker) on faster ones.
    static var scale: Double {
        let now = CACurrentMediaTime()
        if let cached, now - cached.at < 2 { return cached.scale }
        let rate = refreshRate()
        let scale = scaleByRate.first { rate >= $0.minimumRate }?.scale ?? 1
        cached = (scale, now)
        return scale
    }

    /// `seconds`, the response a spring takes at 60 Hz, for the display in use.
    static func response(_ seconds: Double) -> Double {
        seconds * scale
    }

    private static func refreshRate() -> Int {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        return screen?.maximumFramesPerSecond ?? 60
    }
}
