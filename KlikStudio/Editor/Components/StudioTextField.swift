import SwiftUI

/// A text field in the kit's chrome: a squircle in the neutral fill, a hairline edge, and an
/// accent ring while it has the keyboard.
///
/// The typing itself is the system's — a plain `TextField`, so input methods, spelling,
/// undo inside the field and VoiceOver all behave as they do everywhere — and only the box
/// around it is ours. The system's bordered field is a sunken white rectangle with a square
/// corner, which in a column of squircles is the one thing drawn in a different hand.
///
/// `axis: .vertical` makes it a field that grows a line at a time — a caption, an
/// annotation's words — up to whatever `.lineLimit` the caller sets around it.
struct StudioTextField: View {
    let placeholder: String
    @Binding var text: String
    var isInvalid = false
    var monospaced = false
    var size: StudioTheme.ControlSize = .small
    var axis: Axis = .horizontal
    var onCommit: () -> Void = {}

    @FocusState private var isFocused: Bool

    init(_ placeholder: String,
         text: Binding<String>,
         isInvalid: Bool = false,
         monospaced: Bool = false,
         size: StudioTheme.ControlSize = .small,
         axis: Axis = .horizontal,
         onCommit: @escaping () -> Void = {}) {
        self.placeholder = placeholder
        _text = text
        self.isInvalid = isInvalid
        self.monospaced = monospaced
        self.size = size
        self.axis = axis
        self.onCommit = onCommit
    }

    var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .font(.system(size: size.fontSize, design: monospaced ? .monospaced : .default))
            .focused($isFocused)
            .onSubmit(onCommit)
            .studioField(isFocused: isFocused, isInvalid: isInvalid, size: size, isMultiline: axis == .vertical)
            // A field you leave without pressing Return has still been typed in; leaving
            // it is as good as committing, the way the system's fields behave.
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit() }
            }
    }
}

/// The kit's field chrome, for a `TextField` that keeps its own focus.
///
/// `StudioTextField` covers the field that only needs a binding and a commit. The rest —
/// a time that reformats itself once it is left, a pair of fields that commit together
/// when both have been left, a title whose typing is one undo step — hold a `FocusState`
/// of their own, and putting the box round them here rather than rebuilding each one as a
/// `StudioTextField` keeps that logic where it was.
///
/// A *quiet* field draws nothing at rest and only a soft wash under the pointer: a name
/// that reads as a label until it is clicked, a line in a transcript that reads as text.
/// It takes the full box while it is being typed in, so it is plain which line is live.
struct StudioFieldChrome: ViewModifier {
    let isFocused: Bool
    var isInvalid = false
    var size: StudioTheme.ControlSize = .small
    var isMultiline = false
    var isQuiet = false

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    private typealias Palette = StudioTheme.Palette

    func body(content: Content) -> some View {
        let shape = StudioTheme.squircle(size.radius)
        let showsBox = !isQuiet || isFocused || isInvalid

        content
            .textFieldStyle(.plain)
            .foregroundStyle(Palette.textPrimary)
            .focusEffectDisabled()
            .padding(.horizontal, isQuiet ? 6 : 8)
            .padding(.vertical, isMultiline ? 5 : 0)
            .frame(minHeight: size.height)
            .background { shape.fill(fill(showsBox: showsBox)) }
            .overlay {
                shape.strokeBorder(isInvalid ? Palette.destructive : Palette.stroke)
                    .opacity(showsBox ? 1 : 0)
            }
            .studioFocusRing(isFocused && isEnabled, radius: size.radius)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = $0 && isEnabled }
            .animation(StudioMotion.hover, value: isHovering)
            .animation(StudioMotion.hover, value: showsBox)
    }

    private func fill(showsBox: Bool) -> Color {
        if !showsBox { return isHovering ? Palette.ghostHover : .clear }
        return isHovering && !isFocused ? Palette.fillHover : Palette.fill
    }
}

extension View {
    /// Draws a plain `TextField` as one of the kit's: `.studioField(isFocused: isFocused)`.
    func studioField(isFocused: Bool,
                     isInvalid: Bool = false,
                     size: StudioTheme.ControlSize = .small,
                     isMultiline: Bool = false,
                     isQuiet: Bool = false) -> some View {
        modifier(StudioFieldChrome(isFocused: isFocused, isInvalid: isInvalid, size: size,
                                   isMultiline: isMultiline, isQuiet: isQuiet))
    }
}
