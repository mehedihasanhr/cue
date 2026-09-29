import AppKit
import Testing
@testable import RecordKit

/// Naming the pointer from another app's window.
///
/// `NSCursor.currentSystem` never hands back the shared `NSCursor.pointingHand` for the
/// hand over a browser link: it builds a new cursor with the same picture. These make the
/// same kind of cursor — a fresh object, the system's picture — and check it is still named
/// for what it looks like.
@MainActor
struct CursorRecognitionTests {
    init() {
        // The arrow and the I-beam have no picture to read until there is an application.
        _ = NSApplication.shared
    }

    /// A cursor that is the given one in every way except identity.
    private func lookalike(_ cursor: NSCursor, scale: CGFloat = 1) -> NSCursor {
        let source = cursor.image
        let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        return NSCursor(image: image,
                        hotSpot: CGPoint(x: cursor.hotSpot.x * scale, y: cursor.hotSpot.y * scale))
    }

    /// The cursor a shape is named for. Arguments are the shapes rather than the cursors,
    /// because an `NSCursor` cannot cross into a parameterised test.
    private func system(_ shape: CursorShape) -> NSCursor {
        switch shape {
        case .arrow: .arrow
        case .iBeam: .iBeam
        case .pointingHand: .pointingHand
        case .openHand: .openHand
        case .crosshair: .crosshair
        case .resizeLeftRight: .resizeLeftRight
        case .resizeUpDown: .resizeUpDown
        case .operationNotAllowed: .operationNotAllowed
        case .dragCopy: .dragCopy
        case .contextualMenu: .contextualMenu
        default: .arrow
        }
    }

    @Test(arguments: [CursorShape.arrow, .iBeam, .pointingHand, .openHand, .crosshair,
                      .resizeLeftRight, .resizeUpDown, .operationNotAllowed, .dragCopy, .contextualMenu])
    func anotherAppsCursorIsNamedByItsPicture(expected: CursorShape) {
        let cursor = system(expected)
        let copy = lookalike(cursor)
        #expect(copy !== cursor)
        #expect(CursorShape(copy) == expected)
    }

    /// The case that was reported: the hand over a link, recorded as an arrow.
    @Test func theHandOverALinkIsAHand() {
        #expect(CursorShape(lookalike(.pointingHand)) == .pointingHand)
    }

    /// Made larger in Accessibility settings, the hand is still a hand.
    @Test func anEnlargedPointerIsStillRecognised() {
        #expect(CursorShape(lookalike(.pointingHand, scale: 1.75)) == .pointingHand)
        #expect(CursorShape(lookalike(.arrow, scale: 2)) == .arrow)
    }

    /// These are the arrow with a badge — same size, same point. The badge has to be
    /// enough to tell them apart, or every "copy" drag would be drawn as a plain arrow.
    @Test func theArrowWithABadgeIsNotTheArrow() {
        for cursor in [NSCursor.operationNotAllowed, .dragCopy, .contextualMenu] {
            #expect(CursorShape(lookalike(cursor)) != .arrow)
        }
    }

    /// Something that is none of the system's cursors stays `other`.
    @Test func aCustomCursorIsOther() {
        let image = NSImage(size: CGSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            return true
        }
        #expect(CursorShape(NSCursor(image: image, hotSpot: CGPoint(x: 16, y: 16))) == .other)
    }
}
