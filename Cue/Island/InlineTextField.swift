import AppKit
import SwiftUI

/// An in-place text field (card titles, new tasks): ↩ saves, ⎋ cancels, clicking away saves.
struct InlineTextField: View {
    var placeholder = "Name"
    var initial = ""
    var font = Font.system(size: 10.5, weight: .medium)
    /// The field's own box; off when the caller draws one around it.
    var boxed = true
    /// Select the initial text on focus, so typing replaces it.
    var selectAll = false
    let commit: (String) -> Void
    var cancel: () -> Void = {}
    @State private var text = ""
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            // The scheme's own ink, not white: the island forces dark, so this is white
            // there, but the floating task panel follows the system, and in light mode a
            // white project name was typed onto light glass, unreadable.
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.primary.opacity(boxed ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .focused($focused)
            .background(KeyWindowMaker())
            .onAppear {
                text = initial
                // The island is a non-activating panel that is not key until something
                // inside it asks; give the window a beat to become key, then focus.
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    focused = true
                    if selectAll {
                        try? await Task.sleep(for: .milliseconds(40))
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                }
            }
            .onSubmit { finish { commit(text) } }
            .onExitCommand { finish(cancel) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish { commit(text) } }
            }
    }

    private func finish(_ action: () -> Void) {
        guard !done else { return }
        done = true
        action()
    }

    /// The island is a non-activating panel: typing needs it to be the key window.
    private struct KeyWindowMaker: NSViewRepresentable {
        func makeNSView(context: Context) -> KeyView { KeyView() }
        func updateNSView(_ view: KeyView, context: Context) {}

        final class KeyView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window else { return }
                DispatchQueue.main.async {
                    window.makeKey()
                    // Hand the keyboard to the text field that shares this spot.
                    if let field = window.contentView.flatMap({ Self.textField(in: $0, near: self) }) {
                        window.makeFirstResponder(field)
                    }
                }
            }

            /// The SwiftUI text field drawn over this view (they share a frame).
            private static func textField(in root: NSView, near anchor: NSView) -> NSTextField? {
                let target = anchor.convert(anchor.bounds, to: nil)
                var best: NSTextField?
                var bestDistance = CGFloat.greatestFiniteMagnitude
                func walk(_ view: NSView) {
                    if let field = view as? NSTextField, field.isEditable {
                        let frame = field.convert(field.bounds, to: nil)
                        let distance = hypot(frame.midX - target.midX, frame.midY - target.midY)
                        if distance < bestDistance { bestDistance = distance; best = field }
                    }
                    view.subviews.forEach(walk)
                }
                walk(root)
                return bestDistance < 40 ? best : nil
            }
        }
    }
}

