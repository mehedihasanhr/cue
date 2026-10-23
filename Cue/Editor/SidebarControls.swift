import AppKit
import SwiftUI

/// The editor sidebar's own controls, drawn in Cue Studio's style: soft filled fields,
/// squircles, hairline edges and one accent. Studio's components aren't shared with this
/// target; these restate its look (sizes, colours, shapes) in small views of their own.
enum SidebarTheme {
    static let fieldHeight: CGFloat = 30
    static let fieldRadius: CGFloat = 8
    static let fieldInset: CGFloat = 8
    static let swatchRadius: CGFloat = 6
    static let inset: CGFloat = 14
    static let betweenControls: CGFloat = 6
    static let betweenGroups: CGFloat = 12
    static let betweenSections: CGFloat = 20

    /// The sidebar itself: white in the light appearance, a near-black grey in the dark.
    static let panel = dynamic(light: NSColor(white: 1, alpha: 1), dark: NSColor(white: 0x18 / 255, alpha: 1))
    /// A field on the panel: a row, a slider's trough, a button at rest.
    static let field = dynamic(light: cool(0xF3), dark: NSColor(white: 0x23 / 255, alpha: 1))
    static let fieldHover = dynamic(light: cool(0xEB), dark: NSColor(white: 0x2A / 255, alpha: 1))
    static let fieldPressed = dynamic(light: cool(0xE4), dark: NSColor(white: 0x30 / 255, alpha: 1))
    /// The chosen segment, lifted out of its trough.
    static let raised = dynamic(light: .white, dark: NSColor(white: 0x3A / 255, alpha: 1))
    /// A switch that is off.
    static let track = dynamic(light: .black.withAlphaComponent(0.10), dark: .white.withAlphaComponent(0.13))
    static let stroke = dynamic(light: .black.withAlphaComponent(0.09), dark: .white.withAlphaComponent(0.025))
    /// The edge of a swatch, which may be the exact colour of the panel behind it.
    static let strokeStrong = dynamic(light: .black.withAlphaComponent(0.16), dark: .white.withAlphaComponent(0.18))
    /// The set part of a scrub field, and the bar its value ends at.
    static let scrubFill = dynamic(light: brand.withAlphaComponent(0.13), dark: brand.withAlphaComponent(0.30))
    static let scrubMark = dynamic(light: brand, dark: NSColor(srgbRed: 0x5C / 255, green: 0x8D / 255, blue: 1, alpha: 1))
    /// The ring round a chosen swatch.
    static let ink = dynamic(light: NSColor(white: 0.1, alpha: 1), dark: NSColor(white: 0.95, alpha: 1))
    static let label = Color(nsColor: .secondaryLabelColor)
    static let value = Color(nsColor: .labelColor).opacity(0.85)
    static let focusRing = EditorChrome.accent.opacity(0.55)

    private static let brand = NSColor(srgbRed: 0x0E / 255, green: 0x4F / 255, blue: 0xEC / 255, alpha: 1)

    /// A light grey with a breath of blue, so the greys sit with Cue blue.
    private static func cool(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(value - 3) / 255, green: CGFloat(value - 1) / 255, blue: CGFloat(value + 2) / 255, alpha: 1)
    }

    /// Resolved by AppKit at draw time, so it is right inside a popover too.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                                        .accessibilityHighContrastVibrantDark]) != nil ? dark : light
        })
    }

    static func squircle(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

// MARK: - Headings

/// A section's heading, with room for a control at its trailing end.
struct SidebarHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            trailing
        }
        .frame(height: 22)
    }
}

/// A quieter heading inside a section, over a group of swatches.
struct SidebarSubheading<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(SidebarTheme.label)
            Spacer(minLength: 4)
            trailing
        }
    }
}

/// "Show all (N)" / "Show less" at the end of a subheading.
struct ShowAllButton: View {
    @Binding var isExpanded: Bool
    let count: Int
    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            Text(isExpanded ? "Show less" : "Show all (\(count))")
                .font(.system(size: 11))
                .foregroundStyle(isHovering ? Color.primary : SidebarTheme.label)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Scrub slider

/// A slider drawn as one filled row: the name on the left, the value on the right, the set
/// part a blue wash ending in a bright bar. The row is the slider, so a column of them
/// lines up with the switches and pop-ups around it.
///
/// Dragging moves the value by how far the pointer travels rather than jumping to where
/// it went down, so a click to focus never changes anything. Double-click resets; arrows
/// nudge (Shift for ten steps) when focused.
struct ScrubSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var step: CGFloat = 1
    var defaultValue: CGFloat?
    var format: (CGFloat) -> String = { "\(Int($0.rounded()))" }
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragStart: CGFloat?
    @State private var isHovering = false
    @State private var pushedCursor = false
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    private var span: CGFloat { range.upperBound - range.lowerBound }
    private var fraction: CGFloat { span > 0 ? (value.clamped(to: range) - range.lowerBound) / span : 0 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fillTo = width * fraction
            let shape = SidebarTheme.squircle(SidebarTheme.fieldRadius)
            let isLit = isHovering || dragStart != nil
            ZStack(alignment: .leading) {
                shape.fill(isLit ? SidebarTheme.fieldHover : SidebarTheme.field)
                Rectangle()
                    .fill(SidebarTheme.scrubFill)
                    .frame(width: max(0, fillTo))
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(SidebarTheme.scrubMark)
                    .frame(width: 2, height: 14)
                    .offset(x: min(max(0, fillTo - 2), width - 2))
                    .opacity(fraction > 0 ? 1 : 0)
                HStack(spacing: 8) {
                    Text(title.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(SidebarTheme.label)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(format(value))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(isLit ? Color.primary : SidebarTheme.value)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, SidebarTheme.fieldInset)
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(SidebarTheme.focusRing, lineWidth: 2).opacity(isFocused ? 1 : 0)
            }
            .contentShape(shape)
            .gesture(drag(width: width))
            .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
        }
        .frame(height: SidebarTheme.fieldHeight)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering in
            isHovering = hovering && isEnabled
            if isHovering, !pushedCursor { NSCursor.resizeLeftRight.push(); pushedCursor = true }
            if !isHovering, pushedCursor { NSCursor.pop(); pushedCursor = false }
        }
        .focusable(isEnabled, interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let direction: CGFloat = (press.key == .leftArrow || press.key == .downArrow) ? -1 : 1
            let amount = step * (press.modifiers.contains(.shift) ? 10 : 1)
            onEditingChanged(true)
            value = (value + direction * amount).clamped(to: range)
            onEditingChanged(false)
            return .handled
        }
        .help(defaultValue == nil ? title : "\(title) — double-click to reset")
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            onEditingChanged(true)
            value = (value + (direction == .increment ? step : -step)).clamped(to: range)
            onEditingChanged(false)
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { gesture in
                if dragStart == nil {
                    dragStart = value
                    onEditingChanged(true)
                }
                guard let start = dragStart, width > 0 else { return }
                let moved = gesture.translation.width / width * span
                value = snapped(start + moved).clamped(to: range)
            }
            .onEnded { _ in
                dragStart = nil
                onEditingChanged(false)
            }
    }

    private func snapped(_ raw: CGFloat) -> CGFloat {
        step > 0 ? (raw / step).rounded() * step : raw
    }

    private func reset() {
        guard let defaultValue, isEnabled else { return }
        onEditingChanged(true)
        value = defaultValue
        onEditingChanged(false)
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Switch

/// A field-height row with a name and a small capsule switch: grey when off, the accent
/// when on, a white knob that always looks like it sits on top.
struct SidebarSwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var help: String?

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(SidebarSwitchStyle())
            .help(help ?? title)
    }
}

struct SidebarSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 8) {
                configuration.label
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(SidebarTheme.label)
                Spacer(minLength: 4)
                Capsule()
                    .fill(configuration.isOn ? EditorChrome.accent : SidebarTheme.track)
                    .frame(width: 28, height: 16)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                            .padding(2)
                    }
            }
            .padding(.horizontal, SidebarTheme.fieldInset)
            .frame(height: SidebarTheme.fieldHeight)
            .background(SidebarTheme.field, in: SidebarTheme.squircle(SidebarTheme.fieldRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

// MARK: - Pop-up

/// A pop-up menu drawn two ways: bare words and a chevron on a heading (`.ghost`), or a
/// filled field the height of the rows around it (`.field`).
struct SidebarMenu<Value: Hashable>: View {
    enum Style { case ghost, field }

    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var systemImage: ((Value) -> String)?
    var style: Style = .field
    /// A name written inside a field-style menu, the way a scrub row names itself.
    var label: String?

    @State private var isHovering = false

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if let systemImage {
                        Label(title(option), systemImage: systemImage(option))
                    } else {
                        Text(title(option))
                    }
                }
                .disabled(option == selection)
            }
        } label: {
            HStack(spacing: 4) {
                if let label, style == .field {
                    Text(label.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(SidebarTheme.label)
                    Spacer(minLength: 4)
                }
                Text(title(selection))
                    .font(.system(size: style == .ghost ? 12 : 11.5, weight: style == .ghost ? .medium : .regular))
                    .foregroundStyle(style == .ghost ? SidebarTheme.label : SidebarTheme.value)
                    .lineLimit(1)
                if style == .field && label == nil { Spacer(minLength: 2) }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(SidebarTheme.label)
            }
            .padding(.horizontal, style == .ghost ? 6 : SidebarTheme.fieldInset)
            .frame(height: style == .ghost ? 22 : SidebarTheme.fieldHeight)
            .background {
                SidebarTheme.squircle(style == .ghost ? 6 : SidebarTheme.fieldRadius)
                    .fill(style == .ghost
                          ? (isHovering ? SidebarTheme.field : .clear)
                          : (isHovering ? SidebarTheme.fieldHover : SidebarTheme.field))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: style == .ghost, vertical: true)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Segmented

/// Close relatives side by side: a field-coloured trough with the chosen one lifted out
/// of it. The lift slides between choices.
struct SidebarSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.primary : SidebarTheme.label)
                        .frame(maxWidth: .infinity)
                        .frame(height: SidebarTheme.fieldHeight - 6)
                        .background {
                            if isSelected {
                                SidebarTheme.squircle(SidebarTheme.fieldRadius - 2)
                                    .fill(SidebarTheme.raised)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(SidebarTheme.field, in: SidebarTheme.squircle(SidebarTheme.fieldRadius))
    }
}

// MARK: - Buttons

/// A secondary button: a filled field with its title centred.
struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarButtonBody(configuration: configuration)
    }

    private struct SidebarButtonBody: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: SidebarTheme.fieldHeight - 2)
                .background {
                    SidebarTheme.squircle(SidebarTheme.fieldRadius)
                        .fill(configuration.isPressed ? SidebarTheme.fieldPressed
                              : isHovering ? SidebarTheme.fieldHover : SidebarTheme.field)
                }
                .overlay { SidebarTheme.squircle(SidebarTheme.fieldRadius).strokeBorder(SidebarTheme.stroke) }
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
    }
}

// MARK: - Swatches

/// One square choice in a grid: a colour, a gradient, a picture. The chosen one gets an
/// ink ring a little outside its edge; the rest sit slightly back so it stands out.
struct SidebarSwatch<Content: View>: View {
    let isSelected: Bool
    let title: String
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            let shape = SidebarTheme.squircle(SidebarTheme.swatchRadius)
            content
                .aspectRatio(1, contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(shape)
                .overlay { shape.strokeBorder(SidebarTheme.strokeStrong, lineWidth: 0.5) }
                .opacity(isSelected || isHovering ? 1 : 0.88)
                .padding(2.5)
                .overlay {
                    SidebarTheme.squircle(SidebarTheme.swatchRadius + 2.5)
                        .strokeBorder(SidebarTheme.ink.opacity(isSelected ? 0.85 : isHovering ? 0.22 : 0),
                                      lineWidth: isSelected ? 1.5 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The swatch that adds one more: a dashed outline round a plus.
struct SidebarAddSwatch: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            SidebarTheme.squircle(SidebarTheme.swatchRadius)
                .strokeBorder(style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(isHovering ? Color.primary.opacity(0.6) : SidebarTheme.label.opacity(0.7))
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHovering ? Color.primary : SidebarTheme.label)
                }
                .aspectRatio(1, contentMode: .fit)
                .padding(2.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A see-through background's picture: grey and white squares.
struct SidebarCheckerboard: View {
    var square: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let columns = Int(ceil(size.width / square)), rows = Int(ceil(size.height / square))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square)
                    context.fill(Path(rect), with: .color(Color(white: 0.85)))
                }
            }
        }
    }
}
