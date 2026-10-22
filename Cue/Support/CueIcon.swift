import AppKit
import SwiftUI

/// The app icon, drawn rather than shipped flat so it can be produced at whatever
/// size is asked for. The tile and the chrome face are bundled separately (Brand/)
/// and composited here.
@MainActor
enum CueIcon {
    /// Apple's grid: an 824 pt body on a 1024 pt canvas, the rest left for the shadow.
    private static let canvas: CGFloat = 1024, body: CGFloat = 824
    /// Where the face sits on the tile, from the Figma frame (tile at 8, 4.7; face at 229, 195).
    private static let tileSize = CGSize(width: 1099.503, height: 1090.671)
    private static let faceOrigin = CGPoint(x: 221, y: 190.301)
    private static let faceSize = CGSize(width: 669.789, height: 704.215)
    private static let tile = NSImage(contentsOf: Bundle.main.url(forResource: "icon-tile", withExtension: "png") ?? URL(fileURLWithPath: "/"))
    private static let face = NSImage(contentsOf: Bundle.main.url(forResource: "icon-mark", withExtension: "png") ?? URL(fileURLWithPath: "/"))
    /// One image per size, drawn once. Compositing the tile and the face is not
    /// free, and the handful of sizes the app asks for never change.
    private static var images: [Int: NSImage] = [:]

    /// The icon at `side` points. Falls back to the flat icon in the asset catalog
    /// if the pieces are missing.
    static func image(side: CGFloat) -> NSImage {
        let key = Int(side.rounded())
        if let cached = images[key] { return cached }
        guard let tile, let face else { return NSImage(named: "AppIcon") ?? NSApp.applicationIconImage }

        let scale = side / canvas
        let bodyScale = body / max(tileSize.width, tileSize.height) * scale
        let tileRect = CGRect(x: (side - tileSize.width * bodyScale) / 2, y: (side - tileSize.height * bodyScale) / 2,
                              width: tileSize.width * bodyScale, height: tileSize.height * bodyScale)
        // Core Graphics counts up from the bottom; Figma counts down from the top.
        let faceRect = CGRect(x: tileRect.minX + faceOrigin.x * bodyScale,
                              y: tileRect.maxY - (faceOrigin.y + faceSize.height) * bodyScale,
                              width: faceSize.width * bodyScale, height: faceSize.height * bodyScale)

        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.interpolationQuality = .high
            // The artwork untouched: the face carries its own eye holes.
            tile.draw(in: tileRect)
            face.draw(in: faceRect)
            return true
        }
        images[key] = image
        return image
    }
}

/// The app icon in SwiftUI.
struct AppIconView: View {
    var side: CGFloat = 28

    var body: some View {
        Image(nsImage: CueIcon.image(side: side * 2))
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
    }
}
