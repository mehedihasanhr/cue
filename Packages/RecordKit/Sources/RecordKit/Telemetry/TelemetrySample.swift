import CoreGraphics
import Foundation

/// The shape of the cursor at a moment, as something the editor can draw.
///
/// Not `NSCursor`: the recording outlives the process, and the editor has to draw the
/// pointer itself (at a different size, smoothed, with a click bounce). A name is what
/// survives; a system cursor object does not.
public enum CursorShape: String, Codable, Sendable, CaseIterable {
    case arrow, iBeam, pointingHand, openHand, closedHand, crosshair
    case resizeLeftRight, resizeUpDown, resizeDiagonal, disappearingItem
    case operationNotAllowed, dragCopy, dragLink, contextualMenu
    case busy
    case other
}

/// Where the pointer was, and what it looked like.
public struct CursorSample: Codable, Equatable, Sendable {
    /// Seconds since the recording's clock started.
    public var t: Double
    /// Points, in the recorded target's coordinate space, origin at its top left.
    public var x: Double
    public var y: Double
    public var shape: CursorShape

    public init(t: Double, x: Double, y: Double, shape: CursorShape) {
        self.t = t
        self.x = x
        self.y = y
        self.shape = shape
    }

    public var point: CGPoint { CGPoint(x: x, y: y) }
}

/// Something the user did with the mouse or keyboard.
///
/// One enum rather than three files: they interleave in time, and reading them back in
/// order is what an editor wants.
public enum InputSample: Codable, Equatable, Sendable {
    case mouseDown(t: Double, button: Int, x: Double, y: Double)
    case mouseUp(t: Double, button: Int, x: Double, y: Double)
    case scroll(t: Double, dx: Double, dy: Double)
    case key(t: Double, characters: String, modifiers: Int)

    public var t: Double {
        switch self {
        case .mouseDown(let t, _, _, _), .mouseUp(let t, _, _, _),
             .scroll(let t, _, _), .key(let t, _, _): t
        }
    }
}

/// Where the recorded window was, when it moved.
///
/// Recorded so the editor can re-frame afterwards: a window dragged mid-take otherwise
/// leaves the zoom pointing at empty desktop.
public struct WindowBoundsSample: Codable, Equatable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(t: Double, rect: CGRect) {
        self.t = t
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// What had the user's attention, and where it was on screen.
///
/// The other half of "zoom where the work is". Clicks say where someone pointed;
/// this says what they were pointing *at* — the window they brought forward, the text
/// field they tabbed into, the sheet that just opened. A click tells the editor a
/// point; a focus event tells it a rectangle, which is enough to choose how far in to
/// go as well as where.
///
/// Recorded as its own track rather than folded into `InputSample` because the two come
/// from different places at different rates: input is an event stream, focus is a state
/// that changes a handful of times a minute and is worth sampling for movement in
/// between.
public struct FocusSample: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A different application came forward.
        case application
        /// The frontmost window changed, moved or resized.
        case window
        /// Keyboard focus landed somewhere text goes. Needs the Accessibility grant;
        /// absent from recordings made without it.
        case field
    }

    /// Seconds since the recording's clock started.
    public var t: Double
    public var kind: Kind
    /// The focused thing's bounds, in the recorded target's space, origin at its top
    /// left — the same space `CursorSample` is in, so the two can be reasoned about
    /// together without a second mapping.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Who holds focus, when it is known. Kept for the editor's benefit: "zoom on every
    /// switch to Terminal" is a sensible thing to want, and it cannot be asked for
    /// without this.
    public var app: String?

    public init(t: Double, kind: Kind, rect: CGRect, app: String? = nil) {
        self.t = t
        self.kind = kind
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
        self.app = app
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
}
