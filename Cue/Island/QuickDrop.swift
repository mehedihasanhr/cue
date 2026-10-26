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

/// Four tiles on a black slab: drop on one to send the files there. Drawn after
/// Droppy's: near-black tiles, softly lit glyphs, the share link as a small app
/// icon, and the tile under the files lifted rather than outlined.
struct QuickDropGrid: View {
    static let size = CGSize(width: 300, height: 300)
    private static let radius: CGFloat = 38
    private static let tileRadius: CGFloat = 24

    let model: QuickDropModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<2) { row in
                GridRow {
                    ForEach(QuickDropTarget.allCases.filter { $0.row == row }, id: \.self) { target in
                        tile(target)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: Self.size.width - 24, height: Self.size.height - 24)
        .background {
            shape.fill(Color(white: 0.02).opacity(0.97))
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
        }
        .overlay(shape.strokeBorder(.white.opacity(0.06), lineWidth: 1))
        .scaleEffect(model.shown ? 1 : 0.86)
        .opacity(model.shown ? 1 : 0)
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.78), value: model.shown)
        .animation(.easeOut(duration: 0.16), value: model.hovered)
        .environment(\.colorScheme, .dark)
    }

    private func tile(_ target: QuickDropTarget) -> some View {
        let lit = model.hovered == target
        let off = target == .share && !model.canShare
        let shape = RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous)
        return VStack(spacing: 12) {
            glyph(target, off: off)
                .frame(height: 46)
                .scaleEffect(lit ? 1.08 : 1)
                .offset(y: lit ? -2 : 0)
            VStack(spacing: 2) {
                Text(target.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(white: off ? 0.45 : (lit ? 0.97 : 0.84)))
                    .multilineTextAlignment(.center)
                if off {
                    Text("Set up in Settings")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            shape.fill(LinearGradient(colors: [Color(white: lit ? 0.2 : 0.085), Color(white: lit ? 0.15 : 0.055)],
                                      startPoint: .top, endPoint: .bottom))
        }
        .overlay(shape.strokeBorder(.white.opacity(lit ? 0.12 : 0.035), lineWidth: 1))
    }

    /// The tile's picture: a softly lit glyph, or for the share link a small app icon.
    @ViewBuilder
    private func glyph(_ target: QuickDropTarget, off: Bool) -> some View {
        if target == .share {
            let badge = RoundedRectangle(cornerRadius: 12, style: .continuous)
            ZStack {
                badge.fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
                badge.strokeBorder(.white.opacity(0.1), lineWidth: 0.75)
                Icon("link", size: 21, weight: .bold)
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.62, green: 0.6, blue: 1), Color(red: 0.4, green: 0.42, blue: 0.98)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            .frame(width: 46, height: 46)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
            .saturation(off ? 0 : 1)
            .opacity(off ? 0.5 : 1)
        } else {
            Icon(target.symbol, size: 30, weight: .medium)
                .foregroundStyle(LinearGradient(colors: [Color(white: 0.95), Color(white: target == .basket ? 0.55 : 0.75)],
                                                startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1.5)
        }
    }
}

/// A menu item that runs a closure.
nonisolated final class QuickDropMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Menus act on the main thread.
    @objc private func run() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}
