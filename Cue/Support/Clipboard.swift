import AppKit
import os

/// Copies images without making the user wait. The pasteboard gets a *promise* of PNG
/// and TIFF data; the PNG is encoded in the background straight away, and whichever
/// app pastes receives it the moment it asks — if that is before the encode finished,
/// the request simply waits for it. Copy itself returns in microseconds, so feedback
/// can show at once, and a ⌘V right after ⌘C still pastes the right image.
@MainActor
enum Clipboard {
    /// Providers stay alive until the pasteboard says it is done with them.
    private static var providers: [ImageProvider] = []
    /// Marks Cue's own image copies so the clipboard history skips them (captures
    /// are listed already).
    nonisolated static let ownMarker = NSPasteboard.PasteboardType("com.stackrover.cue.capture")

    /// With `fileURL`, the original file rides along (an SVG pastes as itself in
    /// Finder and as a bitmap in an image editor).
    static func copy(_ image: CGImage, fileURL: URL? = nil, to pasteboard: NSPasteboard = .general) {
        let provider = ImageProvider(image: image)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        item.setData(Data(), forType: Clipboard.ownMarker) // captures are listed already
        if let fileURL { item.setString(fileURL.absoluteString, forType: .fileURL) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        provider.changeCount = pasteboard.changeCount
        providers.append(provider)
    }

    /// For data that is already encoded (a saved capture): plain and immediate. TIFF
    /// rides along, since apps that take only that (Pages, Mail's older editor) would
    /// otherwise see nothing to paste.
    static func copy(pngData: Data, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        if let tiff = NSBitmapImageRep(data: pngData)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        pasteboard.setData(Data(), forType: Clipboard.ownMarker)
    }

    /// Turns any outstanding promise into real data. Called before the app quits, so a
    /// copy made moments earlier survives; AppKit does this too, but belt and braces.
    static func resolvePromises(on pasteboard: NSPasteboard = .general) {
        guard let provider = providers.last, provider.changeCount == pasteboard.changeCount,
              let png = provider.pngData()
        else { return }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    fileprivate static func finished(_ provider: ImageProvider) {
        providers.removeAll { $0 === provider }
    }
}

/// Holds one image for the pasteboard and encodes it once, off the main thread.
private nonisolated final class ImageProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let image: CGImage
    private let encoded = OSAllocatedUnfairLock<Data?>(initialState: nil)
    private let ready = DispatchGroup()
    /// The pasteboard generation this provider wrote; stale once anything else is copied.
    var changeCount = 0

    init(image: CGImage) {
        self.image = image
        super.init()
        ready.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let data = ImageEncoding.png(image)
            encoded.withLock { $0 = data }
            ready.leave()
        }
    }

    /// The PNG, waiting for the background encode if it is still running.
    nonisolated func pngData() -> Data? {
        ready.wait()
        return encoded.withLock { $0 }
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .png:
            if let data = pngData() { item.setData(data, forType: .png) }
        case .tiff:
            if let data = NSBitmapImageRep(cgImage: image).tiffRepresentation { item.setData(data, forType: .tiff) }
        default:
            break
        }
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        MainActor.assumeIsolated { Clipboard.finished(self) }
    }
}
