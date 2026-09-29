import AppKit
import CoreGraphics
import CoreMedia
import Foundation

/// The host clock, in seconds — the clock frames and telemetry are both stamped in.
func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

/// One thing the scripted hand does, and when.
struct ScriptStep {
    enum Kind {
        /// The pointer goes somewhere, in one event.
        case move(CGPoint)
        case down(CGPoint)
        case up(CGPoint)
        /// A move with the button held.
        case drag(CGPoint)
        case pauseRecording
        case resumeRecording
    }

    /// Seconds after the script starts.
    let at: Double
    let kind: Kind
    /// What this step is part of, for the report: "jump", "sweep", "click".
    let label: String
}

/// What was actually done, and when the host clock said it was done.
struct ScriptEvent {
    let step: ScriptStep
    let hostTime: Double
}

/// A pointer that does exactly what it is told, on a clock that can be compared with the
/// recording's.
///
/// Everything happens inside a *field*: the blank part of the screen the performance is
/// given. Places are fractions of it, so the same performance fits a whole display, a
/// dragged-out area or one window, and what is being measured is the recording rather
/// than the script.
struct MouseScript {
    let field: CGRect

    func place(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: (field.minX + field.width * x).rounded(), y: (field.minY + field.height * y).rounded())
    }

    /// Two places far enough apart that arriving at one cannot be mistaken for the other.
    var a: CGPoint { place(0.2, 0.35) }
    var b: CGPoint { place(0.8, 0.65) }
    /// Used only after the pause, and on no path the pointer takes before it, so arriving
    /// at one says "this is after the pause".
    var c: CGPoint { place(0.45, 0.08) }
    var d: CGPoint { place(0.72, 0.84) }

    /// Where each scripted click lands, in order.
    var clickStill: CGPoint { place(0.3, 0.5) }
    var clickThenFlee: CGPoint { place(0.35, 0.42) }
    var clickAfterPause: CGPoint { place(0.6, 0.5) }

    static let sweepSpeed = 900.0
    static let runSpeed = 1_000.0
    static let pauseLength = 2.0

    /// The whole performance. Every number here is one the analysis relies on.
    func standard(includingPause: Bool) -> [ScriptStep] {
        var steps: [ScriptStep] = []
        steps.append(ScriptStep(at: 0, kind: .move(a), label: "settle"))

        // Jumps: the pointer is in one place and then, in a single event, in another.
        // The first frame that shows it there and the first sample that says it is there
        // are the same moment, so the difference between them is the clock error.
        for index in 0..<6 {
            steps.append(ScriptStep(at: 1.0 + Double(index) * 0.5,
                                    kind: .move(index.isMultiple(of: 2) ? b : a),
                                    label: "jump"))
        }

        // Sweeps: constant speed, so an error in time is an error in place of exactly
        // speed × time, which is what lets a millisecond be measured with a ruler.
        steps.append(ScriptStep(at: 4.5, kind: .move(place(0.06, 0.2)), label: "settle"))
        steps += Self.sweep(from: place(0.06, 0.2), to: place(0.94, 0.2), startingAt: 5.0)
        steps.append(ScriptStep(at: 6.6, kind: .move(place(0.94, 0.93)), label: "settle"))
        steps += Self.sweep(from: place(0.94, 0.93), to: place(0.06, 0.93), startingAt: 7.1)

        // A click standing still.
        steps.append(ScriptStep(at: 8.7, kind: .move(clickStill), label: "settle"))
        steps.append(ScriptStep(at: 9.2, kind: .down(clickStill), label: "click-still"))
        steps.append(ScriptStep(at: 9.25, kind: .up(clickStill), label: "click-still"))

        // A click, and then straight away: a hand that has pressed the button is already
        // on its way somewhere else. If the place of a click is read late, this is where
        // it shows — the click lands wherever the pointer has got to.
        steps.append(ScriptStep(at: 9.7, kind: .move(clickThenFlee), label: "settle"))
        steps.append(ScriptStep(at: 10.2, kind: .down(clickThenFlee), label: "click-flee"))
        steps.append(ScriptStep(at: 10.205, kind: .up(clickThenFlee), label: "click-flee"))
        steps += Self.sweep(from: clickThenFlee,
                            to: CGPoint(x: min(field.maxX - 10, clickThenFlee.x + 500), y: clickThenFlee.y),
                            startingAt: 10.21, speed: 2_500, label: "flee")

        // A click made while moving, the way a drag starts.
        let runStart = place(0.12, 0.62)
        steps.append(ScriptStep(at: 10.9, kind: .move(runStart), label: "settle"))
        let rate = 240.0
        let pressAt = 0.3, releaseAt = 0.34
        let runLength = min(0.7, Double(field.maxX - 10 - runStart.x) / Self.runSpeed)
        var tick = 0
        while Double(tick) / rate <= runLength {
            let elapsed = Double(tick) / rate
            let point = CGPoint(x: runStart.x + Self.runSpeed * elapsed, y: runStart.y)
            let held = elapsed > pressAt && elapsed < releaseAt
            steps.append(ScriptStep(at: 11.4 + elapsed, kind: held ? .drag(point) : .move(point), label: "run"))
            tick += 1
        }
        steps.append(ScriptStep(at: 11.4 + pressAt,
                                kind: .down(CGPoint(x: runStart.x + Self.runSpeed * pressAt, y: runStart.y)),
                                label: "click-moving"))
        steps.append(ScriptStep(at: 11.4 + releaseAt,
                                kind: .up(CGPoint(x: runStart.x + Self.runSpeed * releaseAt, y: runStart.y)),
                                label: "click-moving"))

        guard includingPause else {
            return steps.sorted { $0.at < $1.at }
        }

        // A hold, and then the same questions asked again. Whatever time the pause took
        // out of the picture has to come out of the pointer's clock too.
        steps.append(ScriptStep(at: 12.7, kind: .pauseRecording, label: "pause"))
        steps.append(ScriptStep(at: 12.7 + Self.pauseLength, kind: .resumeRecording, label: "resume"))
        let after = 12.7 + Self.pauseLength
        steps.append(ScriptStep(at: after + 0.6, kind: .move(c), label: "jump-after-pause"))
        steps.append(ScriptStep(at: after + 1.1, kind: .move(d), label: "jump-after-pause"))
        steps.append(ScriptStep(at: after + 1.6, kind: .move(c), label: "jump-after-pause"))
        steps.append(ScriptStep(at: after + 2.1, kind: .move(clickAfterPause), label: "settle"))
        steps.append(ScriptStep(at: after + 2.6, kind: .down(clickAfterPause), label: "click-after-pause"))
        steps.append(ScriptStep(at: after + 2.65, kind: .up(clickAfterPause), label: "click-after-pause"))
        return steps.sorted { $0.at < $1.at }
    }

    static func sweep(from start: CGPoint, to end: CGPoint, startingAt: Double,
                      speed: Double = sweepSpeed, label: String = "sweep") -> [ScriptStep] {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let length = distance / speed
        let rate = 240.0
        var steps: [ScriptStep] = []
        var tick = 0
        while Double(tick) / rate <= length {
            let progress = (Double(tick) / rate) / length
            steps.append(ScriptStep(at: startingAt + Double(tick) / rate,
                                    kind: .move(CGPoint(x: start.x + (end.x - start.x) * progress,
                                                        y: start.y + (end.y - start.y) * progress)),
                                    label: label))
            tick += 1
        }
        steps.append(ScriptStep(at: startingAt + length, kind: .move(end), label: label))
        return steps
    }

    /// Performs the steps on the calling thread, which must not be the main one: the
    /// recording's own main-thread work has to keep running while this sleeps.
    static func perform(_ steps: [ScriptStep],
                        pause: @escaping () -> Void,
                        resume: @escaping () -> Void) -> [ScriptEvent] {
        let source = CGEventSource(stateID: .hidSystemState)
        let began = hostNow()
        var events: [ScriptEvent] = []
        events.reserveCapacity(steps.count)

        for step in steps {
            wait(until: began + step.at)
            switch step.kind {
            case .move(let point):
                post(.mouseMoved, at: point, source: source)
            case .drag(let point):
                post(.leftMouseDragged, at: point, source: source)
            case .down(let point):
                post(.leftMouseDown, at: point, source: source)
            case .up(let point):
                post(.leftMouseUp, at: point, source: source)
            case .pauseRecording:
                DispatchQueue.main.sync(execute: pause)
            case .resumeRecording:
                DispatchQueue.main.sync(execute: resume)
            }
            events.append(ScriptEvent(step: step, hostTime: hostNow()))
        }
        return events
    }

    private static func post(_ type: CGEventType, at point: CGPoint, source: CGEventSource?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        if type == .leftMouseDown || type == .leftMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }

    /// Sleeps most of the way and spins the rest, because a sleep alone is late by
    /// however long the scheduler likes and this is a measurement of milliseconds.
    private static func wait(until deadline: Double) {
        while true {
            let remaining = deadline - hostNow()
            if remaining <= 0 { return }
            if remaining > 0.003 {
                Thread.sleep(forTimeInterval: remaining - 0.002)
            }
        }
    }
}
