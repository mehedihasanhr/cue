import AppKit
import RecordKit

/// The recorder's icon in the menu bar, and its menu.
///
/// What the icon says is `RecorderStatus`: a plain icon while idle, the number during a
/// countdown, a red dot and the elapsed time while recording, a pause symbol while held.
/// The menu is every recorder action again, so a take can be started, held, marked,
/// restarted and stopped with the bar hidden behind an editor or on another display.
///
/// Never in a recording: the icon and its menu are this app's windows, and a display or
/// area recording leaves out every window this app owns — see `CaptureExclusion`. That is
/// why the menu can be opened to press Stop without the menu itself ending the video.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// What the menu reaches back into the app for.
    struct Actions {
        var recordScreen: () -> Void = {}
        var recordArea: () -> Void = {}
        var recordWindow: () -> Void = {}
        var perform: (RecorderAction) -> Void = { _ in }
        var stop: () -> Void = {}
        var cancelCountdown: () -> Void = {}
        var toggleNotes: () -> Void = {}
        var showRecordings: () -> Void = {}
        var openSettings: () -> Void = {}
        var showBar: () -> Void = {}
    }

    var actions = Actions()
    /// The bar is put away, so the menu offers it back first.
    var isBarMinimized = false
    private let studio: StudioService
    private let preferences: RecorderPreferences
    private var item: NSStatusItem?
    private var ticker: Timer?
    private var shown: RecorderStatus?

    init(studio: StudioService, preferences: RecorderPreferences) {
        self.studio = studio
        self.preferences = preferences
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            item.button?.imagePosition = .imageLeading
            self.item = item
            shown = nil
            refresh()
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// Redraws the icon, and keeps a clock running while the time is on it.
    func refresh() {
        let state = studio.session.state
        if state.isTaking || state.countdownRemaining != nil {
            startTicking()
        } else {
            stopTicking()
        }
        draw(RecorderStatus(state, at: .now))
    }

    private func draw(_ status: RecorderStatus) {
        guard let button = item?.button, status != shown else { return }
        shown = status
        let image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.description)
        if status.phase == .recording, let image {
            // Red while recording, the way every recorder's is: a template image would
            // be drawn in the menu bar's own colour and read as idle at a glance.
            let red = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = image.withSymbolConfiguration(red)
            button.image?.isTemplate = false
        } else {
            button.image = image
            button.image?.isTemplate = true
        }
        button.title = status.title.isEmpty ? "" : " \(status.title)"
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.toolTip = status.description
        button.setAccessibilityLabel(status.description)
    }

    private func startTicking() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - The menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = studio.session.state
        let taking = state.isTaking
        let idle = !state.isBusy

        menu.addItem(heading(for: state))
        menu.addItem(.separator())

        if isBarMinimized {
            menu.addItem(entry("Show Recorder Bar", enabled: true, why: "") { [weak self] in
                self?.actions.showBar()
            })
            menu.addItem(.separator())
        }

        let notReady = "Finish or stop the recording first."
        menu.addItem(entry("Record Screen", enabled: idle, why: notReady) { [weak self] in
            self?.actions.recordScreen()
        })
        menu.addItem(entry("Record Area\u{2026}", enabled: idle, why: notReady) { [weak self] in
            self?.actions.recordArea()
        })
        menu.addItem(entry("Record Window\u{2026}", enabled: idle, why: notReady) { [weak self] in
            self?.actions.recordWindow()
        })
        menu.addItem(.separator())

        let nothing = "Nothing is being recorded."
        menu.addItem(entry(studio.session.isPaused ? "Resume" : "Pause", action: .pause, enabled: taking, why: nothing) {
            [weak self] in self?.actions.perform(.pause)
        })
        if state.isStarting {
            menu.addItem(entry("Cancel Countdown", action: .record, enabled: true, why: "") { [weak self] in
                self?.actions.cancelCountdown()
            })
        } else {
            menu.addItem(entry("Stop", action: .record, enabled: taking, why: nothing) { [weak self] in
                self?.actions.stop()
            })
        }
        menu.addItem(entry(studio.restartPending ? "Confirm Restart" : "Restart",
                           action: .restart, enabled: taking, why: nothing) { [weak self] in
            self?.actions.perform(.restart)
        })
        let markers = studio.session.markerCount
        menu.addItem(entry(markers > 0 ? "Add Marker (\(markers) so far)" : "Add Marker",
                           action: .marker, enabled: taking, why: nothing) { [weak self] in
            self?.actions.perform(.marker)
        })
        menu.addItem(.separator())

        let notes = entry("Speaker Notes", enabled: true, why: "") { [weak self] in self?.actions.toggleNotes() }
        notes.state = preferences.showsSpeakerNotes ? .on : .off
        menu.addItem(notes)
        menu.addItem(entry("Open Recordings", enabled: true, why: "") { [weak self] in self?.actions.showRecordings() })
        menu.addItem(entry("Settings\u{2026}", enabled: true, why: "") { [weak self] in self?.actions.openSettings() })
        menu.addItem(.separator())
        menu.addItem(entry("Quit Klik Studio", enabled: true, why: "") { NSApp.terminate(nil) })
    }

    private func heading(for state: RecordingSession.State) -> NSMenuItem {
        let time = RecorderStatus(state, at: .now).title
        let text = switch state {
        case .recording: "Recording \u{2014} \(time)"
        case .paused: "Paused at \(time)"
        case .countdown(let remaining): "Starting in \(remaining)\u{2026}"
        case .preparing: "Getting ready\u{2026}"
        case .finishing: "Finishing the recording\u{2026}"
        case .idle, .finished, .failed: "Ready to record"
        }
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// One item that runs a closure, shows the action's shortcut, and says why it is off.
    private func entry(_ title: String,
                       action: RecorderAction? = nil,
                       enabled: Bool,
                       why: String,
                       run: @escaping () -> Void) -> NSMenuItem {
        let item = MenuAction.item(title, run: run)
        item.isEnabled = enabled
        if !enabled, !why.isEmpty { item.toolTip = why }
        if let action, preferences.usesGlobalShortcuts, let combo = preferences.shortcuts[action] {
            item.keyEquivalent = combo.menuKeyEquivalent
            item.keyEquivalentModifierMask = combo.menuModifiers
        }
        return item
    }
}

/// What a status menu item runs, so the menu needs no selector per action. Held by the
/// item as its represented object, because a menu item's target is only a weak reference.
final class MenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func fire() { run() }

    static func item(_ title: String, run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}

extension KeyCombo {
    /// The same modifiers as AppKit writes them, for a menu item.
    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if hasControl { flags.insert(.control) }
        if hasOption { flags.insert(.option) }
        if hasShift { flags.insert(.shift) }
        if hasCommand { flags.insert(.command) }
        return flags
    }
}
