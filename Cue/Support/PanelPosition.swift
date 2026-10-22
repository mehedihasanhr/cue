import CoreGraphics
import Foundation

/// Where the floating panels (the library at ⌥⇧K, the quick task at ⌥/) open on
/// the screen the pointer is on.
nonisolated enum PanelPosition: String, CaseIterable, Codable {
    case pointer, top, center, bottom, topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .pointer: "At the mouse pointer"
        case .top: "Top"
        case .center: "Center"
        case .bottom: "Bottom"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }

    /// Gap between a panel and the screen's visible edge.
    static let inset: CGFloat = 8

    /// The window origin for a window of `windowSize` whose visible glass is inset by
    /// `margin` on every side (the rest is shadow room), so the glass — not the
    /// shadow — sits `inset` from the edges of `visible`. At the pointer, the glass's
    /// top-left corner sits just under the pointer, shifted to stay on screen.
    func origin(windowSize: CGSize, margin: CGFloat, pointer: CGPoint, visible: CGRect) -> CGPoint {
        let glass = CGSize(width: windowSize.width - margin * 2, height: windowSize.height - margin * 2)
        let minX = visible.minX + Self.inset
        let maxX = visible.maxX - Self.inset - glass.width
        let minY = visible.minY + Self.inset
        let maxY = visible.maxY - Self.inset - glass.height
        let midX = visible.midX - glass.width / 2
        let midY = visible.midY - glass.height / 2
        let glassOrigin: CGPoint
        switch self {
        case .pointer: glassOrigin = CGPoint(x: pointer.x - 24, y: pointer.y - glass.height + 12)
        case .top: glassOrigin = CGPoint(x: midX, y: maxY)
        case .center: glassOrigin = CGPoint(x: midX, y: midY)
        case .bottom: glassOrigin = CGPoint(x: midX, y: minY)
        case .topLeft: glassOrigin = CGPoint(x: minX, y: maxY)
        case .topRight: glassOrigin = CGPoint(x: maxX, y: maxY)
        case .bottomLeft: glassOrigin = CGPoint(x: minX, y: minY)
        case .bottomRight: glassOrigin = CGPoint(x: maxX, y: minY)
        }
        let clamped = CGPoint(x: min(max(glassOrigin.x, minX), max(minX, maxX)).rounded(),
                              y: min(max(glassOrigin.y, minY), max(minY, maxY)).rounded())
        return CGPoint(x: clamped.x - margin, y: clamped.y - margin)
    }
}
