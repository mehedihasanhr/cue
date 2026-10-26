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

/// Four tiles in a glass square: drop on one to send the files there.
struct QuickDropGrid: View {
    static let size = CGSize(width: 300, height: 300)
    private static let radius: CGFloat = 34

    let model: QuickDropModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(0..<2) { row in
                GridRow {
                    ForEach(QuickDropTarget.allCases.filter { $0.row == row }, id: \.self) { target in
                        tile(target)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: Self.size.width - 20, height: Self.size.height - 20)
        .background {
            ZStack {
                if #available(macOS 26, *) {
                    shape.fill(.clear).glassEffect(.regular.tint(.black.opacity(0.55)), in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(.black.opacity(0.55))
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        }
        .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .scaleEffect(model.shown ? 1 : 0.8)
        .opacity(model.shown ? 1 : 0)
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.72), value: model.shown)
        .animation(.easeOut(duration: 0.14), value: model.hovered)
        .environment(\.colorScheme, .dark)
    }

    private func tile(_ target: QuickDropTarget) -> some View {
        let lit = model.hovered == target
        let off = target == .share && !model.canShare
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(spacing: 10) {
            Icon(target.symbol, size: 28, weight: .medium)
                .foregroundStyle(.white.opacity(off ? 0.35 : (lit ? 1 : 0.8)))
                .offset(y: lit ? -2 : 0)
            VStack(spacing: 2) {
                Text(target.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(off ? 0.45 : 0.92))
                if off {
                    Text("Set up in Settings")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(.white.opacity(lit ? 0.16 : 0.06)))
        .overlay(shape.strokeBorder(lit ? IslandStyle.accent.opacity(0.85) : .clear, lineWidth: 1.5))
        .scaleEffect(lit ? 1.04 : 1)
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
