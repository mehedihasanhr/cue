import AppKit
import CoreMedia
import TimelineKit

/// Being tested without being in the way.
///
/// The app is operated by a tool while somebody is using the Mac for something else. An
/// editor that comes to the front every time a recording is opened is right for a person
/// who asked for it and wrong for a test that did not: it pulls them out of whatever they
/// were doing. With `KLIK_STUDIO_QUIET` set, windows open behind everything and the app
/// does not make itself active.
///
/// Debug builds only. A shipped app has no such switch to find.
enum StudioAutomation {
    static let isQuiet: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["KLIK_STUDIO_QUIET"] != nil
        #else
        false
        #endif
    }()

    /// Puts the app in the appearance a test asked for, for this process only.
    ///
    /// Both appearances have to be looked at, and the only other way to see the second
    /// one is to change the whole Mac's, under the person using it.
    @MainActor
    static func applyAppearance() {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["KLIK_STUDIO_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #endif
    }

    /// The Recordings layout a test asked for — `grid` or `list` — for this process only,
    /// because a tool cannot press a segment it cannot see and the preference lives in the
    /// app's own container.
    static var libraryLayout: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["KLIK_STUDIO_LIBRARY_LAYOUT"]
        #else
        nil
        #endif
    }

    /// Shows a window the way the moment calls for: in front and active for a person,
    /// behind everything and inactive for a test.
    @MainActor
    static func present(_ controller: NSWindowController) {
        if isQuiet {
            controller.window?.orderBack(nil)
        } else {
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - A pointer, for a test

    /// Mouse and key events from `studiolab`, played into the app's own window.
    ///
    /// Posted events reach a window only on the Space somebody is looking at, and a quiet
    /// test's window is deliberately not there — so a click on the canvas could not be
    /// tested at all, and "clicking a shape does nothing" could only be guessed at. Handed
    /// straight to `NSWindow.sendEvent`, the events go through the window's own hit
    /// testing and gestures exactly as a hand's would, wherever the window is.
    ///
    /// The script, on the `com.klik.studio.lab` pasteboard, is lines of `down x y`, `drag x y`, `up x y`, `click x y` and
    /// `key <characters> [cmd] [shift]`, in the window's points from its top left. Quiet
    /// debug builds only.
    @MainActor
    static func listenForPointer() {
        #if DEBUG
        guard isQuiet else { return }
        let name = Notification.Name("com.klik.studio.lab.events")
        // The script is on a pasteboard of its own — never the clipboard — because a
        // sandboxed app is handed a distributed notification without anything attached to
        // it, and cannot read a file another process wrote.
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { _ in
            let board = NSPasteboard(name: NSPasteboard.Name("com.klik.studio.lab"))
            guard let script = board.string(forType: .string) else { return }
            board.clearContents()
            Task { @MainActor in
                // What happened, back on the same board, for the test to read.
                var report = await play(script)
                try? await Task.sleep(for: .milliseconds(300))
                if let model = StudioAppDelegate.shared?.editors.current?.session.model {
                    report += "\nstate tool=\(model.tool) selection=\(model.selection) playhead=\(model.playhead.seconds)"
                        + " drawing=\(String(describing: model.drawingAnnotation)) editing=\(String(describing: model.editingAnnotation))"
                        + " annotations=\(model.timeline.annotations.map { "\($0.kind.label)@\($0.id.uuidString.prefix(4))" })"
                }
                board.clearContents()
                board.setString("done\n" + report, forType: .string)
            }
        }
        #endif
    }

    #if DEBUG
    @MainActor private static var acceptingFirstMouse: Set<ObjectIdentifier> = []

    @MainActor
    private static func acceptFirstMouse(in viewClass: AnyClass) {
        guard acceptingFirstMouse.insert(ObjectIdentifier(viewClass)).inserted else { return }
        let selector = #selector(NSView.acceptsFirstMouse(for:))
        let yes: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        let implementation = imp_implementationWithBlock(yes)
        if let method = class_getInstanceMethod(viewClass, selector),
           !class_addMethod(viewClass, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }

    @MainActor
    @discardableResult
    private static func play(_ script: String) async -> String {
        // `window <words in its title>` as the first line picks the window; otherwise the
        // biggest, which is the editor.
        var lines = script.split(whereSeparator: \.isNewline).map(String.init)
        var titled: String?
        if let first = lines.first, first.hasPrefix("window ") {
            titled = String(first.dropFirst(7))
            lines.removeFirst()
        }
        guard let window = NSApp.windows
            .filter({ $0.contentView != nil && $0.frame.width > 400 && $0.isVisible })
            .filter({ titled == nil || $0.title.contains(titled!) })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return "no window" }
        var report = "window \(window.title) \(window.frame) content \(window.contentView?.frame ?? .zero)"
            + " key=\(window.isKeyWindow) active=\(NSApp.isActive)"
        // A quiet test's app is never active, and a click on an inactive app's window only
        // brings it forward — so the window's views are told to take the first click, as
        // they would once a person had clicked the app to the front.
        if let view = window.contentView { acceptFirstMouse(in: type(of: view)) }
        let height = window.contentView?.frame.height ?? window.frame.height
        // Key, without coming forward or the app becoming active: a click on a window that
        // is not key is taken as "bring this window to me", and never reaches the view.
        window.makeKey()
        var pressed = false
        for line in lines {
            let parts = line.split(separator: " ").map(String.init)
            guard let verb = parts.first else { continue }
            if verb == "key", parts.count > 1 {
                var flags: NSEvent.ModifierFlags = []
                if parts.contains("cmd") { flags.insert(.command) }
                if parts.contains("shift") { flags.insert(.shift) }
                let named: [String: (String, UInt16)] = ["esc": ("\u{1b}", 53), "return": ("\r", 36),
                                                         "backspace": ("\u{7f}", 51), "tab": ("\t", 48),
                                                         "space": (" ", 49)]
                let characters = named[parts[1]]?.0 ?? parts[1]
                let code: UInt16 = named[parts[1]]?.1 ?? 0
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: characters, charactersIgnoringModifiers: characters,
                                                    isARepeat: false, keyCode: code) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try? await Task.sleep(for: .milliseconds(30))
                continue
            }
            // `play`: starts or stops playback, as the space bar would — which a window in
            // the background never receives.
            if verb == "play" {
                StudioAppDelegate.shared?.editors.current?.session.model?.togglePlayback()
                continue
            }
            if verb == "wait", parts.count > 1, let ms = Int(parts[1]) {
                try? await Task.sleep(for: .milliseconds(ms))
                continue
            }
            guard parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) else { continue }
            let point = NSPoint(x: x, y: height - y)
            if let hit = window.contentView?.hitTest(point) {
                report += "\n\(verb) \(x),\(y) hits \(type(of: hit))"
            }
            func send(_ type: NSEvent.EventType) {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1,
                                                     pressure: type == .leftMouseUp ? 0 : 1) else { return }
                // Through the app's own queue, as an event from the window server arrives —
                // SwiftUI's gestures did not see one handed straight to the window.
                NSApp.postEvent(event, atStart: false)
            }
            switch verb {
            case "down": send(.leftMouseDown); pressed = true
            case "drag": send(pressed ? .leftMouseDragged : .mouseMoved)
            case "up": send(.leftMouseUp); pressed = false
            case "move": send(.mouseMoved)
            case "click":
                send(.leftMouseDown)
                try? await Task.sleep(for: .milliseconds(40))
                send(.leftMouseUp)
            default: break
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return report
    }
    #endif
}
