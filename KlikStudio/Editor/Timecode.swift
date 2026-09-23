import CoreMedia
import Foundation

/// Times, written the way each place needs them.
///
/// There used to be three of these — one on the transport, one on the sidebar, one at
/// the bottom of the timeline — which is two more than the number of ways a time should
/// be spelled in one window.
enum Timecode {
    /// `01:23.45`. The transport, where a hundredth of a second is the point.
    static func precise(_ time: CMTime) -> String {
        let total = max(0, time.seconds)
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        let hundredths = Int((total - total.rounded(.down)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }

    /// `1:23`. A length quoted in passing, where hundredths are noise.
    static func short(_ time: CMTime) -> String {
        let total = max(0, time.seconds)
        return String(format: "%d:%02d", Int(total) / 60, Int(total) % 60)
    }

    /// `7s`, `1m 12s`. A duration on a badge, read at a glance rather than compared.
    static func length(_ time: CMTime) -> String {
        let total = max(0, time.seconds)
        if total < 1 { return String(format: "%.1fs", total) }
        if total < 60 { return "\(Int(total.rounded()))s" }
        let minutes = Int(total) / 60
        let seconds = Int(total.rounded()) % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }

    /// `3s` up close, `1:30` once minutes are in play. The timeline ruler.
    ///
    /// The step decides the precision: ticks half a second apart printed as whole
    /// seconds read "0s 0s 1s 1s", which looks like a rendering fault rather than like
    /// a finer ruler.
    static func ruler(_ seconds: Double, step: Double = 1) -> String {
        if seconds >= 60 {
            let minutes = Int(seconds) / 60
            let remainder = seconds - Double(minutes) * 60
            return step < 1
                ? String(format: "%d:%04.1f", minutes, remainder)
                : String(format: "%d:%02d", minutes, Int(remainder.rounded()))
        }
        return step < 1 ? String(format: "%.1fs", seconds) : "\(Int(seconds.rounded()))s"
    }
}
