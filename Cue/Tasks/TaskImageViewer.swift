import AppKit
import SwiftUI

/// An image from a task, over the whole window on a dark backdrop, to be looked at
/// properly: fitted at first, then zoomed with the buttons, ⌘+ / ⌘− or a pinch, and
/// moved about by dragging. A double-click goes between fitted and actual size. Copy,
/// open in Preview, show in Finder, full screen. ⎋ or a click on the backdrop closes it.
struct TaskImageViewer: View {
    let url: URL
    let close: () -> Void

    @State private var image: NSImage?
    /// How far past fitted the image is drawn (1: fitted).
    @State private var zoom: CGFloat = 1
    /// The zoom when a pinch began, so it scales from there.
    @State private var pinchStart: CGFloat?
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?

    private static let zoomRange: ClosedRange<CGFloat> = 0.25...12
    private static let margin: CGFloat = 56

    var body: some View {
        GeometryReader { proxy in
            let fit = fitScale(in: proxy.size)
            ZStack {
                Color.black.opacity(0.88)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: image.size.width * fit * zoom, height: image.size.height * fit * zoom)
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
                        .offset(offset)
                        .gesture(pan)
                        .simultaneousGesture(pinch)
                        .onTapGesture(count: 2) { toggleActualSize(fit: fit) }
                        .accessibilityLabel("Image, \(Int(image.size.width)) by \(Int(image.size.height))")
                } else {
                    Text("This image can't be opened.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .overlay(alignment: .top) { toolbar(fit: fit) }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background { keys }
        .onAppear { image = NSImage(contentsOf: url) }
        .transition(.opacity)
    }

    /// The scale that fits the image in the window with a margin — never past its own
    /// size, so a small image is not blown up until asked.
    private func fitScale(in size: CGSize) -> CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return 1 }
        let width = max(size.width - Self.margin * 2, 1), height = max(size.height - Self.margin * 2 - 30, 1)
        return min(width / image.size.width, height / image.size.height, 1)
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart ?? offset
                dragStart = start
                offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? zoom
                pinchStart = start
                zoom = (start * value.magnification).clamped(to: Self.zoomRange)
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.easeOut(duration: 0.18)) {
            zoom = value.clamped(to: Self.zoomRange)
            if zoom <= 1 { offset = .zero }
        }
    }

    /// Fitted ↔ actual size (or twice fitted, for an image that already fits whole).
    private func toggleActualSize(fit: CGFloat) {
        if abs(zoom - 1) > 0.01 {
            withAnimation(.easeOut(duration: 0.18)) { zoom = 1; offset = .zero }
        } else {
            setZoom(fit < 1 ? 1 / fit : 2)
        }
    }

    private func toolbar(fit: CGFloat) -> some View {
        HStack(spacing: 4) {
            if let image {
                Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 8)
            }
            Spacer()
            group {
                button("minus.magnifyingglass", help: "Zoom out (⌘−)") { setZoom(zoom / 1.25) }
                Button {
                    setZoom(1)
                } label: {
                    Text("\(Int((fit * zoom * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(minWidth: 46)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fit to the window (⌘0)")
                button("plus.magnifyingglass", help: "Zoom in (⌘+)") { setZoom(zoom * 1.25) }
            }
            group {
                button("doc.on.doc", help: "Copy the image") {
                    guard let image else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                    FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
                }
                button("arrow.up.forward.app", help: "Open in Preview") { NSWorkspace.shared.open(url) }
                button("folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                button("arrow.up.left.and.arrow.down.right", help: "Full screen (⌃⌘F)") { NSApp.keyWindow?.toggleFullScreen(nil) }
            }
            group {
                button("xmark", help: "Close (⎋)", action: close)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .foregroundStyle(.white.opacity(0.9))
    }

    private func group(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 2)
            .background(.white.opacity(0.1), in: Capsule())
            .environment(\.colorScheme, .dark)
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// ⎋ closes; ⌘+ / ⌘= and ⌘− zoom; ⌘0 fits; ⌃⌘F full screen.
    private var keys: some View {
        ZStack {
            Button("", action: close).keyboardShortcut(.escape, modifiers: [])
            Button("") { setZoom(zoom * 1.25) }.keyboardShortcut("=", modifiers: .command)
            Button("") { setZoom(zoom * 1.25) }.keyboardShortcut("+", modifiers: .command)
            Button("") { setZoom(zoom / 1.25) }.keyboardShortcut("-", modifiers: .command)
            Button("") { setZoom(1) }.keyboardShortcut("0", modifiers: .command)
            Button("") { NSApp.keyWindow?.toggleFullScreen(nil) }.keyboardShortcut("f", modifiers: [.control, .command])
        }
        .hidden()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
