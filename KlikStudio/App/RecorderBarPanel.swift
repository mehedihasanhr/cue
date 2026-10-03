import AppKit
import SwiftUI

/// The window the recorder bar lives in.
///
/// An `NSPanel`, not a SwiftUI `Window`, for three reasons a recorder cares about: it
/// floats above other apps, it can be non-activating (clicking Record does not pull you
/// out of the app you are demonstrating), and it follows you between Spaces. None of
/// those are expressible in a plain scene on macOS 14.
@MainActor
final class RecorderBarPanel {
    private var panel: NSPanel?
    private let settings: StudioSettings
    private let studio: StudioService
    let model: RecorderModel

    /// What the bar's menu items reach back into the app for.
    var showLibrary: () -> Void = {}
    var openSettings: () -> Void = {}
    /// Told whenever the bar comes or goes. The microphone meter and the camera preview
    /// run only while the bar is on screen, and this is how they know.
    var onVisibilityChange: (Bool) -> Void = { _ in }

    /// The size the bar last said it wants. The panel is allowed to be bigger than this
    /// for a moment while a shape change plays out.
    private var wantedSize: NSSize = .zero
    private var tighten: Task<Void, Never>?
    /// Where the bar is: the middle of its bottom edge, which is the one point of it that
    /// stays put while its width changes.
    ///
    /// Kept here rather than read back off the window. The window's frame is what changes
    /// when the bar changes shape, so a centre read from it afterwards is the centre of
    /// wherever the resize happened to leave it — which is how the bar came to sit against
    /// its old left edge for the whole of every take. Set when the bar is first placed and
    /// when somebody drags it, and by nothing else.
    private var anchor: CGPoint?
    /// True while this is the one moving the window, so that is not mistaken for a drag.
    private var isPlacing = false
    private var moveObserver: (any NSObjectProtocol)?
    /// The screen-filling overlay that names the target. Owned here rather than by the
    /// bar, because it outlives any one view and starting a take has to take it down.
    private lazy var targets = TargetOverlayController(model: model)
    /// The bar minimized: the clock on a small island at the screen's edge.
    private lazy var island: RecordingIsland = {
        let island = RecordingIsland(studio: studio, settings: settings)
        island.expand = { [weak self] in self?.show() }
        // Records what the bar has chosen, from the island; with nothing chosen yet the
        // bar comes back to ask, as its own Record button does.
        island.record = { [weak self] in
            guard let self else { return }
            if self.model.canRecord {
                self.model.record()
            } else {
                self.show()
                self.begin(self.model.mode)
            }
        }
        return island
    }()

    init(settings: StudioSettings, studio: StudioService) {
        self.settings = settings
        self.studio = studio
        model = RecorderModel(settings: settings, studio: studio)
        // Dragging out an area puts up its own overlay; this one waits until that is
        // finished rather than appearing underneath it.
        model.onAreaPicked = { [weak self] in self?.targets.show() }
        targets.start = { [weak self] in
            self?.model.record()
            self?.targets.hide()
        }
        targets.barFrame = { [weak self] in
            guard let panel = self?.panel, panel.isVisible else { return nil }
            return panel.frame
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        defer {
            // Every time, not only the first: a bar that comes back after an edit was
            // listing the windows that were open before it, and offering recents that are
            // one recording out of date.
            Task {
                await model.refreshSources()
                model.refreshRecents()
            }
        }

        model.isMinimized = false
        island.hide()
        model.presentations += 1
        if let panel {
            panel.orderFrontRegardless()
            onVisibilityChange(true)
            return
        }

        let bar = RecorderBar(model: model,
                              close: { [weak self] in self?.hide() },
                              minimize: { [weak self] in self?.minimize() },
                              showLibrary: { [weak self] in self?.showLibrary() },
                              openSettings: { [weak self] in self?.openSettings() },
                              showTargets: { [weak self] mode in
                                  // Area raises its own drag overlay first; this one
                                  // follows from `onAreaPicked` once a rectangle exists.
                                  // Area raises its own drag overlay first; this one
                                  // follows from `onAreaPicked` once a rectangle exists.
                                  // Window shows this overlay directly, as a grid of
                                  // pictures of the windows.
                                  guard mode.isAvailable, mode != .area else { return }
                                  self?.targets.show()
                              })
            .environment(studio)
            .environment(settings)
            .padding(14)   // room for the bar's own shadow, which a borderless window clips
            .background(BarSizeReporter { [weak self] size in self?.resize(to: size) })

        let hosting = NSHostingView(rootView: bar)
        // The window's size is decided here and nowhere else. Left to size itself from its
        // content, AppKit resizes a window about its bottom-left corner the moment the
        // content changes — before `resize(to:)` has been told, and from the wrong corner.
        hosting.sizingOptions = []

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered,
                            defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        // A step above `.floating`, so the target overlay can sit over every other app
        // and still leave the bar on top of itself — you can change the microphone
        // without dismissing the overlay to get at it.
        // One above the target overlay, which is at `.screenSaver` so it can appear over
        // a full-screen app. The bar has to stay above it — choosing a window and then
        // changing the microphone is one continuous thought.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        // Dark, whatever the system is set to.
        //
        // This chrome is white on a black-tinted glass, and the tint is deliberately light
        // enough to let the wallpaper through. Under a light appearance the same glass
        // renders near-white, so the labels went white-on-white and an unavailable one —
        // already dimmed to 30% — disappeared altogether. A recorder floats over whatever
        // is being filmed rather than over the app's own surfaces, so it has no appearance
        // to agree with: it is furniture of its own, and pinning it is what lets the one
        // palette hold.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false        // the SwiftUI bar draws its own, shaped to its corners
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // The bar is furniture, not a document: it should not be in the window menu or
        // restored into a random corner on next launch.
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .utilityWindow

        self.panel = panel
        position(panel)
        // Somebody dragging the bar is somebody choosing where it lives.
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                                              object: panel,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }
        panel.orderFrontRegardless()
        onVisibilityChange(true)
    }

    private func moved() {
        guard let panel, !isPlacing else { return }
        anchor = CGPoint(x: panel.frame.midX, y: panel.frame.minY)
    }

    func hide() {
        targets.hide()
        panel?.orderOut(nil)
        onVisibilityChange(false)
    }

    /// Puts the bar away for the rest of the take. The menu bar icon carries on with the
    /// clock, pause and stop, and offers the bar back.
    func minimize() {
        let frame = panel?.frame
        model.isMinimized = true
        hide()
        island.show(below: frame)
    }

    /// The take is over: the island goes, and the bar is the app's to show or not.
    func leaveMinimized() {
        model.isMinimized = false
        island.hide()
    }

    /// The bar's window, for what sits beside it — the camera preview follows it about.
    var window: NSWindow? { panel }

    /// Starts choosing a target from outside the bar — the menu bar icon's Record Area and
    /// Record Window — exactly as pressing that mode on the bar does.
    func begin(_ mode: RecorderModel.Mode) {
        show()
        model.choose(mode)
        guard mode.isAvailable, mode != .area else { return }
        targets.show()
    }

    /// Takes the target overlay down, for a take started by a shortcut while it was up.
    func hideTargets() {
        targets.hide()
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// Bottom centre of the screen with the pointer on it: near the Dock, out of the way
    /// of the thing being recorded, and where Screen Studio and QuickTime both put it.
    ///
    /// Only the first placement is ours. After that the bar keeps whatever centre it has,
    /// because the user may have dragged it somewhere they prefer.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = wantedSize.width > 1 ? wantedSize : panel.frame.size
        anchor = CGPoint(x: visible.midX, y: visible.minY + 24)
        place(panel, size: size, display: false)
    }

    /// Puts the window where the anchor says, at a size, without that counting as a drag.
    private func place(_ panel: NSPanel, size: NSSize, display: Bool) {
        guard let anchor else { return }
        var frame = NSRect(x: (anchor.x - size.width / 2).rounded(),
                           y: anchor.y.rounded(),
                           width: size.width, height: size.height)
        // Kept on the screen it is on: a bar dragged to the edge and then widened would
        // otherwise grow off the side, with its close button out of reach.
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame, frame.width <= visible.width {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        }
        guard frame != panel.frame else { return }
        isPlacing = true
        panel.setFrame(frame, display: display)
        isPlacing = false
    }

    /// Takes the width the bar asked for, without letting it drift off centre.
    ///
    /// The bar is not one width. The display's name arrives from ScreenCaptureKit a moment
    /// after the panel opens and widens it; starting a take drops two thirds of the
    /// controls and halves it. Every one of those changes used to leave the bar where its
    /// left edge had been, because that is the corner AppKit resizes a window about — so
    /// the bar that opened centred stopped being centred the first time it changed.
    private func resize(to size: CGSize) {
        guard let panel else { return }
        let target = NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard target.width > 1, target.height > 1 else { return }
        wantedSize = target
        tighten?.cancel()

        // Growing has to happen now, or the window clips the bar while it expands.
        if target.width > panel.frame.width || target.height > panel.frame.height {
            apply(target)
            return
        }

        // Shrinking can wait. Everything around the bar is transparent, so a window that
        // is briefly too large is invisible — where one that is briefly too small cuts the
        // bar off halfway through its own animation.
        tighten = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(StudioMotion.shapeDuration * 1000) + 40))
            guard !Task.isCancelled, let self else { return }
            self.apply(self.wantedSize)
        }
    }

    /// Takes a size about the bar's anchor, so a change of width happens about the middle
    /// of the bar rather than about its left edge. The anchor is the screen's bottom
    /// centre, or wherever the user dragged the bar to.
    private func apply(_ size: NSSize) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        place(panel, size: size, display: true)
    }
}
