import CoreGraphics
import Foundation

/// What the island needs to know about a screen, decoupled from `NSScreen` so the
/// placement rules can be unit-tested.
nonisolated struct ScreenMetrics: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`: the notch height, 0 on displays without one.
    var safeAreaTop: CGFloat
    /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`: the menu-bar strips either
    /// side of the notch (nil without a notch).
    var auxiliaryTopLeft: CGRect?
    var auxiliaryTopRight: CGRect?

    var hasNotch: Bool { safeAreaTop > 0 }

    /// Height of the menu-bar strip (24 pt on a plain display, the notch height on a
    /// notched one).
    var menuBarHeight: CGFloat {
        if hasNotch { return safeAreaTop }
        let height = frame.maxY - visibleFrame.maxY
        return height > 0 ? height : 24
    }

    /// The notch, in screen coordinates; nil on a plain display.
    var notch: CGRect? {
        guard hasNotch else { return nil }
        let left = auxiliaryTopLeft?.maxX ?? frame.midX - 100
        let right = auxiliaryTopRight?.minX ?? frame.midX + 100
        guard right > left else { return nil }
        return CGRect(x: left, y: frame.maxY - safeAreaTop, width: right - left, height: safeAreaTop)
    }
}

/// The island's three sizes for one screen. Every rect hangs from the top edge of the
/// screen (`frame.maxY`), centred on the notch (or the screen when there is none).
nonisolated struct IslandGeometry: Equatable {
    enum Phase: Equatable { case collapsed, flash, prompt, form, expanded }

    let screen: ScreenMetrics
    /// Where every shape is centred: the notch, or the middle of a plain display.
    let centerX: CGFloat
    let collapsed: CGRect
    /// The compact box at its fallback width; `rect(for:contentWidth:)` fits it to
    /// its content.
    let flash: CGRect
    /// A one-line question (a name): a flash with room for a label and a box.
    let prompt: CGRect
    /// A compact form (a new task): wider and taller than a flash.
    let form: CGRect
    let expanded: CGRect
    /// Bottom corner radius of the shape in each phase.
    let collapsedRadius: CGFloat
    let flashRadius: CGFloat = 18
    let expandedRadius: CGFloat = 28
    /// Outward curve where the open panel meets the top of the screen.
    static let openFlare: CGFloat = 24

    /// Plain-display pill.
    static let pillWidth: CGFloat = 140
    /// Room around the flash / expanded shape for its shadow.
    static let shadowMargin: CGFloat = 28
    /// Fallback width of the compact box, before its content has been measured.
    static let flashWidth: CGFloat = 340
    /// The compact box is always at least this much wider than the closed shape,
    /// and never wider than `maxFlashWidth`.
    static let minFlashGrowth: CGFloat = 40
    static let maxFlashWidth: CGFloat = 480
    static let flashContentHeight: CGFloat = 48
    static let promptContentHeight: CGFloat = 64
    static let formWidth: CGFloat = 460
    static let formContentHeight: CGFloat = 300
    static let panelHorizontalPadding: CGFloat = 4
    static let panelBottomPadding: CGFloat = 4

    init(screen: ScreenMetrics, panelSize: CGSize) {
        self.screen = screen
        let top = screen.frame.maxY
        let centerX: CGFloat
        let collapsedSize: CGSize
        if let notch = screen.notch {
            centerX = notch.midX
            // Exactly the notch: the shape must never show beside the physical bezel,
            // and a bottom radius a little larger than the real corners keeps it inside.
            collapsedSize = notch.size
            collapsedRadius = 14
        } else {
            centerX = screen.frame.midX
            collapsedSize = CGSize(width: Self.pillWidth, height: max(12, screen.menuBarHeight - 2))
            collapsedRadius = 12
        }
        self.centerX = centerX
        collapsed = Self.hang(size: collapsedSize, centerX: centerX, top: top, in: screen.frame)
        flash = Self.hang(
            size: CGSize(width: Self.flashWidth, height: collapsedSize.height + Self.flashContentHeight),
            centerX: centerX, top: top, in: screen.frame
        )
        prompt = Self.hang(
            size: CGSize(width: Self.flashWidth, height: collapsedSize.height + Self.promptContentHeight),
            centerX: centerX, top: top, in: screen.frame
        )
        form = Self.hang(
            size: CGSize(width: Self.formWidth, height: collapsedSize.height + Self.formContentHeight),
            centerX: centerX, top: top, in: screen.frame
        )
        expanded = Self.hang(
            size: CGSize(
                width: panelSize.width + Self.panelHorizontalPadding * 2,
                height: collapsedSize.height + panelSize.height + Self.panelBottomPadding
            ),
            centerX: centerX, top: top, in: screen.frame
        )
    }

    func rect(for phase: Phase) -> CGRect {
        switch phase {
        case .collapsed: collapsed
        case .flash: flash
        case .prompt: prompt
        case .form: form
        case .expanded: expanded
        }
    }

    /// The compact phases (`.flash`, `.prompt`) sized to their content: `contentWidth`
    /// clamped between a little wider than the closed shape and `maxFlashWidth`.
    /// Other phases, and a nil width, are the fixed rects.
    func rect(for phase: Phase, contentWidth: CGFloat?) -> CGRect {
        guard let contentWidth, phase == .flash || phase == .prompt else { return rect(for: phase) }
        let width = min(max(contentWidth, collapsed.width + Self.minFlashGrowth), Self.maxFlashWidth).rounded()
        let fixed = rect(for: phase)
        return Self.hang(size: CGSize(width: width, height: fixed.height), centerX: centerX, top: screen.frame.maxY, in: screen.frame)
    }

    func radius(for phase: Phase) -> CGFloat {
        switch phase {
        case .collapsed: collapsedRadius
        case .flash, .prompt: flashRadius
        case .form: expandedRadius
        case .expanded: expandedRadius
        }
    }

    /// Height of the strip that overlaps the notch / menu bar in every phase.
    var stripHeight: CGFloat { collapsed.height }

    /// The window is never resized: it always holds the largest shape plus shadow room
    /// on the sides and below, and the transparent remainder lets clicks through. Only
    /// the drawn shape animates, so it always grows out of the notch's centre.
    var windowRect: CGRect { windowRect(for: .expanded) }

    func windowRect(for phase: Phase) -> CGRect {
        let shape = rect(for: phase)
        guard phase != .collapsed else { return shape }
        var rect = shape.insetBy(dx: -Self.shadowMargin, dy: 0)
        rect.origin.y -= Self.shadowMargin
        rect.size.height += Self.shadowMargin
        let bounds = screen.frame
        if rect.width <= bounds.width {
            rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        }
        return rect
    }

    /// A rect of `size` whose top edge is `top`, centred on `centerX`, shifted
    /// sideways (never shrunk) to stay inside `bounds`; it always hangs from the top.
    private static func hang(size: CGSize, centerX: CGFloat, top: CGFloat, in bounds: CGRect) -> CGRect {
        var origin = CGPoint(x: (centerX - size.width / 2).rounded(), y: top - size.height)
        if size.width <= bounds.width {
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        }
        return CGRect(origin: origin, size: size)
    }
}
