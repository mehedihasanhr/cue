import AppKit
import SwiftUI

/// Words that can run to more than one line, typed the way a text box is typed into.
///
/// AppKit's text view rather than SwiftUI's vertical `TextField`, because the field treats
/// Return as "done": a label could only get a second line by Option-Return, which nobody
/// finds, and pressing Return to start one closed the label instead. Here Return is a new
/// line, and the ways out are the ones a text box has — ⌘Return, Escape, or clicking
/// somewhere else.
///
/// It reports the height its words need for the width it is offered, so in the inspector
/// it grows a line at a time; on the canvas it is given the label's own box.
struct StudioTextArea: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var colour: NSColor = .labelColor
    var alignment: NSTextAlignment = .natural
    var placeholder: String = ""
    /// Takes the keyboard as soon as it appears.
    var takesFocus = false
    /// Selects everything when it takes the keyboard, so typing replaces a placeholder word.
    var selectsAll = false
    /// Grows no taller than this many lines, scrolling after that. Nil: as tall as it needs.
    var maxLines: Int?
    /// Typing has finished: ⌘Return, Escape, or the keyboard went somewhere else.
    var onEnd: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = TextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false          // the document's undo covers typing
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.focusRingType = .none

        textView.minSize = .zero
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)

        let scroll = Scroll()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = textView
        apply(to: textView)
        textView.string = text

        if takesFocus {
            DispatchQueue.main.async {
                guard let window = textView.window else { return }
                window.makeFirstResponder(textView)
                if selectsAll { textView.selectAll(nil) } else {
                    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? TextView else { return }
        apply(to: textView)
        // Only when it really differs: setting the string moves the caret to the end, and
        // the binding comes back round with exactly what was just typed.
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scroll.documentView as? NSTextView,
              let container = textView.textContainer, let layout = textView.layoutManager else { return nil }
        let width = proposal.width ?? 200
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: font)
        var height = max(line, ceil(layout.usedRect(for: container).height))
        if let maxLines { height = min(height, line * CGFloat(maxLines)) }
        return CGSize(width: width, height: height)
    }

    private func apply(to textView: TextView) {
        textView.font = font
        textView.textColor = colour
        textView.alignment = alignment
        textView.insertionPointColor = colour
        textView.typingAttributes = [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph]
        textView.placeholder = placeholder
        textView.enclosingScrollView?.hasVerticalScroller = false
    }

    private var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        return style
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: StudioTextArea
        /// Set once the way out has been taken, so leaving by ⌘Return does not report again
        /// when the keyboard then moves on.
        fileprivate var hasEnded = false

        init(_ parent: StudioTextArea) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                end(textView)
                return true
            }
            return false
        }

        fileprivate func end(_ textView: NSTextView) {
            guard !hasEnded else { return }
            hasEnded = true
            if textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
            parent.onEnd()
        }

        fileprivate func resigned() {
            guard !hasEnded else { return }
            hasEnded = true
            // After the click that took the keyboard has been handled, so ending does not
            // tear the view down in the middle of the event that is selecting something else.
            DispatchQueue.main.async { self.parent.onEnd() }
        }

        fileprivate func focused() { hasEnded = false }
    }

    /// Keeps the text view exactly as wide as the room it is given, and at least as tall.
    final class Scroll: NSScrollView {
        override func tile() {
            super.tile()
            guard let document = documentView else { return }
            let size = contentSize
            if document.frame.width != size.width { document.frame.size.width = size.width }
            if document.frame.height < size.height { document.frame.size.height = size.height }
        }
    }

    /// The text view, with ⌘Return as "done" and a placeholder drawn while it is empty.
    final class TextView: NSTextView {
        weak var coordinator: Coordinator?
        var placeholder = "" {
            didSet { if placeholder != oldValue { needsDisplay = true } }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.contains(.command) {
                coordinator?.end(self)
                return
            }
            super.keyDown(with: event)
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { coordinator?.focused() }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { coordinator?.resigned() }
            return resigned
        }

        override func didChangeText() {
            super.didChangeText()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty, let font else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            (placeholder as NSString).draw(in: bounds, withAttributes: [
                .font: font,
                .foregroundColor: (textColor ?? .labelColor).withAlphaComponent(0.4),
                .paragraphStyle: paragraph,
            ])
        }
    }
}
