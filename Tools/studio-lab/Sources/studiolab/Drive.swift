import AppKit
import ApplicationServices
import Foundation

/// Operating an app by what its controls are called, not by where they are.
///
/// A click at a point on the screen lands on whatever is at that point — and on a Mac
/// somebody is using, that stops being the app under test the moment they switch to
/// something else. Everything here talks to one process through Accessibility instead: it
/// presses *that app's* button, types into *that app's* field, and photographs *that
/// app's* window, wherever the pointer is and whatever is in front.
///
/// `studiolab tree <app>` — what the app's windows contain.
/// `studiolab press <app> <label>` — press the control called that.
/// `studiolab set <app> <label> <value>` — set a field or a slider.
/// `studiolab key <app> <keycode> [cmd] [shift] [opt] [ctrl]` — a keystroke, to that app only.
/// `studiolab shot <app> <file.png> [title]` — a picture of its window.
/// `studiolab windows <app>` — its windows and where they are.
@MainActor
enum Drive {
    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 2 else { return usage() }
        let command = arguments[0]
        guard let app = application(named: arguments[1]) else {
            print("\(arguments[1]) is not running")
            return 1
        }
        guard AXIsProcessTrusted() else {
            print("Accessibility is not granted to this terminal")
            return 1
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let rest = Array(arguments.dropFirst(2))

        switch command {
        case "tree":
            let depth = rest.first.flatMap(Int.init) ?? 40
            for window in windows(of: element) {
                describe(window, depth: 0, limit: depth)
            }
            return 0

        case "menus":
            guard let bar: AXUIElement = attribute(kAXMenuBarAttribute as String, of: element) else { return 1 }
            for menu in children(of: bar) {
                let title: String = attribute(kAXTitleAttribute as String, of: menu) ?? ""
                guard title != "Apple" else { continue }
                print(title)
                for holder in children(of: menu) {
                    for item in children(of: holder) {
                        let name: String = attribute(kAXTitleAttribute as String, of: item) ?? ""
                        guard !name.isEmpty else { continue }
                        let enabled: Bool = attribute(kAXEnabledAttribute as String, of: item) ?? true
                        let key: String = attribute(kAXMenuItemCmdCharAttribute as String, of: item) ?? ""
                        print("   \(name)\(key.isEmpty ? "" : "  [\(key)]")\(enabled ? "" : "  (disabled)")")
                    }
                }
            }
            return 0

        case "press":
            // The name exactly, unless it is given with a leading "~": a name that merely
            // contains the word is how "Pointer" came to press "Hide Pointer over
            // Selection".
            guard var label = rest.first else { return usage() }
            let loose = label.hasPrefix("~")
            if loose { label.removeFirst() }
            let index = rest.dropFirst().first.flatMap(Int.init) ?? 0
            // Never a title in the menu bar itself. Pressing one opens its menu, on
            // screen, over whatever the person at the Mac is doing — and a menu and a
            // command often share a name: "Captions" is both a menu and a tool.
            let matches = find(label, in: element, exactly: !loose) {
                let role: String = attribute(kAXRoleAttribute as String, of: $0) ?? ""
                return role != (kAXMenuBarItemRole as String)
                    && actions(of: $0).contains(kAXPressAction as String)
            }
            guard index < matches.count else {
                print("nothing to press called \"\(label)\" (\(matches.count) found)")
                return 1
            }
            let result = AXUIElementPerformAction(matches[index], kAXPressAction as CFString)
            print(result == .success ? "pressed \(summary(of: matches[index]))" : "could not press: \(result.rawValue)")
            return result == .success ? 0 : 1

        case "set":
            guard rest.count >= 2 else { return usage() }
            let matches = find(rest[0], in: element, exactly: false) { isSettable($0) }
            guard let target = matches.first else {
                print("nothing to set called \"\(rest[0])\"")
                return 1
            }
            let value: CFTypeRef = Double(rest[1]).map { $0 as CFNumber } ?? rest[1] as CFString
            let result = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, value)
            print(result == .success ? "set \(summary(of: target))" : "could not set: \(result.rawValue)")
            return result == .success ? 0 : 1

        case "resize":
            // `studiolab resize <app> <width> <height>`: the app's first titled window, by
            // Accessibility, so a layout can be checked at a size without touching the screen.
            guard rest.count >= 2, let width = Double(rest[0]), let height = Double(rest[1]) else { return usage() }
            var windows: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
            guard let window = (windows as? [AXUIElement])?.first(where: { window in
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                return !((title as? String) ?? "").isEmpty
            }) else {
                print("no titled window")
                return 1
            }
            var size = CGSize(width: width, height: height)
            let value = AXValueCreate(.cgSize, &size)!
            let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
            print(result == .success ? "resized to \(Int(width)) × \(Int(height))" : "could not resize: \(result.rawValue)")
            return result == .success ? 0 : 1

        case "key":
            guard let code = rest.first.flatMap(UInt16.init) else { return usage() }
            var flags: CGEventFlags = []
            for name in rest.dropFirst() {
                switch name {
                case "cmd": flags.insert(.maskCommand)
                case "shift": flags.insert(.maskShift)
                case "opt": flags.insert(.maskAlternate)
                case "ctrl": flags.insert(.maskControl)
                default: break
                }
            }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                event?.flags = flags
                // To the process, not to the screen: whatever is in front does not hear it.
                event?.postToPid(app.processIdentifier)
                usleep(30_000)
            }
            return 0

        case "windows":
            for entry in windowList(of: app.processIdentifier) {
                print(entry.id, "layer \(entry.layer)", entry.bounds, entry.title, entry.onScreen ? "" : "(not on screen)")
            }
            return 0

        case "shot":
            guard let path = rest.first else { return usage() }
            let wanted = rest.dropFirst().first
            let candidates = windowList(of: app.processIdentifier)
                .filter { $0.bounds.width > 80 && $0.bounds.height > 60 }
                .filter { entry in wanted.map { entry.title.localizedCaseInsensitiveContains($0) } ?? true }
                // The biggest one is the one that was meant, unless a title was given.
                .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
            guard let window = candidates.first else {
                print("\(arguments[1]) has no window to photograph")
                return 1
            }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.id), path]
            try? capture.run()
            capture.waitUntilExit()
            print(capture.terminationStatus == 0 ? "\(path) (\(window.title), \(Int(window.bounds.width))×\(Int(window.bounds.height)))" : "could not photograph the window")
            return capture.terminationStatus

        default:
            return usage()
        }
    }

    private static func usage() -> Int32 {
        print("usage: studiolab tree|press|set|key|shot|windows <app> …")
        return 2
    }

    // MARK: - Finding things

    private static func application(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName == name || $0.bundleIdentifier == name
        }
    }

    private static func attribute<Value>(_ name: String, of element: AXUIElement) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Value
    }

    private static func windows(of application: AXUIElement) -> [AXUIElement] {
        attribute(kAXWindowsAttribute as String, of: application) ?? []
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute as String, of: element) ?? []
    }

    private static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func isSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    /// Everything a control might be known by.
    private static func names(of element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
         kAXIdentifierAttribute, kAXValueAttribute, kAXRoleDescriptionAttribute]
            .compactMap { attribute($0 as String, of: element) as String? }
            .filter { !$0.isEmpty }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(kAXPositionAttribute as String, of: element),
              let size: AXValue = attribute(kAXSizeAttribute as String, of: element) else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    private static func summary(of element: AXUIElement) -> String {
        let role: String = attribute(kAXRoleAttribute as String, of: element) ?? "?"
        let names = names(of: element).prefix(3).joined(separator: " | ")
        let place = frame(of: element).map { " @\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? ""
        return "\(role) \"\(names)\"\(place)"
    }

    /// Controls that answer to a name, exact matches first.
    private static func find(_ label: String,
                             in application: AXUIElement,
                             exactly: Bool,
                             where accept: (AXUIElement) -> Bool) -> [AXUIElement] {
        var exact: [AXUIElement] = []
        var partial: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 60 else { return }
            let names = names(of: element)
            if accept(element) {
                if names.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
                    exact.append(element)
                } else if names.contains(where: { $0.localizedCaseInsensitiveContains(label) }) {
                    partial.append(element)
                }
            }
            for child in children(of: element) { walk(child, depth: depth + 1) }
        }
        for window in windows(of: application) { walk(window, depth: 0) }
        // The menu bar as well: most of what an editor can do is only there.
        if let menus: AXUIElement = attribute(kAXMenuBarAttribute as String, of: application) {
            walk(menus, depth: 0)
        }
        return exactly ? exact : exact + partial
    }

    private static func describe(_ element: AXUIElement, depth: Int, limit: Int) {
        guard depth < limit else { return }
        let role: String = attribute(kAXRoleAttribute as String, of: element) ?? "?"
        let names = names(of: element)
        let acts = actions(of: element).filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" }
        // Groups with nothing to say for themselves are scaffolding, and printing them
        // buries the controls.
        if !(role == "AXGroup" && names.isEmpty && acts.isEmpty) || depth == 0 {
            let place = frame(of: element).map { " @\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? ""
            print(String(repeating: "  ", count: min(depth, 12))
                  + "\(role) \(names.prefix(3).map { "\"\($0.prefix(60))\"" }.joined(separator: " "))"
                  + (acts.isEmpty ? "" : " [\(acts.joined(separator: ","))]") + place)
        }
        for child in children(of: element) { describe(child, depth: depth + 1, limit: limit) }
    }

    // MARK: - Windows, as the window server sees them

    private struct WindowEntry {
        let id: CGWindowID
        let layer: Int
        let bounds: CGRect
        let title: String
        let onScreen: Bool
    }

    private static func windowList(of process: pid_t) -> [WindowEntry] {
        guard let listing = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return listing.compactMap { entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner == process,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = (entry[kCGWindowBounds as String] as? [String: Any])
                      .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { return nil }
            return WindowEntry(id: id,
                               layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                               bounds: bounds,
                               title: entry[kCGWindowName as String] as? String ?? "",
                               onScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }
}
