import SwiftUI

/// What the island shows: nothing (a black shape hiding on the notch), the capture
/// that was just taken, or the captures strip.
@Observable
final class IslandModel {
    enum Phase: Equatable {
        case collapsed
        case flash(CaptureItem)
        case expanded

        var geometryPhase: IslandGeometry.Phase {
            switch self {
            case .collapsed: .collapsed
            case .flash: .flash
            case .expanded: .expanded
            }
        }
    }

    var phase: Phase = .collapsed
    var geometry: IslandGeometry?
    /// A click on the closed shape opens it.
    var onTap: () -> Void = {}
}

/// The island silhouette: top corners flare outward into the bezel (a small flare
/// closed, a wide one open), bottom corners are rounded. All radii animate, so the
/// closed notch morphs into the open panel.
nonisolated struct NotchShape: Shape {
    /// Outward curve at the top corners (the notch meeting the bezel).
    var flare: CGFloat
    /// Inward rounding of the top corners (the open panel).
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(flare, AnimatablePair(topRadius, bottomRadius)) }
        set { flare = newValue.first; topRadius = newValue.second.first; bottomRadius = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let flare = min(self.flare, rect.width / 4)
        let top = min(topRadius, rect.width / 2, rect.height / 2)
        let bottom = min(bottomRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - flare, y: rect.minY))
        if flare > 0 {
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + flare), control: CGPoint(x: rect.minX, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: rect.minX + top, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + top), control: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + bottom, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX, y: rect.maxY))
        if flare > 0 {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + flare))
            path.addQuadCurve(to: CGPoint(x: rect.maxX + flare, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

struct IslandView: View {
    let model: IslandModel
    let library: CaptureLibrary
    let actions: HistoryActions

    /// Opening overshoots a touch; closing settles without a bounce.
    static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    static let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    static let contentAnimation = Animation.smooth(duration: 0.35)

    var body: some View {
        let phase = model.phase
        if let geometry = model.geometry {
            let size = geometry.rect(for: phase.geometryPhase).size
            let collapsed = phase == .collapsed
            let shape = NotchShape(
                flare: collapsed ? 6 : IslandGeometry.openFlare,
                topRadius: 0,
                bottomRadius: geometry.radius(for: phase.geometryPhase)
            )
            ZStack(alignment: .top) {
                shape.fill(.black)
                content(for: phase, strip: geometry.stripHeight)
                    .compositingGroup()
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .contentShape(shape)
            .onTapGesture { if collapsed { model.onTap() } }
            .animation(collapsed ? Self.closeAnimation : Self.openAnimation, value: phase)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder
    private func content(for phase: IslandModel.Phase, strip: CGFloat) -> some View {
        switch phase {
        case .collapsed:
            EmptyView()
        case .flash(let item):
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                FlashRow(item: item, library: library)
                    .frame(height: IslandGeometry.flashContentHeight)
            }
            .transition(Self.contentTransition)
        case .expanded:
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                IslandPanel(library: library, actions: actions)
                    .padding(.horizontal, IslandGeometry.panelHorizontalPadding)
                    .padding(.bottom, IslandGeometry.panelBottomPadding)
            }
            .transition(Self.contentTransition)
        }
    }

    private static let contentTransition: AnyTransition = .scale(scale: 0.8, anchor: .top)
        .combined(with: .opacity)
        .animation(contentAnimation)
}

/// "Just captured": the thumbnail and a copied confirmation.
private struct FlashRow: View {
    let item: CaptureItem
    let library: CaptureLibrary

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail = library.thumbnail(for: item) {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 66, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.15)))

            VStack(alignment: .leading, spacing: 2) {
                Text("Copied to clipboard")
                    .font(.system(size: 13, weight: .semibold))
                Text(item.dimensions)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.green)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
    }
}
