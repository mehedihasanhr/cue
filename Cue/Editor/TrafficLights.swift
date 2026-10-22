import AppKit
import SwiftUI

/// Custom close / minimise / zoom buttons that live inside Cue's own toolbar row, so
/// they sit on the same centre line as the tools (the native ones are pinned to
/// AppKit's title-bar height). Same colors, sizes and hover glyphs as the system's.
struct TrafficLights: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void

    @Environment(\.controlActiveState) private var activeState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            light(Color(red: 1, green: 0.373, blue: 0.341), glyph: "xmark", action: onClose)
            light(Color(red: 0.996, green: 0.737, blue: 0.18), glyph: "minus", action: onMinimize)
            light(Color(red: 0.157, green: 0.784, blue: 0.251), glyph: "arrow.up.left.and.arrow.down.right", action: onZoom)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(activeState == .inactive && !hovering ? Color.primary.opacity(0.18) : color)
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                if hovering {
                    Image(systemName: glyph)
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.black.opacity(0.6))
                }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
    }
}

/// Transparent backdrop that lets the window be dragged by the toolbar row, since the
/// native title-bar drag region only covers the top 28 points.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
