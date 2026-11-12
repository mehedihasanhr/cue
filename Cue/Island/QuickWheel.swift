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

    /// What this action adds to, and so what the middle offers to open while the
    /// segment is under the pointer: the captures, the colors, the notes, the tasks.
    var collection: QuickCollection? {
        switch self {
        case .captureArea, .captureWindow, .captureFullScreen, .captureText: .captures
        case .pickColor: .colors
        case .quickNote: .notes
        case .quickTask: .tasks
        case .record: .recordings
        }
    }
}

/// Where a quick action's work ends up. Hovering a segment puts this in the middle
/// of the ring, and clicking the middle opens it.
enum QuickCollection: String, Sendable {
    case captures, colors, notes, tasks, recordings

    /// The words in the middle, under the icon.
    var title: String {
        switch self {
        case .captures: "All captures"
        case .colors: "All colors"
        case .notes: "All notes"
        case .tasks: "All tasks"
        case .recordings: "Recordings"
        }
    }

    var symbol: String {
        switch self {
        case .captures: "photo.on.rectangle"
        case .colors: "paintpalette"
        case .notes: "note.text"
        case .tasks: "checklist"
        case .recordings: "film.stack"
        }
    }
}

@MainActor @Observable
final class QuickWheelModel {
    var shown = false
    /// The segment under the pointer.
    var hovered: QuickAction?
    /// The pointer is in the middle of the ring. The segment it came from stays
    /// `hovered`, so the middle keeps offering that segment's collection: the way
    /// over to the middle to click it must not be the way to lose it.
    var inHub = false
    var actions: [QuickAction] = QuickAction.allCases

    /// What the middle opens on a click, if anything.
    var collection: QuickCollection? { hovered?.collection }

    /// The middle: what hovering offers to open, else the name of the segment under
    /// the pointer, else what the ring is.
    var caption: String { collection?.title ?? hovered?.title ?? "Quick actions" }

    /// The icon in the middle follows the same order.
    var symbol: String { collection?.symbol ?? hovered?.symbol ?? "square.grid.2x2" }
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

    /// The middle: what the hovered segment adds to — the captures, the tasks, the
    /// notes — which a click here opens. With nothing hovered it is the ring's own
    /// name, and a click just closes.
    private var centre: some View {
        let side = (WheelGeometry.inner - 6) * 2
        let openable = model.collection != nil
        return ZStack {
            Circle().fill(dark ? Color.white.opacity(model.inHub && openable ? 0.18 : 0.08)
                               : Color.white.opacity(model.inHub && openable ? 0.62 : 0.4))
            VStack(spacing: 6) {
                Icon(model.symbol, size: 22, weight: .medium)
                    .foregroundStyle(model.collection == nil ? (model.hovered?.tint ?? ink) : ink)
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
        .overlay(Circle().strokeBorder(.white.opacity(model.inHub && openable ? 0.9 : (dark ? 0.15 : 0.7)),
                                       lineWidth: model.inHub && openable ? 1.5 : 1))
        .scaleEffect(model.inHub && openable ? 1.04 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: model.inHub)
    }
}
