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

    /// The size the bar last said it wants. The panel is allowed to be bigger than this
    /// for a moment while a shape change plays out.
    private var wantedSize: NSSize = .zero
    private var tighten: Task<Void, Never>?
    /// The screen-filling overlay that names the target. Owned here rather than by the
    /// bar, because it outlives any one view and starting a take has to take it down.
    private lazy var targets = TargetOverlayController(model: model)

    init(settings: StudioSettings, studio: StudioService) {
        self.settings = settings
        self.studio = studio
        model = RecorderModel(settings: settings, studio: studio)
        // Dragging out an area puts up its own overlay; this one waits until that is
        // finished rather than appearing underneath it.
        model.onAreaPicked = { [weak self] in self?.targets.show() }
        // Both pickers take the screen first and raise the confirmation afterwards; the
        // list is the fallback for a window that cannot be pointed at.
        model.onWindowPicked = { [weak self] in self?.targets.show() }
        model.onWindowListWanted = { [weak self] in self?.targets.show() }
        targets.start = { [weak self] in
            self?.model.record()
            self?.targets.hide()
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

        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let bar = RecorderBar(model: model,
                              close: { [weak self] in self?.hide() },
                              showLibrary: { [weak self] in self?.showLibrary() },
                              openSettings: { [weak self] in self?.openSettings() },
                              showTargets: { [weak self] mode in
                                  // Area raises its own drag overlay first; this one
                                  // follows from `onAreaPicked` once a rectangle exists.
                                  // Area and window both raise their own picker first;
                                  // this overlay follows from their callbacks.
                                  guard mode.isAvailable, mode != .area, mode != .window else { return }
                                  self?.targets.show()
                              })
            .environment(studio)
            .environment(settings)
            .padding(14)   // room for the bar's own shadow, which a borderless window clips
            .background(BarSizeReporter { [weak self] size in self?.resize(to: size) })

        let hosting = NSHostingView(rootView: bar)
        hosting.sizingOptions = [.intrinsicContentSize]

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered,
                            defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        // A step above `.floating`, so the target overlay can sit over every other app
        // and still leave the bar on top of itself — you can change the microphone
        // without dismissing the overlay to get at it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
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
        panel.orderFrontRegardless()
    }

    func hide() {
        targets.hide()
        panel?.orderOut(nil)
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
        let size = panel.frame.size
        panel.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(),
                              y: visible.minY + 24,
                              width: size.width, height: size.height),
                       display: false)
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
        guard target.width > 1, target.height > 1, target != panel.frame.size else { return }
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

    /// Re-derives the origin from the centre the bar is on, so a change of width happens
    /// about the middle of the bar rather than about its left edge. That centre is
    /// whatever it currently is: the screen's, or wherever the user dragged the bar to.
    private func apply(_ size: NSSize) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        let frame = NSRect(x: (panel.frame.midX - size.width / 2).rounded(),
                           y: panel.frame.minY,
                           width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }
}
