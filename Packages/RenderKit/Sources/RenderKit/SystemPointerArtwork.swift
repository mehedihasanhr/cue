import CoreGraphics
import CoreImage
import Foundation
import TimelineKit

/// The system's own pointers — macOS 26's and the classic one — drawn from the artwork
/// this Mac keeps for Accessibility's pointer colours.
///
/// Read from the Mac the video is made on rather than shipped with the app: the same
/// pictures a screen recording of that Mac would have caught, now drawn at the frame's own
/// size instead of the recording's. Each pointer is two vector layers, the body and the
/// outline round it, which is how Accessibility recolours them — and how these styles are
/// white or coloured as well as black.
///
/// Where the artwork is not on this Mac, there is no drawing, and the renderer falls back
/// to its own.
enum SystemPointerArtwork {
    enum Generation: Sendable {
        /// macOS 26's rounded arrow and tilted hand.
        case current
        /// The arrow and hand macOS drew from 10.0 to 15.
        case classic

        fileprivate var folder: String {
            switch self {
            case .current: "Cursors-macOS16"
            case .classic: "Cursors"
            }
        }
    }

    private static let root = URL(fileURLWithPath:
        "/System/Library/PrivateFrameworks/AccessibilitySupport.framework/Versions/A/Frameworks/AccessibilityFoundation.framework/Versions/A/Resources")

    /// A system pointer's size against the drawn arrow's at the same setting: one point
    /// of the system's artwork to every 1/14 of the size, which makes the system arrow —
    /// seventeen points tall — as tall as the drawn one, so changing style does not
    /// change how big the pointer is.
    static let pointsAcross = 14.0

    /// What the style's generation and colours are, or `nil` for a style that is not a
    /// system pointer.
    static func ink(for appearance: CursorStyle.Appearance, color: ColorValue)
        -> (generation: Generation, body: CGColor, outline: CGColor)? {
        let black = CGColor(gray: 0, alpha: 1), white = CGColor(gray: 1, alpha: 1)
        switch appearance {
        case .macOS26: return (.current, black, white)
        case .macOS14: return (.classic, black, white)
        case .macOS26White: return (.current, white, black)
        case .macOS14White: return (.classic, white, black)
        case .macOS26Colour:
            let body = CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
            return (.current, body, white)
        case .asRecorded, .largeArrow, .minimal, .dot, .clicksOnly: return nil
        }
    }

    /// The artwork's name for each shape.
    private static func name(of shape: CursorShapeKind) -> String {
        switch shape {
        case .arrow: "arrow"
        case .pointingHand: "hand"
        case .openHand: "handOpened"
        case .iBeam: "iBeam"
        case .crosshair: "cross"
        case .resizeHorizontal: "resizeLeftRight"
        case .resizeVertical: "resizeUpDown"
        }
    }

    /// One shape's two layers, read once.
    private struct Artwork: @unchecked Sendable {
        // `CGPDFPage` is immutable once read and drawing it from several threads is safe;
        // the documents are held so the pages stay valid.
        let documents: [CGPDFDocument]
        let body: CGPDFPage
        let outline: CGPDFPage
        /// The artwork's whole canvas, in points.
        let box: CGRect
        /// The part of the canvas the pointer covers, outline and all, in points from the
        /// canvas's top-left: most of a system pointer's canvas is empty, and a drawing
        /// that kept it would sit in the corner of its own picture.
        let content: CGRect
        /// Its point, in points from the canvas's top-left: where the system's own
        /// hotspot is, found from the body the way the system places it — the arrow's tip,
        /// the pointing fingertip, the middle of anything else.
        let hotspot: CGPoint
    }

    private struct ArtworkKey: Hashable, Sendable {
        let generation: Generation
        let shape: CursorShapeKind
    }

    /// Fourteen at most, and each is a pair of small PDFs.
    private static let artworks = ArtworkCache<ArtworkKey, Artwork>(capacity: 16)

    private static func artwork(_ generation: Generation, _ shape: CursorShapeKind) -> Artwork? {
        artworks.value(for: ArtworkKey(generation: generation, shape: shape)) {
            let folder = root.appendingPathComponent(generation.folder)
            let base = name(of: shape)
            guard let bodyDocument = CGPDFDocument(folder.appendingPathComponent("\(base)-bottom.pdf") as CFURL),
                  let outlineDocument = CGPDFDocument(folder.appendingPathComponent("\(base)-top.pdf") as CFURL),
                  let body = bodyDocument.page(at: 1),
                  let outline = outlineDocument.page(at: 1)
            else { return nil }
            let box = body.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0,
                  let bodyMask = Mask(body, box: box),
                  let outlineMask = Mask(outline, box: box) else { return nil }
            return Artwork(documents: [bodyDocument, outlineDocument], body: body, outline: outline,
                           box: box, content: outlineMask.bounds.union(bodyMask.bounds),
                           hotspot: bodyMask.hotspot(for: shape))
        }
    }

    /// Whether this Mac has the artwork, so a test can tell "missing" from "wrong".
    static func isAvailable(_ generation: Generation) -> Bool {
        artwork(generation, .arrow) != nil
    }

    /// Where a layer is opaque, read from its pixels at ten to a point.
    private struct Mask {
        /// What it covers, in points from the canvas's top-left.
        let bounds: CGRect
        /// Its topmost row of pixels: where that row is, and its first and last column.
        let top: (y: Double, minX: Double, maxX: Double)

        private static let detail = 10.0

        init?(_ page: CGPDFPage, box: CGRect) {
            let detail = Self.detail
            let width = Int((box.width * detail).rounded(.up)), height = Int((box.height * detail).rounded(.up))
            var alpha = [UInt8](repeating: 0, count: width * height)
            let found = alpha.withUnsafeMutableBytes { buffer -> (CGRect, (Double, Double, Double))? in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
                else { return nil }
                context.scaleBy(x: detail, y: detail)
                context.translateBy(x: -box.minX, y: -box.minY)
                context.drawPDFPage(page)
                let pixels = buffer.bindMemory(to: UInt8.self)
                // A bitmap context's first row in memory is the top of the picture.
                var top: (row: Int, minX: Int, maxX: Int)?
                var minX = width, maxX = -1, minY = height, maxY = -1
                for row in 0..<height {
                    for column in 0..<width where pixels[row * width + column] > 127 {
                        minX = min(minX, column); maxX = max(maxX, column)
                        minY = min(minY, row); maxY = max(maxY, row)
                        if top == nil { top = (row, column, column) }
                        if top?.row == row { top?.maxX = column }
                    }
                }
                guard let top, maxX >= minX else { return nil }
                let bounds = CGRect(x: Double(minX) / detail, y: Double(minY) / detail,
                                    width: Double(maxX - minX + 1) / detail, height: Double(maxY - minY + 1) / detail)
                return (bounds, (Double(top.row) / detail, Double(top.minX) / detail, Double(top.maxX + 1) / detail))
            }
            guard let found else { return nil }
            bounds = found.0
            top = (y: found.1.0, minX: found.1.1, maxX: found.1.2)
        }

        /// The system's point for a shape drawn by this layer: the arrow's tip, the
        /// pointing fingertip, the middle of anything else.
        func hotspot(for shape: CursorShapeKind) -> CGPoint {
            switch shape {
            case .arrow:
                CGPoint(x: top.minX, y: top.y)
            case .pointingHand:
                CGPoint(x: (top.minX + top.maxX) / 2, y: top.y)
            case .openHand, .iBeam, .crosshair, .resizeHorizontal, .resizeVertical:
                CGPoint(x: bounds.midX, y: bounds.midY)
            }
        }
    }

    /// The pointer for a shape at a pointer size in output pixels, in the given colours,
    /// with the system's soft shadow under it.
    static func drawing(_ generation: Generation, shape: CursorShapeKind, size: Double,
                        body: CGColor, outline: CGColor) -> PointerStyleArtwork.Drawing? {
        guard let artwork = artwork(generation, shape) else { return nil }
        let unit = size / pointsAcross
        // The system's shadow: two points of blur, a point down, a little under half dark.
        let blur = 2 * unit
        let margin = blur + unit
        let content = artwork.content
        let width = Int((content.width * unit + margin * 2).rounded(.up))
        let height = Int((content.height * unit + margin * 2).rounded(.up))
        guard width > 1, height > 1,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)

        // PDF space runs up, as Core Graphics does, so the artwork is drawn as it is and
        // only moved: the content's bottom-left to the margin's. `content` is measured from
        // the top, so its bottom is the canvas's height less its far edge.
        func place(_ page: CGPDFPage, in colour: CGColor) {
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.saveGState()
            context.translateBy(x: margin, y: margin)
            context.scaleBy(x: unit, y: unit)
            context.translateBy(x: -content.minX, y: -(artwork.box.height - content.maxY))
            context.translateBy(x: -artwork.box.minX, y: -artwork.box.minY)
            context.drawPDFPage(page)
            context.restoreGState()
            // The layer's own shape, filled with the colour asked for.
            context.saveGState()
            context.setBlendMode(.sourceIn)
            context.setFillColor(colour)
            context.fill(canvas)
            context.restoreGState()
            context.endTransparencyLayer()
        }

        context.setShadow(offset: CGSize(width: 0, height: -unit), blur: blur,
                          color: CGColor(gray: 0, alpha: 0.45))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        place(artwork.body, in: body)
        place(artwork.outline, in: outline)
        context.endTransparencyLayer()

        guard let image = context.makeImage() else { return nil }
        let point = CGPoint(x: margin + (artwork.hotspot.x - content.minX) * unit,
                            y: margin + (artwork.hotspot.y - content.minY) * unit)
        return PointerStyleArtwork.Drawing(image: CIImage(cgImage: image),
                                           hotspot: CGPoint(x: point.x / Double(width),
                                                            y: point.y / Double(height)))
    }
}
