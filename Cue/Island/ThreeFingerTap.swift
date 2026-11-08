import AppKit

/// A three-finger tap on the trackpad, anywhere, as a way to open the quick wheel.
///
/// Two things can tell Cue about it, and it listens for both:
///
/// * `NSEventTypeQuickLook` — the tap as macOS itself recognises it, which it sends
///   only when System Settings › Trackpad › "Look up & data detectors" is set to
///   "Tap with three fingers". Where that holds this is exact, and the event is
///   swallowed so the dictionary pop-over doesn't open behind the wheel.
/// * `NSEventTypeGesture` — the touches themselves, read by `Tap` below. This is what
///   carries the gesture when that setting is off (`TrackpadThreeFingerTapGesture = 0`),
///   which is far from rare: nothing else on the machine emits the QuickLook event then.
///
/// An active event tap, so it needs Accessibility; without it `start` returns false
/// and nothing else in Cue is affected. `GestureProbe` writes out what the trackpad
/// actually sends, which is how the rules in `Tap` were arrived at.
@MainActor
final class ThreeFingerTap {
    /// NSEventType values that have no `CGEventType` of their own.
    nonisolated private static let gestureType = CGEventType(rawValue: 29)!
    nonisolated private static let quickLookType = CGEventType(rawValue: 33)!
    /// Two reports of one tap (both sources, or a stray repeat) count once.
    nonisolated private static let debounce: TimeInterval = 0.4

    nonisolated(unsafe) private static var tap: CFMachPort?
    nonisolated(unsafe) private static var onTap: (@MainActor () -> Void)?
    nonisolated(unsafe) private static var lastFired: TimeInterval = 0
    nonisolated(unsafe) private static var watcher = Tap()
    /// Off until Settings asks for it; the tap stays in place either way.
    nonisolated(unsafe) static var active = false

    /// Starts the tap. Returns false when it can't (no Accessibility).
    @discardableResult
    static func start(onTap handler: @escaping @MainActor () -> Void) -> Bool {
        guard tap == nil else { onTap = handler; return true }
        onTap = handler
        let mask = CGEventMask(1 << gestureType.rawValue) | CGEventMask(1 << quickLookType.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
            ThreeFingerTap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return false }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// Runs on the main thread (the tap's source is on the main run loop). Returns
    /// true to swallow the event, which only happens for the Look up gesture Cue has
    /// taken over, and only while it is on.
    nonisolated private static func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case quickLookType:
            guard active else { return false }
            fire()
            return true
        case gestureType:
            guard active, let nsEvent = NSEvent(cgEvent: event) else { return false }
            if watcher.saw(nsEvent.allTouches(), at: nsEvent.timestamp) { fire() }
            return false
        default:
            return false
        }
    }

    nonisolated private static func fire() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFired > debounce else { return }
        lastFired = now
        DispatchQueue.main.async { MainActor.assumeIsolated { onTap?() } }
    }

    /// Picks a three-finger tap out of the stream of touches.
    ///
    /// An earlier try at this opened the wheel by itself, because it fired whenever
    /// *a* touch ended while three had been down — and in the middle of a scroll or a
    /// swipe there is always such a moment. The rules here are what the trackpad's own
    /// events (see `GestureProbe`) say a tap looks like and the other gestures do not:
    ///
    /// * exactly three fingers, never a fourth at any point;
    /// * all three landing together, within `together` of each other — which is what
    ///   separates a tap from two fingers arriving beside one already resting;
    /// * none of them travelling more than `travel` across the trackpad;
    /// * all three gone again within `hold` of landing.
    ///
    /// Anything else blocks the gesture until every finger is off the trackpad, so a
    /// long drag can never end in an accidental tap.
    nonisolated struct Tap {
        /// How far apart the three landings may be, and how long the tap may last.
        static let together: TimeInterval = 0.2
        static let hold: TimeInterval = 0.4
        /// How far a finger may travel, in the trackpad's own 0...1 across and up.
        static let travel: CGFloat = 0.05

        private var landed: [Int: (at: TimeInterval, place: CGPoint)] = [:]
        private var lifted: Set<Int> = []
        /// Set when this cannot be a tap any more; cleared when the hand comes off.
        private var blocked = false

        /// Takes one gesture event's touches. True when they completed a tap.
        mutating func saw(_ touches: Set<NSTouch>, at now: TimeInterval) -> Bool {
            guard !touches.isEmpty else { reset(); return false }
            let down = touches.filter { $0.phase != .ended && $0.phase != .cancelled }
            // What landed and what left is written down first, so three fingers
            // leaving in the one event still count as having left.
            if !blocked {
                if touches.count > 3 {
                    // A fourth finger is some other gesture, and ends this one for good.
                    blocked = true
                } else {
                    for touch in touches where touch.phase == .began {
                        landed[touch.identity.hash] = (now, CGPoint(x: touch.normalizedPosition.x, y: touch.normalizedPosition.y))
                    }
                    for touch in touches where touch.phase == .ended || touch.phase == .cancelled {
                        lifted.insert(touch.identity.hash)
                    }
                    for touch in down {
                        // A finger already down before Cue was watching: not a landing
                        // it saw, so not a tap it can vouch for.
                        guard let start = landed[touch.identity.hash] else { blocked = true; break }
                        let moved = hypot(touch.normalizedPosition.x - start.place.x, touch.normalizedPosition.y - start.place.y)
                        if moved > Self.travel || now - start.at > Self.hold { blocked = true; break }
                    }
                }
            }
            let tapped = !blocked && complete(touches, at: now)
            // A tap is finished with, and so is anything that ends with the hand off
            // the trackpad: either way the next gesture starts from nothing.
            if tapped || down.isEmpty { reset() }
            return tapped
        }

        /// Three fingers that landed together, went nowhere, and have all left.
        private func complete(_ touches: Set<NSTouch>, at now: TimeInterval) -> Bool {
            guard landed.count == 3, lifted.count == 3 else { return false }
            let times = landed.values.map(\.at)
            guard let first = times.min(), let last = times.max() else { return false }
            guard last - first <= Self.together, now - first <= Self.hold else { return false }
            // Whichever of them this event still carries; the rest were watched on
            // their way out, in the events before this one.
            for touch in touches {
                guard let start = landed[touch.identity.hash] else { return false }
                let moved = hypot(touch.normalizedPosition.x - start.place.x, touch.normalizedPosition.y - start.place.y)
                guard moved <= Self.travel else { return false }
            }
            return true
        }

        private mutating func reset() {
            landed.removeAll()
            lifted.removeAll()
            blocked = false
        }
    }
}
