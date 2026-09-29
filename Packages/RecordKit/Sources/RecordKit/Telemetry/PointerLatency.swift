import AppKit
import CoreGraphics
import Foundation

/// How long after the pointer moves the screen shows it having moved.
///
/// The system knows where the pointer is the moment the hand moves; the screen shows it
/// there at its next refresh, and a captured frame is a picture of the screen. So a
/// position read at some instant is what the *picture* shows one refresh later. Written
/// down unadjusted, the drawn pointer runs that far ahead of everything else in the frame
/// — measured against a recording with the real pointer in it, 8.5 ms on a 120 Hz display,
/// which is nine points for a pointer crossing the screen in a second.
///
/// One refresh of the display being recorded is what was measured, and is what this
/// returns.
public enum PointerLatency {
    /// Seconds between the pointer moving and the picture showing it, on this display.
    public static func seconds(for display: CGDirectDisplayID?) -> Double {
        seconds(refreshRate: refreshRate(of: display))
    }

    /// The arithmetic, separate from the asking so it can be checked without a display.
    public static func seconds(refreshRate: Double) -> Double {
        // A display that reports no rate, or an absurd one, is treated as the common case
        // rather than given no correction or an enormous one.
        let rate = refreshRate.isFinite && refreshRate >= 24 && refreshRate <= 480 ? refreshRate : 60
        return 1 / rate
    }

    static func refreshRate(of display: CGDirectDisplayID?) -> Double {
        let display = display ?? CGMainDisplayID()
        // The screen's own answer first: a ProMotion panel reports no fixed rate through
        // its display mode, because it has none, but it does say how fast it can go —
        // and with a pointer moving on it, that is how fast it is going.
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
        if let screen, screen.maximumFramesPerSecond > 0 {
            return Double(screen.maximumFramesPerSecond)
        }
        if let mode = CGDisplayCopyDisplayMode(display), mode.refreshRate > 0 {
            return mode.refreshRate
        }
        return 60
    }
}
