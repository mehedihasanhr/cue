import AppKit
import SwiftUI

/// The player detached from the island: a small window that floats over everything,
/// a pill with the track and play/pause, or opened out to a card with the artwork
/// large, the timeline and the controls. Dragged anywhere, and found there again.
@MainActor
final class MiniPlayerController {
    private let nowPlaying: NowPlaying
    private var panel: NSPanel?
    private let model = MiniPlayerModel()

    private static let originKey = "island.miniPlayer.origin"

    init(nowPlaying: NowPlaying) {
        self.nowPlaying = nowPlaying
    }

    var isShown: Bool { panel?.isVisible == true }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        resize(animated: false)
        panel.orderFrontRegardless()
    }

    func close() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
        panel.orderOut(nil)
    }

    /// Between the pill and the card, keeping the top edge where it is.
    func toggleSize() {
        model.expanded.toggle()
        resize(animated: true)
    }

    private func resize(animated: Bool) {
        guard let panel else { return }
        let size = model.expanded ? MiniPlayerView.expandedSize : MiniPlayerView.compactSize
        var frame = panel.frame
        if !panel.isVisible, let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            frame.origin = NSPointFromString(saved)
            frame.size = size
        } else if !panel.isVisible {
            // First time: the top right of the screen, under the menu bar.
            let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            frame = CGRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24, width: size.width, height: size.height)
        } else {
            frame.origin.y += frame.height - size.height
            frame.size = size
        }
        // Kept on a screen.
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        if animated, !IslandView.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: MiniPlayerView.compactSize), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = FirstMouseHostingView(rootView: MiniPlayerView(nowPlaying: nowPlaying, model: model,
                                                                  toggle: { [weak self] in self?.toggleSize() },
                                                                  close: { [weak self] in self?.close() }))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

@MainActor @Observable
final class MiniPlayerModel {
    var expanded = false
}

/// The mini player's content: the pill, or the card.
struct MiniPlayerView: View {
    static let compactSize = CGSize(width: 300, height: 64)
    static let expandedSize = CGSize(width: 280, height: 340)

    let nowPlaying: NowPlaying
    let model: MiniPlayerModel
    let toggle: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    // Light and dark kept apart: Droppy's light grey and near-black ink in light mode.
    private var dark: Bool { scheme == .dark }
    private var ink: Color { dark ? .white : Color(light: 0x222222, dark: 0x222222) }
    private var quiet: Color { dark ? .white.opacity(0.55) : Color(light: 0x6E6E6E, dark: 0x6E6E6E) }
    private var faint: Color { dark ? .white.opacity(0.45) : Color(light: 0x8A8A8A, dark: 0x8A8A8A) }
    /// Behind artwork that hasn't come yet.
    private var well: Color { dark ? .white.opacity(0.08) : .black.opacity(0.06) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: model.expanded ? 28 : 22, style: .continuous)
        ZStack {
            if model.expanded { card.transition(.opacity) } else { pill.transition(.opacity) }
        }
        .padding(model.expanded ? 16 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                if #available(macOS 26, *) {
                    shape.fill(.clear).glassEffect(.regular.tint(dark ? .black.opacity(0.5) : .white.opacity(0.4)), in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
                shape.fill(dark ? Color.black.opacity(0.5) : Color(light: 0xF6F4F3, dark: 0xF6F4F3).opacity(0.9))
                // The artwork's colours, blurred, behind the card.
                if model.expanded, let artwork = nowPlaying.artwork {
                    Image(nsImage: artwork).resizable().scaledToFill().blur(radius: 40).opacity(dark ? 0.35 : 0.22).clipShape(shape)
                }
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(dark ? 0.1 : 0.8), lineWidth: 1))
        .clipShape(shape)
        .foregroundStyle(ink)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.25), value: model.expanded)
    }

    // MARK: The pill

    private var pill: some View {
        HStack(spacing: 10) {
            artwork(side: 44, radius: 11)
                .onTapGesture(perform: toggle)
            VStack(alignment: .leading, spacing: 1) {
                Text(nowPlaying.track?.title ?? "Nothing playing")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(nowPlaying.track?.artist ?? nowPlaying.player?.name ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(quiet)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                button("backward.fill", 11, nowPlaying.previous)
            }
            button(nowPlaying.isPlaying ? "pause.fill" : "play.fill", 15, nowPlaying.playPause)
            if hovering {
                button("forward.fill", 11, nowPlaying.next)
            } else if let track = nowPlaying.track {
                critter(CueCritter(side: 22, mood: .playing(nowPlaying.isPlaying, trackID: track.id)))
            }
        }
        .overlay(alignment: .topTrailing) { if hovering { closeButton.offset(x: 6, y: -6) } }
    }

    // MARK: The card

    private var card: some View {
        VStack(spacing: 12) {
            // The artwork across the card, cropped to fill it.
            ZStack {
                well
                if let image = nowPlaying.artwork {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if let track = nowPlaying.track {
                    critter(CueCritter(side: 80, mood: .playing(nowPlaying.isPlaying, trackID: track.id)))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .help("Make it small")
            VStack(spacing: 2) {
                Text(nowPlaying.track?.title ?? "Nothing playing")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(nowPlaying.track?.artist ?? "")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(quiet)
                    .lineLimit(1)
            }
            if let track = nowPlaying.track, track.duration > 0 {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let position = nowPlaying.position(at: context.date)
                    VStack(spacing: 3) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(dark ? Color.white.opacity(0.15) : Color.black.opacity(0.1))
                                Capsule().fill(dark ? Color.white.opacity(0.85) : ink.opacity(0.8)).frame(width: max(4, proxy.size.width * position / track.duration))
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { location in nowPlaying.seek(to: min(max(location.x / proxy.size.width, 0), 1) * track.duration) }
                        }
                        .frame(height: 4)
                        HStack {
                            Text(Self.time(position))
                            Spacer()
                            Text("-" + Self.time(max(0, track.duration - position)))
                        }
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(faint)
                    }
                }
                .frame(height: 22)
            }
            HStack(spacing: 22) {
                button("backward.fill", 15, nowPlaying.previous)
                button(nowPlaying.isPlaying ? "pause.fill" : "play.fill", 24, nowPlaying.playPause)
                button("forward.fill", 15, nowPlaying.next)
            }
        }
        .overlay(alignment: .topTrailing) { if hovering { closeButton.offset(x: 6, y: -6) } }
    }

    // MARK: Parts

    private func artwork(side: CGFloat, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack {
            shape.fill(well)
            if let image = nowPlaying.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let track = nowPlaying.track {
                critter(CueCritter(side: side * 0.45, mood: .playing(nowPlaying.isPlaying, trackID: track.id)))
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .help(model.expanded ? "Make it small" : "Open it out")
    }

    private func button(_ symbol: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(symbol, size: size, weight: .bold)
                .frame(width: size + 16, height: size + 16)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button(action: close) {
            Icon("xmark", size: 8, weight: .bold)
                .frame(width: 18, height: 18)
                .foregroundStyle(dark ? .white : Color(light: 0x555555, dark: 0x555555))
                .background(dark ? Color(white: 0.25) : Color(light: 0xD2D2D0, dark: 0xD2D2D0), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(dark ? 0.2 : 0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Close the mini player")
    }

    /// The critter is white: on the light pane a faint outline keeps it from fading in.
    private func critter(_ critter: CueCritter) -> some View {
        critter
            .shadow(color: .black.opacity(dark ? 0 : 0.35), radius: 0.6)
            .shadow(color: .black.opacity(dark ? 0 : 0.2), radius: 1.5)
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
