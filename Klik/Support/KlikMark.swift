import AppKit
import SwiftUI

/// Klik's mark, as paths rather than a picture, so its eyes can close: the body is
/// drawn with the eyes punched out of it (even-odd), and a blink is the eyes losing
/// their height. The flat SVG in the asset catalog stays the source of truth — this
/// file is generated from it — and is still what a static NSImage uses. The path
/// data is parsed by `SVGPath` in Icon.swift, the same parser the icon set uses.
nonisolated enum KlikMark {
    /// The artwork's own size; every path below is in these coordinates.
    static let size = CGSize(width: 670.0, height: 705.0)

    private static let bodyData = "M140.678 0.257704C152.389 -0.707721 172.455 1.25799 185.63 2.54859C186.251 2.60936 186.856 2.66865 "
        + "187.444 2.72604C187.887 2.7692 188.319 2.81129 188.742 2.85219L253.062 9.26221C316.339 15.8832 "
        + "379.526 23.3229 442.608 31.5776L499.497 39.4067C502.25 39.793 504.955 40.1623 507.617 "
        + "40.5259C532.828 43.9687 554.287 46.8992 578.448 58.8557C619.178 79.0127 644.956 109.306 659.435 "
        + "152.242C664.737 167.656 667.96 183.708 669.018 199.974C669.979 213.577 669.825 230.519 669.684 "
        + "246.053C669.638 251.093 669.594 255.986 669.59 260.567L668.366 395.655L668.242 503.458C668.24 "
        + "508.701 668.29 513.913 668.339 519.095C668.681 554.88 669.009 589.265 652.097 622.881C599.649 "
        + "727.117 436.66 737.82 397.419 615.98C393.212 601.771 391.563 591.898 390.714 576.964C387.72 579.123 "
        + "383.495 582.794 379.436 586.32C376.766 588.639 374.169 590.895 372.041 592.618C359.278 602.97 "
        + "345.789 612.388 331.673 620.808C278.381 652.216 217.528 666.708 156.559 650.936C103.221 637.182 "
        + "57.6381 602.589 30.0347 554.918C-42.709 430.667 27.7134 304.424 141.171 238.563C135.13 238.657 "
        + "128.866 238.718 122.814 238.374C-32.1149 229.58 -40.4203 56.1179 97.6579 7.885C112.444 2.71997 "
        + "124.894 1.26277 140.678 0.257704Z "

    private static let leftEyeData = "M360.816 228.982C384.17 227.428 402.438 245.011 413.466 264.166C434.182 300.157 444.121 353.213 "
        + "434.354 393.711C426.235 427.395 402.542 456.36 365.084 446.174C341.883 436.83 324.969 415.049 320.43 "
        + "390.174C317.784 375.689 325.494 369.463 333.976 362.613C337.07 360.115 340.267 357.533 343.101 "
        + "354.437C345.5 351.81 346.65 346.071 345.635 342.571C343.116 334.236 336.158 332.338 329.123 "
        + "330.419C320.856 328.164 312.481 325.879 311.07 313.088C307.637 281.98 326.507 234.529 360.816 "
        + "228.982Z "

    private static let rightEyeData = "M569.074 221.262C559.251 204.679 544.003 190.841 523.817 192.596C509.928 196.304 501.655 203.987 "
        + "493.5 217.283C485.399 230.489 469.721 275.691 489.096 286.294C491.409 287.56 494.287 288.446 497.205 "
        + "289.345C506.404 292.178 516.003 295.134 509.596 310.504C508.686 312.636 503.427 317.57 501.299 "
        + "318.892C472.476 336.777 498.691 381.403 520.452 394.818C523.577 396.732 526.923 398.257 530.416 "
        + "399.358C564.006 407.231 584.131 378.217 590.589 348.858C599.606 307.905 590.196 257.339 569.074 "
        + "221.262Z "

    // Parsed once, then only read: CGPath is not Sendable, but these are immutable.
    nonisolated(unsafe) private static let body = SVGPath.path(bodyData)
    nonisolated(unsafe) private static let eyes = [SVGPath.path(leftEyeData), SVGPath.path(rightEyeData)]

    /// One eye, fitted to `box` exactly, `open` from 0 to 1. The chrome face is a
    /// different drawing from the flat mark — its holes sit a little differently — so
    /// the icon places each eye in the hole it measured rather than trusting the mark.
    static func eye(_ index: Int, fitting box: CGRect, open: CGFloat) -> CGPath {
        guard eyes.indices.contains(index) else { return CGMutablePath() }
        let eye = eyes[index]
        let source = eye.boundingBox
        guard source.width > 0, source.height > 0 else { return eye }
        let fit = CGAffineTransform(translationX: box.minX, y: box.minY)
            .scaledBy(x: box.width / source.width, y: box.height / source.height)
            .translatedBy(x: -source.minX, y: -source.minY)
        let lidded = lid(for: eye, open: open).concatenating(fit)
        let path = CGMutablePath()
        path.addPath(eye, transform: lidded)
        return path
    }

    /// Just the eyes, in `rect` (the mark's own box), `open` from 0 to 1 — for the
    /// app icon, where the face is a picture and only the holes are drawn.
    static func eyes(in rect: CGRect, open: CGFloat) -> CGPath {
        let scale = min(rect.width / size.width, rect.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let fit = CGAffineTransform(translationX: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)
            .scaledBy(x: scale, y: scale)
        let combined = CGMutablePath()
        for eye in eyes {
            combined.addPath(eye, transform: lid(for: eye, open: open).concatenating(fit))
        }
        return combined
    }

    /// An eye closes towards its own middle, the way a lid comes down. The lid is
    /// applied in the eye's own coordinates, so both eyes close by the same fraction
    /// of their own height however they are placed.
    private static func lid(for eye: CGPath, open: CGFloat) -> CGAffineTransform {
        let centre = eye.boundingBox.midY
        return CGAffineTransform(translationX: 0, y: centre)
            .scaledBy(x: 1, y: max(min(max(open, 0), 1), 0.001))
            .translatedBy(x: 0, y: -centre)
    }

    /// The mark in `rect`, with the eyes `open` from 0 (shut) to 1.
    static func path(in rect: CGRect, eyesOpen open: CGFloat) -> CGPath {
        let scale = min(rect.width / size.width, rect.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let fit = CGAffineTransform(translationX: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)
            .scaledBy(x: scale, y: scale)
        let combined = CGMutablePath()
        combined.addPath(body, transform: fit)
        for eye in eyes {
            combined.addPath(eye, transform: lid(for: eye, open: open).concatenating(fit))
        }
        return combined
    }
}

/// The mark as a shape: `eyesOpen` animates, so a blink is an animation like any other.
nonisolated struct KlikMarkShape: Shape {
    var eyesOpen: CGFloat = 1

    var animatableData: CGFloat {
        get { eyesOpen }
        set { eyesOpen = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(KlikMark.path(in: rect, eyesOpen: eyesOpen))
    }
}
