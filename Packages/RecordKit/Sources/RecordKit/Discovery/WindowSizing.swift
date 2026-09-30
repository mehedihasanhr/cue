import CoreGraphics
import Foundation

/// A size to put a window at before recording it.
///
/// A window recorded at whatever size it happened to be makes a video of that shape: 1283
/// by 917, say, which letterboxes in every player and crops badly into every social format.
/// Setting the window to a known size first means the recording *is* 16:9, or square, or
/// upright, and nothing has to be cut off it later.
///
/// The numbers are the recording's pixels, not the window's points, because the recording
/// is what the person is choosing: on a Retina display a window of 960 by 540 points
/// records at 1920 by 1080. `WindowSizing.frame(for:window:visibleFrame:backingScale:)`
/// does that conversion, and shrinks a size that will not fit on the screen.
public enum WindowSizePreset: String, CaseIterable, Identifiable, Sendable {
    case hd720
    case hd1080
    case square
    case vertical
    /// As large as the screen's usable area — under the menu bar, beside the Dock — without
    /// going full screen, which would move the window to a Space of its own.
    case fitDisplay

    public var id: String { rawValue }

    /// The recording's size in pixels, or `nil` for the screen's own.
    public var pixels: CGSize? {
        switch self {
        case .hd720: CGSize(width: 1_280, height: 720)
        case .hd1080: CGSize(width: 1_920, height: 1_080)
        case .square: CGSize(width: 1_080, height: 1_080)
        case .vertical: CGSize(width: 1_080, height: 1_920)
        case .fitDisplay: nil
        }
    }

    public var title: String {
        switch self {
        case .hd720: "1280 × 720"
        case .hd1080: "1920 × 1080"
        case .square: "1080 × 1080"
        case .vertical: "1080 × 1920"
        case .fitDisplay: "Fit to display"
        }
    }

    /// What the size is for, said in the words somebody would choose it by.
    public var subtitle: String {
        switch self {
        case .hd720: "16:9, HD"
        case .hd1080: "16:9, Full HD"
        case .square: "1:1, square"
        case .vertical: "9:16, upright"
        case .fitDisplay: "The screen's usable area"
        }
    }
}

/// The arithmetic of resizing a window to a preset: where it goes, and which of an
/// application's windows the recorder's window is.
///
/// Kept apart from the Accessibility calls that act on it, and free of them, so it can be
/// tested: the call that moves another application's window cannot be, and must not be
/// run from a test on somebody's Mac.
///
/// Every rectangle here is in global display points with the origin at the top left of the
/// main display, y running down — the convention `SCWindow.frame` and the Accessibility
/// position both use, so nothing is flipped on the way from one to the other.
public enum WindowSizing {
    /// What a resize will do: the frame to ask for, and whether the preset had to be made
    /// smaller to fit.
    public struct Plan: Equatable, Sendable {
        /// Where the window should go, in points.
        public let frame: CGRect
        /// The size the preset asked for did not fit on the screen, so this is that shape,
        /// shrunk until it does. The recording will be the right shape and fewer pixels.
        public let isShrunk: Bool

        public init(frame: CGRect, isShrunk: Bool) {
            self.frame = frame
            self.isShrunk = isShrunk
        }
    }

    /// Where a window goes to be a preset's size on a screen.
    ///
    /// - Parameters:
    ///   - window: where the window is now.
    ///   - visibleFrame: the screen's usable area — without the menu bar and the Dock — in
    ///     the same top-left points.
    ///   - backingScale: pixels per point on that screen, 2 on a Retina display.
    ///
    /// The window keeps its top-left corner when the new size fits there, because that is
    /// where the person put it and where they are looking. When it does not, it is moved
    /// the least it takes to be wholly on the screen. A size larger than the screen keeps
    /// its shape and shrinks to fit: a 1080 × 1920 window will not fit upright on a
    /// non-Retina laptop, and a squashed window would record the wrong shape, which is the
    /// one thing this exists to prevent. Whole points, rounded down, so a shrunk window is
    /// never a fraction of a point too big.
    public static func frame(for preset: WindowSizePreset,
                             window: CGRect,
                             visibleFrame: CGRect,
                             backingScale: Double) -> Plan? {
        guard visibleFrame.width >= 1, visibleFrame.height >= 1 else { return nil }
        guard let pixels = preset.pixels else {
            return Plan(frame: visibleFrame.integral, isShrunk: false)
        }
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        var size = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        var isShrunk = false
        let fit = min(visibleFrame.width / size.width, visibleFrame.height / size.height)
        if fit < 1 {
            size = CGSize(width: (size.width * fit).rounded(.down), height: (size.height * fit).rounded(.down))
            isShrunk = true
        }
        let x = min(max(window.minX, visibleFrame.minX), visibleFrame.maxX - size.width)
        let y = min(max(window.minY, visibleFrame.minY), visibleFrame.maxY - size.height)
        return Plan(frame: CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height),
                    isShrunk: isShrunk)
    }

    /// One of an application's windows, as Accessibility describes it.
    public struct Candidate: Equatable, Sendable {
        public let frame: CGRect
        public let title: String?

        public init(frame: CGRect, title: String?) {
            self.frame = frame
            self.title = title
        }
    }

    /// How far apart two frames may be and still be the same window, in points on every
    /// edge. The two accounts come from different parts of the system and can disagree
    /// by a point of rounding; a different window of the same app is almost never within
    /// this of it.
    public static let sameWindowTolerance = 4.0

    /// Which of an application's windows is the one the recorder listed.
    ///
    /// Accessibility names windows by element, and the recorder knows them by window
    /// number; there is no public bridge between the two. So they are matched by where
    /// they are: the window whose frame is the recorder's, give or take a point of
    /// rounding. Two windows stacked exactly on top of each other — a document and its
    /// twin — are told apart by title. Nothing close enough is no match at all, rather than
    /// the nearest window, because resizing the wrong window of somebody's app is worse
    /// than resizing none and saying so.
    public static func match(_ target: CGRect, title: String?, among candidates: [Candidate]) -> Int? {
        func distance(_ a: CGRect, _ b: CGRect) -> Double {
            max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
        }
        let close = candidates.indices
            .map { (index: $0, distance: distance(candidates[$0].frame, target)) }
            .filter { $0.distance <= sameWindowTolerance }
        guard !close.isEmpty else { return nil }
        if close.count > 1, let title, !title.isEmpty,
           let named = close.filter({ candidates[$0.index].title == title }).min(by: { $0.distance < $1.distance }) {
            return named.index
        }
        return close.min { $0.distance < $1.distance }?.index
    }

    /// A rectangle in AppKit's screen coordinates — origin at the bottom left of the main
    /// display, y running up, which is what `NSScreen.visibleFrame` is in — turned into the
    /// top-left points everything else here uses.
    ///
    /// - Parameter mainHeight: the height of the main display, the one the two systems
    ///   share an edge on.
    public static func topLeft(_ rect: CGRect, mainHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Which screen a window is on: the one holding most of it, or, for a window wholly
    /// off every screen, the one nearest it.
    public static func screen(for window: CGRect, among screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        func area(_ index: Int) -> Double {
            let overlap = screens[index].intersection(window)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let most = screens.indices.max(by: { area($0) < area($1) }), area(most) > 0 { return most }
        func gap(_ index: Int) -> Double {
            let screen = screens[index]
            let dx = max(screen.minX - window.maxX, window.minX - screen.maxX, 0)
            let dy = max(screen.minY - window.maxY, window.minY - screen.maxY, 0)
            return hypot(dx, dy)
        }
        return screens.indices.min { gap($0) < gap($1) }
    }
}
