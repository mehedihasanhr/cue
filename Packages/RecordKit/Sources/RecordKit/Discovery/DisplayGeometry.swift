import CoreGraphics
import Foundation

/// Moving a rectangle between the two coordinate systems a Mac screen has.
///
/// The window server, ScreenCaptureKit and every capture API put the origin at the **top
/// left** of the primary display with y increasing downwards. AppKit puts it at the
/// **bottom left** with y increasing upwards. Both call their rectangles `CGRect`, both
/// are in points, and nothing in the type system objects when one is used as the other —
/// the only symptom is an overlay drawn at the mirror of where it belongs, which looks
/// plausible on a laptop screen and obviously wrong on a tall external display.
///
/// This lives here, in a package with tests, rather than as a private method on the view
/// that needs it, because that mistake has already been made once in this project: a
/// zoom's anchor was read in one convention and applied in the other, and every off-centre
/// zoom was vertically mirrored for months without anyone noticing.
public enum DisplayGeometry {
    /// A window-server rectangle as AppKit screen coordinates.
    ///
    /// - Parameters:
    ///   - frame: the rectangle, origin at the top left of the primary display.
    ///   - primaryMaxY: the top edge of the primary display in AppKit coordinates — which
    ///     is `NSScreen.screens.first?.frame.maxY`, and *not* the height of the screen the
    ///     rectangle happens to be on. The global space is built on one origin; measuring
    ///     against a second display's own height is how a window on it lands at the wrong
    ///     height by exactly the difference between the two.
    public static func appKit(_ frame: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: frame.minX,
               y: primaryMaxY - frame.maxY,
               width: frame.width,
               height: frame.height)
    }

    /// The inverse, for going back the other way.
    public static func windowServer(_ frame: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: frame.minX,
               y: primaryMaxY - frame.maxY,
               width: frame.width,
               height: frame.height)
    }
}
