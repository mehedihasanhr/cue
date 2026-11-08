import AppKit
import SwiftUI

/// What the quick wheel offers, clockwise from the top. The same things the
/// shortcuts and the menu bar do, in one ring under the pointer.
enum QuickAction: String, CaseIterable, Identifiable, Sendable {
    case captureArea, captureWindow, captureFullScreen, captureText, pickColor, quickTask, quickNote, record

    var id: Self { self }

    /// The word on the segment: one short word, so eight of them read round the ring.
    var short: String {
        switch self {
        case .captureArea: "Area"
        case .captureWindow: "Window"
        case .captureFullScreen: "Screen"
        case .captureText: "Text"
        case .pickColor: "Color"
        case .quickTask: "Task"
        case .quickNote: "Note"
        case .record: "Record"
        }
    }

    /// The whole name, shown in the middle while the segment is under the pointer.
    var title: String {
        switch self {
        case .captureArea: "Capture selected area"
        case .captureWindow: "Capture window"
        case .captureFullScreen: "Capture screen"
        case .captureText: "Capture text"
        case .pickColor: "Pick a color"
        case .quickTask: "Quick task"
        case .quickNote: "Quick note"
        case .record: "Record"
        }
    }

    var symbol: String {
        switch self {
        case .captureArea: "viewfinder"
        case .captureWindow: "macwindow"
        case .captureFullScreen: "display"
        case .captureText: "text.viewfinder"
        case .pickColor: "eyedropper"
        case .quickTask: "checklist"
        case .quickNote: "note.text"
        case .record: "record.circle"
        }
    }

    /// Record is red, the way it is everywhere else in Cue.
    var tint: Color? { self == .record ? Color(red: 0.86, green: 0.2, blue: 0.2) : nil }
}

@MainActor @Observable
final class QuickWheelModel {
    var shown = false
    /// The segment under the pointer.
    var hovered: QuickAction?
    var actions: [QuickAction] = QuickAction.allCases

    /// The middle: the whole name of what is under the pointer, else what the ring is.
    var caption: String { hovered?.title ?? "Quick actions" }
}

/// A ring of Cue's quick actions round the pointer, opened by a three-finger tap
/// (Settings › Island) or its shortcut. Moving onto a segment lights it; clicking it,
/// or letting go of the tap over it, does the thing and the ring goes.
///
/// It is drawn like the convert wheel — the same disc, segments and glass — so the
/// two read as one thing in two places.
struct QuickWheelView: View {
    let model: QuickWheelModel
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var ink: Color { dark ? .white : Color(red: 0.11, green: 0.11, blue: 0.11) }

    var body: some View {
        let count = model.actions.count
        ZStack {
            Circle()
                .fill(.clear)
                .frame(width: WheelGeometry.outer * 2 + WheelGeometry.rim * 2, height: WheelGeometry.outer * 2 + WheelGeometry.rim * 2)
                .modifier(WheelGlass(dark: dark))
            ForEach(Array(model.actions.enumerated()), id: \.element) { index, action in
                segment(action, index: index, count: count)
            }
            centre
        }
        .frame(width: WheelGeometry.window.width, height: WheelGeometry.window.height)
        .scaleEffect(model.shown ? 1 : 0.6)
        .rotationEffect(.degrees(model.shown ? 0 : -25))
        .opacity(model.shown ? 1 : 0)
        .animation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.7), value: model.shown)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: model.hovered)
    }

    private func segment(_ action: QuickAction, index: Int, count: Int) -> some View {
        let lit = model.hovered == action
        let step = 360 / Double(count)
        let middle = Angle.degrees(Double(index) * step)
        let shape = RingSegment(start: .degrees(Double(index) * step - step / 2), end: .degrees(Double(index) * step + step / 2),
                                inner: WheelGeometry.inner, outer: WheelGeometry.outer, gap: WheelGeometry.gap, corner: 14)
        let radius = (WheelGeometry.inner + WheelGeometry.outer) / 2 + 4
        let offset = CGSize(width: sin(middle.radians) * radius, height: -cos(middle.radians) * radius)
        return ZStack {
            shape.fill(segmentFill(lit: lit))
            shape.stroke(.white.opacity(dark ? 0.12 : 0.65), lineWidth: 1)
            VStack(spacing: 3) {
                Icon(action.symbol, size: 20, weight: .medium)
                    .foregroundStyle(action.tint ?? ink)
                Text(action.short)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .offset(offset)
        }
        .frame(width: WheelGeometry.window.width, height: WheelGeometry.window.height)
        .scaleEffect(lit ? 1.04 : 1)
        .shadow(color: .black.opacity(lit ? 0.18 : 0), radius: 8, y: 3)
    }

    private func segmentFill(lit: Bool) -> AnyShapeStyle {
        if dark { return AnyShapeStyle(Color.white.opacity(lit ? 0.26 : 0.1)) }
        return AnyShapeStyle(LinearGradient(colors: [.white.opacity(lit ? 0.95 : 0.62), .white.opacity(lit ? 0.85 : 0.45)],
                                            startPoint: .top, endPoint: .bottom))
    }

    /// The middle: Cue's mark, and under it the name of whatever is under the pointer.
    private var centre: some View {
        let side = (WheelGeometry.inner - 6) * 2
        return ZStack {
            Circle().fill(dark ? Color.white.opacity(0.08) : Color.white.opacity(0.4))
            VStack(spacing: 6) {
                Icon(model.hovered?.symbol ?? "square.grid.2x2", size: 22, weight: .medium)
                    .foregroundStyle(model.hovered?.tint ?? ink)
                    .contentTransition(.opacity)
                Text(model.caption)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 0.18, green: 0.42, blue: 0.95)))
                    .frame(maxWidth: side - 10)
                    .contentTransition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(dark ? 0.15 : 0.7), lineWidth: 1))
    }
}
