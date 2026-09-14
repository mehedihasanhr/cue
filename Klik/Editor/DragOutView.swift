import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A grab handle: drag it into Finder, Slack, WhatsApp, a browser… and the receiver
/// gets a PNG of the current document (rendered at drag start, so unsaved
/// annotations are included) via a file promise.
struct DragOutView: NSViewRepresentable {
    let fileName: String
    let render: () -> Data?
    let thumbnail: () -> NSImage?

    func makeNSView(context: Context) -> DragOutControl {
        let view = DragOutControl()
        view.fileName = fileName
        view.render = render
        view.thumbnail = thumbnail
        return view
    }

    func updateNSView(_ view: DragOutControl, context: Context) {
        view.fileName = fileName
        view.render = render
        view.thumbnail = thumbnail
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DragOutControl, context: Context) -> CGSize? {
        CGSize(width: 32, height: 28)
    }
}

final class DragOutControl: NSView, NSDraggingSource {
    var fileName = "Screenshot.png"
    var render: (() -> Data?)?
    var thumbnail: (() -> NSImage?)?
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
        guard let image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Drag out")?.withSymbolConfiguration(config) else { return }
        let size = image.size
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        NSColor.labelColor.withAlphaComponent(0.85).set()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let data = render?() else { return }
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: FilePromiseWriter(data: data, fileName: fileName))
        let item = NSDraggingItem(pasteboardWriter: provider)
        let preview = thumbnail?() ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!
        let previewSize = Self.fit(preview.size, in: CGSize(width: 240, height: 180))
        item.setDraggingFrame(CGRect(x: 0, y: 0, width: previewSize.width, height: previewSize.height), contents: preview)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    private static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Writes the pre-rendered PNG when the receiving app asks for the promised file.
/// Called on the promise's operation queue, hence `nonisolated`.
private nonisolated final class FilePromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    private let data: Data
    private let fileName: String

    init(data: Data, fileName: String) {
        self.data = data
        self.fileName = fileName
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        do {
            try data.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
