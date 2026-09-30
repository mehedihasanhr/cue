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

    /// Where the bar is, so the window picker can stop short of it rather than slide under.
    var barFrame: () -> NSRect? = { nil }

    init(model: RecorderModel) {
        self.model = model
    }

    var isVisible: Bool { !windows.isEmpty }

    func show() {
        hide()
        let pointer = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            // A non-activating panel, the way Spotlight and Raycast come up. It takes the
            // keyboard without making Klik Studio the active app — and activating an app is
            // what makes macOS leave a full-screen Space for one where that app has a
            // window. Over a full-screen app, or a private browser window you are about to
            // pick, the overlay has to come up *there*.
            let window = OverlayWindow(contentRect: screen.frame,
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered,
                                       defer: false,
                                       screen: screen)
            // Above a full-screen app, and under the bar.
            //
            // `floating - 1` was under the bar and under anything full-screen, so this
            // never appeared on the Space somebody was actually working on — only on a
            // plain desktop. The area picker has always used `.screenSaver` for exactly
            // this reason and has always worked over full-screen apps; the difference was
            // never deliberate. The bar sits one above, so it stays usable: you can still
            // change your mind about the microphone without dismissing this first.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue)
            // Not pinned to dark, unlike the bar. Everything drawn straight onto the scrim
            // is white by hand; the window picker is a panel of its own, and it follows the
            // system's light or dark appearance like any other window would.
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            // Not `isFloatingPanel`: setting it puts the level back to `.floating`, which
            // silently undid the `.screenSaver` above and left this under full-screen apps.
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = false
            window.isExcludedFromWindowsMenu = true
            window.animationBehavior = .none
            window.onCancel = { [weak self] in self?.hide() }

            let view = TargetOverlayView(model: model,
                                         insets: Self.insets(on: screen, clearing: barFrame()),
                                         displayID: Self.displayID(of: screen),
                                         screenName: screen.localizedName,
                                         // Only one screen should carry the card when the
                                         // target is not a display — the one being used.
                                         isPointerScreen: NSMouseInRect(pointer, screen.frame, false),
                                         start: { [weak self] in self?.start() },
                                         cancel: { [weak self] in self?.hide() })

            window.contentView = NSHostingView(rootView: view)
            window.orderFrontRegardless()
            windows.append(window)
        }

        // Key — without which none of this can hear a keystroke.
        //
        // A local event monitor only sees events delivered to this app, and keystrokes go
        // to whichever app owns the key window. A non-activating panel can be that window
        // while another app stays active, so escape, return and the search field all work
        // without `NSApp.activate` — which is deliberately not called: it is what pulled
        // the user off a full-screen Space the moment the picker opened.
        let front = windows.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? windows.first
        front?.makeKeyAndOrderFront(nil)
        front?.makeFirstResponder(front?.contentView)

        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53:                                          // escape
                self?.hide()
                return nil                                    // swallowed, not passed on
            case 36, 76:                                      // return, enter
                // The button the overlay exists for, from the keyboard — so searching for
                // a window and taking it never needs the mouse.
                guard let self, self.model.target != nil else { return event }
                self.start()
                return nil
            default:
                return event
            }
        }
    }

    func hide() {
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    /// The room the window picker has on one screen: under the menu bar, and above the
    /// recorder bar if it is on this screen — or above the Dock if it is not.
    private static func insets(on screen: NSScreen, clearing bar: NSRect?) -> EdgeInsets {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let top = frame.maxY - visible.maxY + 28
        var bottom = visible.minY - frame.minY + 28
        if let bar, frame.intersects(bar) {
            // The panel's frame carries 14 points of transparent room for the bar's shadow.
            bottom = max(bottom, bar.maxY - 14 - frame.minY + 20)
        }
        return EdgeInsets(top: top, leading: 40, bottom: bottom, trailing: 40)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// Borderless windows cannot take the keyboard unless they say they can, and an overlay
/// that swallows the screen without answering Escape is a trap.
private final class OverlayWindow: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

// MARK: - What one screen shows

private struct TargetOverlayView: View {
    let model: RecorderModel
    let insets: EdgeInsets
    let displayID: CGDirectDisplayID?
    let screenName: String
    let isPointerScreen: Bool
    let start: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack {
            scrim
            if showsCard {
                Group {
                    if model.mode == .window {
                        windowPicker
                    } else if model.mode == .device {
                        devicePicker
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

    /// Dark enough that white type is unambiguous over a bright wallpaper. Neutral, not
    /// tinted: a blue wash turned every wallpaper the same bruised navy and made the panel
    /// on top of it look dirty in either theme.
    private var scrim: some View {
        Color.black.opacity(0.6)
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
    ///
    /// They are laid out on one panel rather than straight onto the dimmed wallpaper.
    /// Loose cards over a photograph took their contrast from whatever was behind them, and
    /// the button underneath collided with the bar. A single surface — header, windows,
    /// footer — reads as one decision with one place to confirm it.
    private var windowPicker: some View {
        WindowPickerPanel(model: model, start: start, cancel: cancel)
            // Clear of the menu bar and of the recorder bar, which stays usable under this.
            .padding(insets)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Naming a connected iPhone or iPad — usually one, sometimes none, rarely more.
    private var devicePicker: some View {
        DevicePickerPanel(model: model, start: start, cancel: cancel)
            .padding(insets)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The device picker: the iPhones and iPads on a cable, and the choice.
///
/// The window picker's shape, smaller, because the list is short — and because what it
/// most often has to say is why the list is empty. A device only appears once it is
/// unlocked and trusts this Mac, both of which happen on the device, so the empty state
/// says exactly that rather than "no devices", which would send somebody looking for a
/// setting on the Mac that does not exist.
private struct DevicePickerPanel: View {
    let model: RecorderModel
    let start: () -> Void
    let cancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var selected: RecorderModel.Source? {
        model.devices.first { $0.target == model.target }
    }

    private let radius: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            actionBar
        }
        .frame(maxWidth: 560)
        .background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(colorScheme == .dark ? Color(white: 0.13).opacity(0.95)
                                                : Color(white: 0.985).opacity(0.97))
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.3), radius: 44, y: 20)
        }
        .animation(StudioMotion.selection, value: model.devices.map(\.id))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "apps.iphone")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Record an iPhone or iPad")
                .font(.system(size: 19))
                .foregroundStyle(.primary)
            Spacer()
            if !model.devices.isEmpty {
                Text(model.devices.count == 1 ? "1 device" : "\(model.devices.count) devices")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
    }

    @ViewBuilder
    private var content: some View {
        if model.deviceAccessDenied {
            message(symbol: "video.slash",
                    title: "Klik Studio isn\u{2019}t allowed to use the camera",
                    detail: "A connected iPhone or iPad is recorded the way a camera is, so it needs the same permission.") {
                Button("Allow Camera in Settings\u{2026}") { model.openCameraSettings() }
                    .padding(.top, 6)
            }
        } else if model.devices.isEmpty {
            message(symbol: "cable.connector",
                    title: "No iPhone or iPad connected",
                    detail: "Connect an iPhone or iPad with a cable, unlock it and trust this Mac.") {
                EmptyView()
            }
        } else {
            VStack(spacing: 4) {
                ForEach(model.devices) { source in
                    DeviceRow(source: source, isSelected: model.target == source.target) {
                        model.select(source)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func message<Extra: View>(symbol: String, title: String, detail: String,
                                      @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.primary.opacity(0.35))
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            extra()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let selected {
                Text(selected.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)
            } else {
                Text(model.devices.isEmpty ? "Waiting for a device\u{2026}" : "Select a device to record it")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)

            ActionChip(title: "Record Device", key: "\u{21A9}", isPrimary: true, action: start)
                .disabled(selected == nil || model.deviceAccessDenied)
                .opacity(selected == nil || model.deviceAccessDenied ? 0.4 : 1)
            Rectangle()
                .fill(.primary.opacity(0.12))
                .frame(width: 1, height: 16)
            ActionChip(title: "Cancel", key: "esc", isPrimary: false, action: cancel)
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .frame(height: 56)
    }
}

/// One connected device on offer.
private struct DeviceRow: View {
    let source: RecorderModel.Source
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var symbol: String {
        source.subtitle.hasPrefix("iPad") ? "ipad" : "iphone"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.primary.opacity(0.75))
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(source.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, StudioPalette.brand)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(.primary.opacity(highlight),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.98))
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
        .animation(StudioMotion.selection, value: isSelected)
    }

    private var highlight: Double {
        let dark = colorScheme == .dark
        if isSelected { return dark ? 0.12 : 0.07 }
        return isHovering ? (dark ? 0.06 : 0.035) : 0
    }
}

/// The window picker: search, the windows grouped by where they are, and the choice.
///
/// Shaped like a launcher rather than a dialog. The search field *is* the header, there
/// are no rules or outlines — space and a change of shade do the separating — and the one
/// action lives in a quiet bar along the bottom, with the key that does it beside it.
private struct WindowPickerPanel: View {
    @Bindable var model: RecorderModel
    let start: () -> Void
    /// The same as pressing escape.
    let cancel: () -> Void
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var onScreen: [RecorderModel.Source] { model.filteredWindows.filter(\.isOnScreen) }
    private var elsewhere: [RecorderModel.Source] { model.filteredWindows.filter { !$0.isOnScreen } }

    private var selected: RecorderModel.Source? {
        model.windows.first { $0.target == model.target }
    }

    private let radius: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            content
            if let note = model.resizeNote { resizeNote(note) }
            actionBar
        }
        .frame(maxWidth: 880)
        .background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                // Near-solid, not glass. Over a scrim this dark any material turns to the
                // same muddy grey in both themes, and the previews and labels on it lose
                // their edges. A clean surface is what lets the content carry the contrast.
                shape.fill(.regularMaterial)
                shape.fill(colorScheme == .dark ? Color(white: 0.13).opacity(0.95)
                                                : Color(white: 0.985).opacity(0.97))
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.3), radius: 44, y: 20)
        }
        .onAppear { searchFocused = true }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "macwindow")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            // The prompt is styled apart from the text: `foregroundStyle` below would
            // otherwise paint it full strength, and a hint that looks typed is not a hint.
            TextField("", text: $model.windowSearch,
                      prompt: Text("Choose a window to record…").foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .foregroundStyle(.primary)
                .focused($searchFocused)
            if model.windowSearch.isEmpty {
                Text(countLine)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    model.windowSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
    }

    private var countLine: String {
        let count = model.windows.count
        return count == 1 ? "1 window" : "\(count) windows"
    }

    // MARK: Windows

    @ViewBuilder
    private var content: some View {
        if model.filteredWindows.isEmpty {
            emptyState
        } else {
            // Grows with the windows until it runs out of room, then scrolls — a panel
            // that is 600 points tall around four windows is mostly nothing.
            ViewThatFits(in: .vertical) {
                sections
                ScrollView { sections }.scrollIndicators(.automatic)
            }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !onScreen.isEmpty {
                section("On this desktop", onScreen)
            }
            // The Space used to be a badge on every card; as a heading it is said once, and
            // the windows you can see come first.
            if !elsewhere.isEmpty {
                section("On other Spaces", elsewhere)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private func section(_ title: String, _ sources: [RecorderModel.Source]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 4)],
                      alignment: .leading,
                      spacing: 4) {
                ForEach(sources) { source in
                    WindowTile(source: source,
                               thumbnail: model.thumbnail(for: source),
                               isSelected: model.target == source.target) {
                        model.select(source)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.windows.isEmpty ? "macwindow.on.rectangle" : "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.primary.opacity(0.35))
                .padding(.bottom, 4)
            Text(model.windows.isEmpty ? "No windows are open to record"
                                       : "No windows match “\(model.windowSearch)”")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
            Text(model.windows.isEmpty ? "Open the app you want to record, and it will appear here."
                                       : "Try the app's name, or part of the window's title.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let selected {
                AppIcon(processID: selected.processID, size: 20)
                Text(selected.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)
                Text(model.targetDetail.isEmpty ? selected.subtitle : model.targetDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Select a window to record it")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)

            if selected != nil { sizeMenu }

            ActionChip(title: "Record Window", key: "↩", isPrimary: true, action: start)
                .disabled(selected == nil)
                .opacity(selected == nil ? 0.4 : 1)
            Rectangle()
                .fill(.primary.opacity(0.12))
                .frame(width: 1, height: 16)
            ActionChip(title: "Cancel", key: "esc", isPrimary: false, action: cancel)
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .frame(height: 56)
        .animation(StudioMotion.selection, value: selected?.id)
    }
}

extension WindowPickerPanel {
    /// The sizes the chosen window can be put at before it is recorded.
    ///
    /// Beside the button that records it, because it is the last thing decided about the
    /// window and the first thing the recording's shape depends on. Greyed for a window on
    /// another Space, which Accessibility cannot reach.
    var sizeMenu: some View {
        Menu {
            Section("Resize the window to record at") {
                ForEach(WindowSizePreset.allCases) { preset in
                    Button {
                        model.resizeWindow(to: preset)
                    } label: {
                        Text(preset.title)
                        Text(preset.subtitle)
                    }
                }
            }
        } label: {
            Label("Size", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.resizableWindow == nil)
        .help(model.resizableWindow == nil
              ? "Only a window on this desktop can be resized"
              : "Put the window at a preset size, so the recording is that shape")
    }

    /// What the last resize did, or why it could not, with the way to the grant when that
    /// is what is missing.
    func resizeNote(_ note: RecorderModel.ResizeNote) -> some View {
        HStack(spacing: 8) {
            Image(systemName: note.isGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(note.isGood ? Color.green : Color.orange)
            Text(note.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if note.needsAccess {
                Button("Allow in System Settings…") { model.requestAccessibility() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .transition(.opacity)
    }
}

/// An action and its key, the way a launcher lists them: words, then the keycap.
private struct ActionChip: View {
    let title: String
    let key: String
    let isPrimary: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: isPrimary ? .semibold : .regular))
                    .foregroundStyle(.primary.opacity(isPrimary ? 0.95 : 0.6))
                KeyCap(key: key)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.primary.opacity(isHovering ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.97))
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
    }
}

/// A key, drawn as a key.
private struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(0.6))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// The icon of the application that owns a window.
private struct AppIcon: View {
    let processID: pid_t
    let size: CGFloat

    var body: some View {
        if processID != 0, let icon = NSRunningApplication(processIdentifier: processID)?.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: size * 0.6))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// One window on offer.
///
/// No outline in any state. Resting, it is the window and its name on the panel; hovered
/// or chosen, a soft wash comes up behind it, the way a launcher marks the row you are on.
private struct WindowTile: View {
    let source: RecorderModel.Source
    let thumbnail: CGImage?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    /// The window's own title, which is what tells two windows of one application apart.
    ///
    /// It used to be replaced by "On another Space" whenever that was true, which was
    /// exactly backwards: the Space is a footnote and the title is the answer. Five rows
    /// reading "Google Chrome · On another Space" are five ways to pick the wrong one.
    private var subtitle: String {
        source.subtitle.isEmpty ? "Untitled window" : source.subtitle
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                preview
                HStack(spacing: 9) {
                    AppIcon(processID: source.processID, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 2)
            }
            .padding(10)
            .background(.primary.opacity(highlight),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.98))
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
        .animation(StudioMotion.selection, value: isSelected)
        .help(source.subtitle.isEmpty ? source.title : "\(source.title) — \(source.subtitle)")
    }

    /// A wash behind the tile, lighter in light mode — the same step of grey reads twice
    /// as heavy on a white panel as on a dark one.
    private var highlight: Double {
        let dark = colorScheme == .dark
        if isSelected { return dark ? 0.12 : 0.07 }
        return isHovering ? (dark ? 0.06 : 0.035) : 0
    }

    /// The window itself, shown whole inside a well rather than cropped to fill it — the
    /// way Mission Control shows it — so a tall window and a wide one both read as windows.
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                // A step lighter than the panel in dark mode, not darker: most windows are
                // dark themselves, and a black well swallowed them whole.
                .fill(colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.045))

            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 8, y: 3)
                    .padding(12)
            } else {
                // Not photographed — another Space, or a window that refuses to be. The
                // app's icon says whose it is, which a grey box never did.
                AppIcon(processID: source.processID, size: 44)
                    .opacity(source.isShareable ? 0.9 : 0.35)
            }

            VStack {
                HStack(alignment: .top) {
                    if !source.isShareable {
                        Label("Hidden from recording", systemImage: "eye.slash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                    }
                    Spacer()
                    if isSelected {
                        // The one mark of the accent in the grid: which window will record.
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, StudioPalette.brand)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                Spacer()
            }
            .padding(7)
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .frame(maxWidth: .infinity)
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
        // The global shortcut, so it can be learned here and used from any app next time.
        .help(RecorderCenter.shared?.help("Start recording", .record) ?? "Start recording")
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
    }
}
