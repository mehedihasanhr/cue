import AppKit
import CoreGraphics
import RecordKit
import SwiftUI

/// The screen-filling confirmation that comes up when a mode is chosen.
///
/// Picking "Display" is not the same as knowing what will be recorded. The bar can only
/// ever name the target in twelve points of text somewhere along a strip; this dims the
/// whole screen and says it once, in the middle, at the size of the decision — the display
/// or window by name, the resolution and frame rate it will actually capture at, and the
/// button that starts it.
///
/// It is also the answer to "which display?" on more than one screen: every screen gets an
/// overlay naming *itself*, so choosing between them is pointing at one rather than
/// reading a menu of near-identical names.
@MainActor
final class TargetOverlayController {
    private var windows: [OverlayWindow] = []
    private let model: RecorderModel
    /// Watches for escape while the overlay is up.
    ///
    /// A monitor rather than `cancelOperation`, which is what this relied on and which
    /// never fired: the overlay is ordered front but deliberately never made key — the bar
    /// above it has to stay usable, so you can change your mind about the microphone
    /// without dismissing this first. A window that is not key has no first responder, so
    /// the key never reached it and escape did nothing at all.
    private var escape: Any?

    /// Pressing the button. The panel owns what that means, because starting a take also
    /// has to take the overlay down.
    var start: () -> Void = {}

    init(model: RecorderModel) {
        self.model = model
    }

    var isVisible: Bool { !windows.isEmpty }

    func show() {
        hide()
        let pointer = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame,
                                       styleMask: [.borderless],
                                       backing: .buffered,
                                       defer: false,
                                       screen: screen)
            // Under the bar, over everything else: the bar stays usable — you can change
            // your mind about the microphone without dismissing this first.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isExcludedFromWindowsMenu = true
            window.animationBehavior = .none
            window.onCancel = { [weak self] in self?.hide() }

            let view = TargetOverlayView(model: model,
                                         displayID: Self.displayID(of: screen),
                                         screenName: screen.localizedName,
                                         // Only one screen should carry the card when the
                                         // target is not a display — the one being used.
                                         isPointerScreen: NSMouseInRect(pointer, screen.frame, false),
                                         start: { [weak self] in self?.start() })

            window.contentView = NSHostingView(rootView: view)
            window.orderFrontRegardless()
            windows.append(window)
        }

        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // escape
            self?.hide()
            return nil                                        // swallowed, not passed on
        }
    }

    func hide() {
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// Borderless windows cannot take the keyboard unless they say they can, and an overlay
/// that swallows the screen without answering Escape is a trap.
private final class OverlayWindow: NSWindow {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

// MARK: - What one screen shows

private struct TargetOverlayView: View {
    let model: RecorderModel
    let displayID: CGDirectDisplayID?
    let screenName: String
    let isPointerScreen: Bool
    let start: () -> Void

    var body: some View {
        ZStack {
            scrim
            if showsCard {
                Group {
                    if model.mode == .window {
                        windowPicker
                    } else {
                        card
                    }
                }
                .transition(StudioMotion.reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .ignoresSafeArea()
        .animation(StudioMotion.selection, value: model.targetLabel)
    }

    /// Dark enough that white type is unambiguous over a bright wallpaper, with a breath
    /// of Klik blue so the dim reads as this app's rather than the system's.
    private var scrim: some View {
        ZStack {
            Color.black.opacity(0.52)
            StudioPalette.brand.opacity(0.14)
        }
    }

    /// Every display names itself. Anything else is named once, on the screen you are
    /// working on, because a window lives on one screen and repeating it on the others
    /// would be four copies of one answer.
    private var showsCard: Bool {
        model.mode == .display ? displayID != nil : isPointerScreen
    }

    private var isArmed: Bool {
        guard model.mode == .display else { return model.target != nil }
        return displayID != nil && model.target?.displayID == displayID
    }

    private var title: String {
        guard model.mode == .display else {
            return model.targetLabel.isEmpty ? "Nothing chosen yet" : model.targetLabel
        }
        return source?.title ?? screenName
    }

    private var detail: String {
        model.mode == .display ? (source.map(Self.detail) ?? "") : model.targetDetail
    }

    private var source: RecorderModel.Source? {
        guard let displayID else { return nil }
        return model.displays.first { $0.target.displayID == displayID }
    }

    private var card: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 46, weight: .bold))
                // Large type reads too loose at its default tracking; Apple tightens as
                // it grows, and so does this.
                .tracking(-0.8)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 18, y: 4)

            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
            }

            StartButton(isArmed: isArmed, action: start)
                .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: 620)
    }

    private static func detail(_ source: RecorderModel.Source) -> String {
        source.subtitle
    }

    /// Naming a window, which is the one target that cannot be guessed.
    ///
    /// The bar used to do this in a menu beside the modes. A menu of thirty near-identical
    /// rows is the wrong shape for "which of these am I pointing at" — the overlay has the
    /// whole screen, so the windows are laid out as things you point at.
    private var windowPicker: some View {
        @Bindable var model = model
        return VStack(spacing: 16) {
            Text(model.targetLabel.isEmpty ? "Choose a window" : model.targetLabel)
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 3)

            TextField("Search windows", text: $model.windowSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(width: 280, height: 34)
                .background(.white.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16)))

            if model.filteredWindows.isEmpty {
                Text(model.windows.isEmpty ? "No windows are open to record."
                                           : "Nothing matches that.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(height: 120)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                        ForEach(model.filteredWindows) { source in
                            WindowTile(source: source,
                                       isSelected: model.target == source.target) {
                                model.select(source)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxWidth: 760, maxHeight: 300)
            }

            StartButton(isArmed: model.target != nil, action: start)
                .padding(.top, 4)
                .disabled(model.target == nil)
                .opacity(model.target == nil ? 0.45 : 1)
        }
        .padding(40)
    }
}

/// One window on offer.
private struct WindowTile: View {
    /// What the row says under the name, which is not always the window's title.
    ///
    /// Two facts matter more than the title when they are true: a window the system will
    /// not let a recording see captures as a black rectangle, and a window on another
    /// Space cannot be pointed at — both are better said here than discovered afterwards.
    private var subtitle: String {
        if !source.isShareable { return "Hidden from recording by its app" }
        if !source.isOnScreen { return "On another Space — recording will switch to it" }
        return source.subtitle.isEmpty ? "Untitled window" : source.subtitle
    }

    let source: RecorderModel.Source
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(source.isShareable ? .white.opacity(0.6) : Color.orange.opacity(0.9))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .frame(height: 50)
            .background(isSelected ? AnyShapeStyle(StudioPalette.brand.opacity(0.85))
                                   : AnyShapeStyle(.white.opacity(isHovering ? 0.16 : 0.09)),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(isSelected ? 0.3 : 0.12))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.97))
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
    }
}

/// The one button the overlay exists for.
private struct StartButton: View {
    let isArmed: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "record.circle")
                    .font(.system(size: 15, weight: .semibold))
                Text(isArmed ? "Start recording" : "Record this display")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 46)
            .background(StudioPalette.brand.opacity(isHovering ? 1 : 0.92),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            .shadow(color: StudioPalette.brand.opacity(0.45), radius: 18, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.96))
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
    }
}
