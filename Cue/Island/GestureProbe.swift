import AppKit

/// Diagnostics: what the trackpad actually sends, so a gesture Cue wants to read can
/// be found rather than guessed at. `--env CUE_DEBUG_GESTURE=1` writes every event it
/// sees to Pictures/Cue/_gesture.txt, with its type, its touches and their phases.
///
/// Not part of the app: nothing calls it unless that variable is set.
enum GestureProbe {
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var tap: CFMachPort?

    /// Every event type a trackpad gesture might arrive as, by NSEventType raw value.
    nonisolated private static let types: [(UInt32, String)] = [
        (18, "rotate"), (19, "beginGesture"), (20, "endGesture"), (29, "gesture"),
        (30, "magnify"), (31, "swipe"), (32, "smartMagnify"), (33, "quickLook"),
        (34, "pressure"),
    ]

    static func run() {
        file = CaptureLibrary.defaultFolder().appendingPathComponent("_gesture.txt")
        let trusted = AXIsProcessTrusted()
        note("accessibility trusted: \(trusted)")
        var mask: CGEventMask = 0
        for (raw, _) in types { mask |= CGEventMask(1 << raw) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
            GestureProbe.saw(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else {
            note("tapCreate FAILED (no Accessibility for this build?)")
            flush()
            return
        }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        note("tap running — tap three fingers on the trackpad now")
        flush()
    }

    nonisolated private static func saw(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return note("tap re-enabled", flushNow: true)
        }
        let name = types.first { $0.0 == type.rawValue }?.1 ?? "raw"
        var line = "\(name)(\(type.rawValue))"
        if let nsEvent = NSEvent(cgEvent: event) {
            let touches = nsEvent.allTouches()
            if !touches.isEmpty {
                let phases = touches.map { touch -> String in
                    switch touch.phase {
                    case .began: "began"
                    case .moved: "moved"
                    case .stationary: "still"
                    case .ended: "ended"
                    case .cancelled: "cancelled"
                    default: "?"
                    }
                }
                line += " touches=\(touches.count) [\(phases.sorted().joined(separator: ","))]"
            }
        }
        note(line, flushNow: true)
    }

    nonisolated private static func note(_ line: String, flushNow: Bool = false) {
        lines.append("\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime))  \(line)")
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        if flushNow { flush() }
    }

    /// Worked out once on the main actor, so the tap's callback can write without it.
    nonisolated(unsafe) private static var file: URL?

    nonisolated private static func flush() {
        guard let file else { return }
        try? lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
