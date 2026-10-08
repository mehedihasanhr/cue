import AppKit
import SwiftUI

/// The mark, drawn from its paths. The body has the eyes punched out of it, so the
/// fill is even-odd.
struct KlikMarkView: View {
    var body: some View {
        KlikMarkShape()
            .fill(style: FillStyle(eoFill: true))
            .accessibilityHidden(true)
    }
}

/// The mark drawn into an `NSImage`, for the places AppKit owns — the status item
/// and its menu. A template image, so the system tints it for the menu bar.
@MainActor
enum KlikMarkImage {
    /// One image per size and openness. A few sizes and a blink's handful of
    /// steps: this fills up once and is read thereafter.
    private static var images: [Int: NSImage] = [:]

    static func template(height: CGFloat, eyesOpen: CGFloat = 1) -> NSImage {
        let key = Int(height.rounded()) * 100 + Int((eyesOpen * 20).rounded())
        if let cached = images[key] { return cached }
        let width = (KlikMark.size.width / KlikMark.size.height * height).rounded()
        let size = CGSize(width: width, height: height)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(KlikMark.path(in: rect, eyesOpen: eyesOpen))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Klik"
        images[key] = image
        return image
    }
}
