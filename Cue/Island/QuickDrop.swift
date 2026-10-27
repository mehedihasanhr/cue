import AppKit
import SwiftUI

/// Where files shaken up mid-drag can go: the four places in the grid that comes up
/// under the pointer.
enum QuickDropTarget: CaseIterable {
    case basket, transform, share, airDrop

    var title: String {
        switch self {
        case .basket: "Basket"
        case .transform: "Transform"
        case .share: "Share link"
        case .airDrop: "AirDrop"
        }
    }

    var symbol: String {
        switch self {
        case .basket: "tray.and.arrow.down.fill"
        case .transform: "arrow.triangle.2.circlepath"
        case .share: "link"
        case .airDrop: "dot.radiowaves.left.and.right"
        }
    }

    /// Its place in the grid: basket and transform on top, share and AirDrop below.
    var row: Int { self == .basket || self == .transform ? 0 : 1 }
    var column: Int { self == .basket || self == .share ? 0 : 1 }
}

@MainActor @Observable
final class QuickDropModel {
    /// On screen (false while it shrinks away).
    var shown = false
    /// The tile under the dragged files.
    var hovered: QuickDropTarget?
    /// A share link can be made (Settings › Sharing is set up).
    var canShare = false
}

/// The grid's window content: tells which tile the files are over, and takes them.
final class QuickDropView: NSView {
    var onHover: ((QuickDropTarget?) -> Void)?
    var onDrop: ((QuickDropTarget, [URL], Data?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The tile at `point` (in this view), by quadrant.
    private func target(at point: CGPoint) -> QuickDropTarget {
        let column = point.x < bounds.midX ? 0 : 1
        let row = point.y > bounds.midY ? 0 : 1 // AppKit counts up from the bottom
        return QuickDropTarget.allCases.first { $0.row == row && $0.column == column } ?? .basket
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onHover?(target(at: convert(sender.draggingLocation, from: nil)))
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onHover?(nil)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let image = urls.isEmpty ? (pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)) : nil
        guard !urls.isEmpty || image != nil else { return false }
        onDrop?(target(at: convert(sender.draggingLocation, from: nil)), urls, image)
        return true
    }
}

/// Four tiles on a pane of Liquid Glass: drop on one to send the files there. Drawn
/// as Droppy's: small (about 210 × 196), light frosted tiles on clear glass that
/// follows the system's appearance, grey glyphs and small semibold labels, the
/// share link as a little app icon, and the tile under the files brightening.
struct QuickDropGrid: View {
    /// The window: the grid and room around it for its shadow.
    static let size = CGSize(width: 250, height: 236)
    private static let content = CGSize(width: 210, height: 196)
    private static let radius: CGFloat = 22
    private static let tileRadius: CGFloat = 13

    let model: QuickDropModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        Grid(horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach(0..<2) { row in
                GridRow {
                    ForEach(QuickDropTarget.allCases.filter { $0.row == row }, id: \.self) { target in
                        tile(target)
                    }
                }
            }
        }
        .padding(7)
        .frame(width: Self.content.width, height: Self.content.height)
        .modifier(PaneGlass(shape: shape, dark: scheme == .dark))
        .scaleEffect(model.shown ? 1 : 0.82)
        .opacity(model.shown ? 1 : 0)
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.68), value: model.shown)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: model.hovered)
    }

    private func tile(_ target: QuickDropTarget) -> some View {
        let lit = model.hovered == target
        let off = target == .share && !model.canShare
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous)
        return VStack(spacing: 7) {
            glyph(target, off: off)
                .frame(height: 26)
            VStack(spacing: 1) {
                Text(target.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(dark ? Color(white: off ? 0.5 : 0.86) : Color(white: off ? 0.55 : 0.3))
                    .multilineTextAlignment(.center)
                if off {
                    Text("Set up in Settings")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(dark ? Color(white: 0.5) : Color(white: 0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Soft grey, a shade darker than the glass round it; under the files, darker
        // still and lifted a touch.
        .background {
            shape.fill(dark ? Color.white.opacity(lit ? 0.16 : 0.07) : Color.black.opacity(lit ? 0.11 : 0.055))
        }
        .scaleEffect(lit ? 1.03 : 1)
    }

    @ViewBuilder
    private func glyph(_ target: QuickDropTarget, off: Bool) -> some View {
        let dark = scheme == .dark
        if target == .share {
            // A little app icon, as Droppy shows its cloud.
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            ZStack {
                shape.fill(dark ? Color(white: 0.22) : .white)
                Icon("link", size: 15, weight: .bold)
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.62, green: 0.6, blue: 1), Color(red: 0.4, green: 0.42, blue: 0.98)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            .frame(width: 26, height: 26)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .saturation(off ? 0 : 1)
            .opacity(off ? 0.5 : 1)
        } else if target == .basket {
            // A filled tray, shaded top to bottom like a little object.
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(LinearGradient(colors: dark ? [Color(white: 0.92), Color(white: 0.6)] : [Color(white: 0.62), Color(white: 0.36)],
                                                startPoint: .top, endPoint: .bottom))
        } else {
            Image(systemName: target.symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(dark ? Color(white: 0.92) : Color(white: 0.16))
        }
    }
}

/// The grid's pane: clear Liquid Glass with a soft shadow on macOS 26, a material
/// pane before it.
private struct PaneGlass: ViewModifier {
    let shape: RoundedRectangle
    let dark: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(dark ? .black.opacity(0.25) : .white.opacity(0.5)), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(dark ? 0.12 : 0.75), lineWidth: 1))
                .shadow(color: .black.opacity(dark ? 0.35 : 0.14), radius: 14, y: 6)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(dark ? 0.1 : 0.5), lineWidth: 0.75))
                .shadow(color: .black.opacity(dark ? 0.35 : 0.18), radius: 12, y: 5)
        }
    }
}

/// A drop tile's picture, as Droppy draws them: a softly lit glyph, or (`badge`) a
/// small app icon with a coloured glyph, for the share link.
struct DropGlyph: View {
    let symbol: String
    var badge = false
    var off = false
    /// A heavier glyph shaded darker at its foot, so it doesn't outweigh the rest.
    var dim = false
    var size: CGFloat = 30

    var body: some View {
        if badge {
            let shape = RoundedRectangle(cornerRadius: size * 0.4, style: .continuous)
            ZStack {
                shape.fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
                shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.75)
                Icon("link", size: size * 0.7, weight: .bold)
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.62, green: 0.6, blue: 1), Color(red: 0.4, green: 0.42, blue: 0.98)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            .frame(width: size * 1.53, height: size * 1.53)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
            .saturation(off ? 0 : 1)
            .opacity(off ? 0.5 : 1)
        } else {
            Icon(symbol, size: size, weight: .medium)
                .foregroundStyle(LinearGradient(colors: [Color(white: 0.95), Color(white: dim ? 0.55 : 0.75)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1.5)
        }
    }
}

/// What the drop places do with files, shared by the shake grid and the island.
@MainActor
enum QuickDropActions {
    /// The files to AirDrop's picker.
    static func airDrop(_ urls: [URL]) {
        NSApp.activate()
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            FeedbackHUD.show("AirDrop isn't available", symbol: "exclamationmark.triangle.fill", subtitle: "Turn on Wi-Fi and Bluetooth")
            return
        }
        service.perform(withItems: urls)
    }
}
