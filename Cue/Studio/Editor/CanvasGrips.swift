import AppKit
import SwiftUI

/// The grips a box on the picture is resized by — one look for every box in the editor.
///
/// They used to be little white squares with a hard shadow, the look of a nineties drawing
/// program, and a different size in every overlay. Now: a round knob at each corner, a slim
/// pill along each side, both white with the accent round them so they read on any
/// picture, and a little larger under the pointer so there is no doubt which one is about to
/// move. The grab area stays generous whatever is drawn.
struct CanvasGrip: View {
    enum Shape {
        case corner
        /// A side: `vertical` for the left and right sides, which pull across.
        case side(vertical: Bool)
    }

    let shape: Shape
    let cursor: NSCursor
    @State private var isHovering = false

    static let knob: CGFloat = 9
    static let pill = CGSize(width: 18, height: 5)

    var body: some View {
        drawn
            .scaleEffect(isHovering ? 1.25 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            // Room to aim: nine points is a small target on a moving picture.
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .onHover { inside in
                isHovering = inside
                if inside { cursor.push() } else { NSCursor.pop() }
            }
    }

    @ViewBuilder
    private var drawn: some View {
        switch shape {
        case .corner:
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                .frame(width: Self.knob, height: Self.knob)
                .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
        case .side(let vertical):
            Capsule()
                .fill(Color.white)
                .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 1.25))
                .frame(width: vertical ? Self.pill.height : Self.pill.width,
                       height: vertical ? Self.pill.width : Self.pill.height)
                .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
        }
    }

    /// Sides shorter than this get no pill: on a small box the pills crowd the corners and
    /// cover the very thing being sized.
    static let shortestSideWithPill: CGFloat = 44
}

/// The outline of a selected box: a thin line in the accent, with a faint light edge beside
/// it so it can be followed over a dark picture as well as a light one.
struct SelectionOutline: View {
    var cornerRadius: CGFloat = 2
    var dashed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 2.5)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, style: SwiftUI.StrokeStyle(lineWidth: 1.25, dash: dashed ? [4, 3] : []))
                .padding(0.6)
        }
        .allowsHitTesting(false)
    }
}

/// A corner of the crop: a bracket, as Photos draws one, rather than a square on top of the
/// very corner being judged.
struct CropBracket: View {
    /// Which way the bracket's arms run from the corner: +1 or −1 on each axis.
    let horizontal: CGFloat
    let vertical: CGFloat
    var length: CGFloat = 18
    var thickness: CGFloat = 3.5

    var body: some View {
        ZStack {
            // A darker line under the white one, so the bracket reads on a white page too.
            bracket.stroke(Color.black.opacity(0.35),
                           style: SwiftUI.StrokeStyle(lineWidth: thickness + 1.5, lineCap: .round, lineJoin: .round))
            bracket.stroke(Color.white, style: SwiftUI.StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))
        }
        .frame(width: length * 2, height: length * 2)
    }

    /// From the corner outwards along both edges, set in by half its thickness so the whole
    /// bracket sits on the picture rather than half of it off the edge.
    private var bracket: Path {
        Path { path in
            let origin = CGPoint(x: length + horizontal * thickness / 2, y: length + vertical * thickness / 2)
            path.move(to: CGPoint(x: origin.x + horizontal * length, y: origin.y))
            path.addLine(to: origin)
            path.addLine(to: CGPoint(x: origin.x, y: origin.y + vertical * length))
        }
    }
}
