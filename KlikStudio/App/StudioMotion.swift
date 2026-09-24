import AppKit
import SwiftUI

/// The bar's motion, named once.
///
/// Klik keeps its curves on `IslandView` — `easeOut(0.12)` for hover, `0.15` for a state
/// change, a spring for anything that changes shape — and gates every one on Reduce
/// Motion. Studio is a separate target and cannot reach that file, so the same vocabulary
/// is spelled out here rather than scattered as literals through `RecorderBar`. The
/// durations are deliberately the host app's, so the two feel like one product.
enum StudioMotion {
    /// Read from AppKit rather than `@Environment(\.accessibilityReduceMotion)` because
    /// the panel's AppKit half — which resizes the window — needs the same answer as the
    /// SwiftUI half, and cannot see the environment.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Hover. Short enough that sweeping the pointer along the bar reads as a wash rather
    /// than four separate flashes.
    static var hover: Animation { .easeOut(duration: reduceMotion ? 0.001 : 0.12) }

    /// A toggle flipping: camera, microphone, system audio.
    static var state: Animation { .easeOut(duration: 0.15) }

    /// The selection chip travelling between mode tiles. A little give, because the chip
    /// lands somewhere — but only a little: this is chrome sitting on top of the thing
    /// being recorded, not a toy.
    static var selection: Animation {
        reduceMotion ? .easeOut(duration: 0.15)
                     : .spring(response: 0.3, dampingFraction: 0.86, blendDuration: 0)
    }

    /// Setup ⇄ recording, where the bar loses two thirds of its width.
    static var shape: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: shapeDuration, extraBounce: 0.02)
    }

    /// The same beat, for the AppKit window frame that has to keep out of its way.
    static let shapeDuration: TimeInterval = 0.26

    /// Press. Feedback belongs on the mouse going down, so it has to be quicker than
    /// anything else here.
    static var press: Animation { .easeOut(duration: 0.1) }
}

/// Every control on the bar answers the mouse going down, not coming up.
///
/// `.plain` draws the label and nothing else: pressing Record looked identical to hovering
/// it, and on a non-activating panel there is no key-window highlight to fall back on. A
/// press that gives six percent is the smallest thing that reads as "heard you", and it is
/// the same shape as the host app's `PillButtonStyle`.
struct BarButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !StudioMotion.reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(StudioMotion.press, value: configuration.isPressed)
    }
}

/// Reports the bar's laid-out size to the panel around it.
///
/// The panel cannot usefully ask the hosting view how wide the bar wants to be: it has to
/// ask before the display's name has arrived from ScreenCaptureKit, and the answer changes
/// again when a take starts and most of the controls go away. The bar measures itself
/// instead, and the panel sizes and re-centres itself on what it reports.
struct BarSizeReporter: View {
    let report: (CGSize) -> Void

    /// The last size handed on. Reporting is rounded and de-duplicated here, because the
    /// panel rounds the same way before comparing against its own frame: left unrounded,
    /// a sub-point remeasure clears the panel's guard, resizes the window, and is
    /// measured again.
    @State private var reported: CGSize?

    var body: some View {
        GeometryReader { proxy in
            let size = CGSize(width: proxy.size.width.rounded(.up),
                              height: proxy.size.height.rounded(.up))
            Color.clear
                .onChange(of: size, initial: true) { _, size in
                    guard size != reported else { return }
                    reported = size
                    report(size)
                }
        }
    }
}
