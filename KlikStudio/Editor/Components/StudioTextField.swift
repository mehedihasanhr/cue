import SwiftUI

/// A text field in the kit's chrome: a squircle in the neutral fill, a hairline edge, and an
/// accent ring while it has the keyboard.
///
/// The typing itself is the system's — a plain `TextField`, so input methods, spelling,
/// undo inside the field and VoiceOver all behave as they do everywhere — and only the box
/// around it is ours. The system's bordered field is a sunken white rectangle with a square
/// corner, which in a column of squircles is the one thing drawn in a different hand.
struct StudioTextField: View {
    let placeholder: String
    @Binding var text: String
    var isInvalid = false
    var monospaced = false
    var size: StudioTheme.ControlSize = .small
    var onCommit: () -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ placeholder: String,
         text: Binding<String>,
         isInvalid: Bool = false,
         monospaced: Bool = false,
         size: StudioTheme.ControlSize = .small,
         onCommit: @escaping () -> Void = {}) {
        self.placeholder = placeholder
        _text = text
        self.isInvalid = isInvalid
        self.monospaced = monospaced
        self.size = size
        self.onCommit = onCommit
    }

    var body: some View {
        let shape = StudioTheme.squircle(size.radius)
        let font = Font.system(size: size.fontSize, design: monospaced ? .monospaced : .default)

        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(StudioTheme.Palette.textPrimary)
            .focused($isFocused)
            .focusEffectDisabled()
            .onSubmit(onCommit)
            .padding(.horizontal, 8)
            .frame(height: size.height)
            .background { shape.fill(isHovering && !isFocused ? StudioTheme.Palette.fillHover : StudioTheme.Palette.fill) }
            .overlay {
                shape.strokeBorder(isInvalid ? StudioTheme.Palette.destructive : StudioTheme.Palette.stroke)
            }
            .studioFocusRing(isFocused && isEnabled, radius: size.radius)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = $0 && isEnabled }
            .animation(StudioMotion.hover, value: isHovering)
            // A field you leave without pressing Return has still been typed in; leaving
            // it is as good as committing, the way the system's fields behave.
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit() }
            }
    }
}
