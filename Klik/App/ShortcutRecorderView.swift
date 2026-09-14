import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A click-to-record shortcut field, in the style of System Settings › Keyboard.
struct ShortcutRecorderView: NSViewRepresentable {
    var hotkey: Hotkey?
    var onChange: (Hotkey?) -> Void
    var onRecordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let control = ShortcutRecorderControl()
        control.hotkey = hotkey
        control.onChange = onChange
        control.onRecordingChanged = onRecordingChanged
        return control
    }

    func updateNSView(_ control: ShortcutRecorderControl, context: Context) {
        control.hotkey = hotkey
        control.onChange = onChange
        control.onRecordingChanged = onRecordingChanged
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutRecorderControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

final class ShortcutRecorderControl: NSView {
    var hotkey: Hotkey? {
        didSet { if hotkey != oldValue { needsDisplay = true } }
    }
    var onChange: ((Hotkey?) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            pendingModifiers = 0
            onRecordingChanged?(isRecording)
            needsDisplay = true
        }
    }
    private var pendingModifiers: UInt32 = 0

    private static let clearButtonWidth: CGFloat = 26

    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 28) }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !isRecording, hotkey != nil, point.x > bounds.maxX - Self.clearButtonWidth {
            commit(nil)
            return
        }
        if isRecording {
            stop()
        } else {
            window?.makeFirstResponder(self)
            isRecording = true
        }
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return true
    }

    // MARK: - Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Take ⌘-combinations before the main menu sees them while recording.
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        handle(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { super.flagsChanged(with: event); return }
        pendingModifiers = Hotkey.carbonModifiers(from: event.modifierFlags)
        needsDisplay = true
    }

    private func handle(_ event: NSEvent) {
        let plainModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
        switch Int(event.keyCode) {
        case kVK_Escape where plainModifiers:
            stop()
        case kVK_Delete where plainModifiers, kVK_ForwardDelete where plainModifiers:
            commit(nil)
        default:
            let candidate = Hotkey(event: event)
            guard candidate.isUsableAsGlobalShortcut else {
                NSSound.beep()
                return
            }
            commit(candidate)
        }
    }

    private func commit(_ newValue: Hotkey?) {
        hotkey = newValue
        onChange?(newValue)
        stop()
    }

    private func stop() {
        isRecording = false
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    // MARK: - Drawing

    private static let capFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let capHeight: CGFloat = 20
    private static let capMinWidth: CGFloat = 22
    private static let capSpacing: CGFloat = 4

    override func draw(_ dirtyRect: NSRect) {
        let field = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
        }
        field.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.12)).setStroke()
        field.lineWidth = isRecording ? 1.5 : 1
        field.stroke()

        if isRecording {
            let modifiers = Hotkey.modifierSymbols(pendingModifiers)
            if modifiers.isEmpty {
                drawCentered("Type shortcut…", color: .secondaryLabelColor)
            } else {
                drawCaps(modifiers.map(String.init) + ["…"], trailingInset: 0)
            }
        } else if let hotkey {
            let caps = Hotkey.modifierSymbols(hotkey.modifiers).map(String.init) + [KeyCodeNames.name(for: hotkey.keyCode)]
            drawCaps(caps, trailingInset: Self.clearButtonWidth)
            drawClearButton()
        } else {
            drawCentered("Record Shortcut", color: .secondaryLabelColor)
        }
    }

    private func drawCentered(_ text: String, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    /// Each key as its own little keycap, like System Settings › Keyboard.
    private func drawCaps(_ caps: [String], trailingInset: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.capFont, .foregroundColor: NSColor.labelColor]
        let sizes = caps.map { $0.size(withAttributes: attributes) }
        let widths = sizes.map { max(Self.capMinWidth, ceil($0.width) + 10) }
        let total = widths.reduce(0, +) + Self.capSpacing * CGFloat(max(0, caps.count - 1))
        var x = ((bounds.width - trailingInset) - total) / 2
        let y = (bounds.height - Self.capHeight) / 2
        for (index, cap) in caps.enumerated() {
            let rect = CGRect(x: x, y: y, width: widths[index], height: Self.capHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.14).setStroke()
            path.lineWidth = 1
            path.stroke()
            let size = sizes[index]
            cap.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            x += widths[index] + Self.capSpacing
        }
    }

    private func drawClearButton() {
        guard let clear = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear") else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [.secondaryLabelColor, NSColor.labelColor.withAlphaComponent(0.12)]))
        let image = clear.withSymbolConfiguration(config) ?? clear
        let side: CGFloat = 14
        let rect = NSRect(x: bounds.maxX - Self.clearButtonWidth + (Self.clearButtonWidth - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
