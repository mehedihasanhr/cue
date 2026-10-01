import AppKit
import BackgroundKit
import SwiftUI
import TimelineKit

/// A gradient of one's own: two or three colours, straight across at an angle or out
/// from the middle.
///
/// Opens on whatever the background already is — a stock gradient's own two colours, or
/// the default ones — so looking at it changes nothing; the first colour, angle or shape
/// changed is what makes the gradient the project's own.
struct GradientEditor: View {
    let model: EditorModel

    @State private var coalescer = InteractionCoalescer()

    private var gradient: BackgroundGradient { model.editableGradient }

    var body: some View {
        // No swatch of its own and no sentence: the project's own gradient is the last
        // swatch in the row above, and its tooltip says what these controls do to it.
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorRow("Shape") {
                InspectorPicker(selection: shape, options: BackgroundGradient.Shape.allCases) { $0.title }
            }
            // The colours in one row, start to end, as they run across the gradient — with
            // a step at the end to add a middle one or take it away. Two pop-ups and a row
            // per colour said the same thing in three times the height.
            InspectorRow("Colours") {
                HStack(spacing: 6) {
                    ForEach(Array(gradient.stops.indices), id: \.self) { index in
                        InspectorColorWell(title: title(ofStop: index) + " colour", selection: colour(of: index))
                            .help("The gradient's \(title(ofStop: index).lowercased()) colour")
                    }
                    stopStep
                }
            }
            if gradient.shape == .linear {
                InspectorSlider(model: model, "Angle", systemImage: "angle",
                                value: angle, range: 0...360,
                                format: { "\(Int($0.rounded()))°" })
            }
            if gradient.stops.count == 3 {
                InspectorSlider(model: model, "Middle", systemImage: "arrow.left.and.right",
                                value: middle, range: 0.05...0.95)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your own gradient")
    }

    /// Add a middle colour, or take it away: the gradient's two stop counts as one button.
    private var stopStep: some View {
        let range = BackgroundGradient.stopCount
        let count = gradient.stops.count
        let adds = count < range.upperBound
        return Button {
            model.setBackgroundGradient(gradient.withStopCount(adds ? count + 1 : max(range.lowerBound, count - 1)))
        } label: {
            Image(systemName: adds ? "plus" : "minus")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .foregroundStyle(.secondary)
        .help(adds ? "Add a middle colour" : "Take the middle colour away")
        .accessibilityLabel(adds ? "Add a middle colour" : "Remove the middle colour")
    }

    private func title(ofStop index: Int) -> String {
        if index == 0 { return "Start" }
        if index == gradient.stops.count - 1 { return "End" }
        return "Middle"
    }

    private func change(_ edit: (inout BackgroundGradient) -> Void) {
        var changed = gradient
        edit(&changed)
        model.setBackgroundGradient(changed)
    }

    private var shape: Binding<BackgroundGradient.Shape> {
        Binding { gradient.shape } set: { shape in change { $0.shape = shape } }
    }

    /// The one control with no "editing ended" of its own — see `InteractionCoalescer`.
    private func colour(of index: Int) -> Binding<Color> {
        Binding {
            gradient.stops.indices.contains(index) ? gradient.stops[index].color.color : .black
        } set: { picked in
            let value = RGBA(NSColor(picked)).colorValue
            coalescer.touch("Gradient", model: model)
            change { gradient in
                guard gradient.stops.indices.contains(index) else { return }
                gradient.stops[index].color = value
            }
        }
    }

    /// In degrees, which is how people think of an angle; stored in turns, which is how
    /// the stock gradients store theirs.
    private var angle: Binding<Double> {
        Binding {
            // Held to one turn and never negative, whatever a file says: -0.25 is 270°.
            let turn = gradient.angle.truncatingRemainder(dividingBy: 1)
            return (turn < 0 ? turn + 1 : turn) * 360
        } set: { degrees in
            change { $0.angle = degrees / 360 }
        }
    }

    private var middle: Binding<Double> {
        Binding { gradient.stops.count == 3 ? gradient.stops[1].location : 0.5 } set: { location in
            change { gradient in
                guard gradient.stops.count == 3 else { return }
                gradient.stops[1].location = location
            }
        }
    }
}

/// A gradient of one's own, drawn by SwiftUI for a swatch — the same colours and the
/// same direction the renderer uses, at a size where the two cannot be told apart.
struct GradientSwatch: View {
    let gradient: BackgroundGradient

    var body: some View {
        let stops = gradient.stops.map { Gradient.Stop(color: $0.color.color, location: $0.location) }
        switch gradient.shape {
        case .linear:
            // Turns, counter-clockwise from left-to-right with y up, as the renderer
            // draws them; SwiftUI's y runs down, hence the flipped sine.
            let radians = gradient.angle * 2 * .pi
            let dx = cos(radians) / 2, dy = sin(radians) / 2
            LinearGradient(stops: stops,
                           startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 + dy),
                           endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 - dy))
        case .radial:
            GeometryReader { proxy in
                RadialGradient(stops: stops, center: .center, startRadius: 0,
                               endRadius: hypot(proxy.size.width, proxy.size.height) / 2)
            }
        }
    }
}

/// The grey squares every image editor draws where there is nothing, so "see-through" is
/// something to look at rather than a colour to guess at.
///
/// Drawn *behind* the rendered frame by the view that shows it, never into the frame
/// itself: the renderer's answer for a transparent background is nothing, and that is
/// what the export writes.
struct Checkerboard: View {
    var square: CGFloat = 8
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let light = colorScheme == .dark ? Color(white: 0.3) : Color(white: 1)
            let dark = colorScheme == .dark ? Color(white: 0.22) : Color(white: 0.84)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            let columns = Int((size.width / square).rounded(.up))
            let rows = Int((size.height / square).rounded(.up))
            var path = Path()
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square,
                                        width: square, height: square))
                }
            }
            context.fill(path, with: .color(dark))
        }
        .accessibilityHidden(true)
    }
}
