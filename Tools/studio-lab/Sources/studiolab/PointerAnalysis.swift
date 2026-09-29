import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import RenderKit
import TimelineKit

/// What the script did, as it is kept beside the recording so the analysis can be run
/// again without making the recording again.
struct ScriptRecord: Codable {
    let label: String
    let kind: String
    let x: Double
    let y: Double
    let at: Double
    let hostTime: Double

    init(_ event: ScriptEvent) {
        label = event.step.label
        at = event.step.at
        hostTime = event.hostTime
        switch event.step.kind {
        case .move(let point): kind = "move"; x = point.x; y = point.y
        case .drag(let point): kind = "drag"; x = point.x; y = point.y
        case .down(let point): kind = "down"; x = point.x; y = point.y
        case .up(let point): kind = "up"; x = point.x; y = point.y
        case .pauseRecording: kind = "pause"; x = 0; y = 0
        case .resumeRecording: kind = "resume"; x = 0; y = 0
        }
    }

    var point: CGPoint { CGPoint(x: x, y: y) }

    init(label: String, kind: String, x: Double, y: Double, at: Double, hostTime: Double) {
        self.label = label
        self.kind = kind
        self.x = x
        self.y = y
        self.at = at
        self.hostTime = hostTime
    }

    func moved(by offset: CGPoint) -> ScriptRecord {
        ScriptRecord(label: label, kind: kind, x: x + offset.x, y: y + offset.y, at: at, hostTime: hostTime)
    }
}

/// One thing that was measured, and whether it is good enough.
struct Finding {
    let name: String
    let value: String
    let passed: Bool
    let note: String
}

/// Compares what the recording wrote down with what is in its picture.
@MainActor
enum PointerAnalysis {
    /// The blank part of the picture, in recorded points, a little inside the field so
    /// the stage's own edges are never mistaken for a pointer.
    static func region(for probe: ProbeScript) -> CGRect {
        probe.fieldRect.offsetBy(dx: -probe.originPoint.x, dy: -probe.originPoint.y).insetBy(dx: -12, dy: -12)
    }

    static func run(package url: URL, script probe: ProbeScript) async throws -> [Finding] {
        // Everything the script did, moved into the recording's own coordinates: the
        // place the pointer *should* have been written down as being.
        let origin = probe.originPoint
        let script = probe.events.map { $0.moved(by: CGPoint(x: -origin.x, y: -origin.y)) }
        let package = RecordingPackage(url: url)
        let document = try EditorDocument(package: package)
        let manifest = document.manifest
        guard let videoURL = document.videoURL else {
            return [Finding(name: "video", value: "missing", passed: false, note: "the package has no screen.mov")]
        }

        let region = Self.region(for: probe)
        let frames = try await FrameScan.observations(of: videoURL, scale: manifest.displayScale, region: region)
        let track = document.cursorTrack
        var findings: [Finding] = []

        let seen = frames.filter { $0.tip != nil }.count
        findings.append(Finding(name: "frames",
                                value: "\(frames.count) read, pointer found in \(seen)",
                                passed: seen > frames.count / 2,
                                note: "first frame at \(format(frames.first?.time ?? -1))s, last at \(format(frames.last?.time ?? -1))s; manifest says \(format(manifest.duration))s"))
        findings.append(Finding(name: "telemetry",
                                value: "\(track.samples.count) samples, \(track.clicks.count) clicks",
                                passed: !track.samples.isEmpty,
                                note: "first sample at \(format(track.samples.first?.t ?? -1))s, last at \(format(track.samples.last?.t ?? -1))s"))
        guard seen > 10, !track.samples.isEmpty else { return findings }

        // MARK: Jumps, and the mapping from the script's clock to the file's

        findings.append(Finding(name: "target",
                                value: "\(probe.target), recorded from (\(format(origin.x)), \(format(origin.y)))",
                                passed: true,
                                note: "picture \(Int(manifest.track(.screen)?.pixelSize?.width ?? 0)) × \(Int(manifest.track(.screen)?.pixelSize?.height ?? 0)) px at \(format(manifest.displayScale))x; pointer moved \(format((manifest.telemetry.pointerLatency ?? 0) * 1_000)) ms to meet the picture"))

        let jumps = script.filter { $0.label == "jump" && $0.kind == "move" }
        let laterJumps = script.filter { $0.label == "jump-after-pause" && $0.kind == "move" }

        // First without knowing how far inside its hotspot the pointer's fill starts, then
        // again once that is known.
        var inset = CGPoint.zero
        var seenArrivals = arrivals(at: jumps.map(\.point), in: frames.compactMap { frame in
            frame.tip.map { (frame.time, $0) }
        }, tolerance: 8)
        inset = calibration(frames: frames, track: track, before: seenArrivals.compactMap { $0 }) ?? .zero
        let real: [(time: Double, point: CGPoint)] = frames.compactMap { frame in
            frame.tip.map { (frame.time, CGPoint(x: $0.x - inset.x, y: $0.y - inset.y)) }
        }
        seenArrivals = arrivals(at: jumps.map(\.point), in: real, tolerance: 4)
        let writtenArrivals = arrivals(at: jumps.map(\.point),
                                       in: track.samples.map { ($0.t, $0.point) }, tolerance: 4)

        findings.append(Finding(name: "pointer artwork inset",
                                value: "(\(format(inset.x)), \(format(inset.y))) pt",
                                passed: abs(inset.x) < 6 && abs(inset.y) < 6,
                                note: "how far inside its hotspot the pointer's dark fill starts; taken off every reading below"))

        let jumpDifferences = zip(writtenArrivals, seenArrivals).compactMap { written, seen -> Double? in
            guard let written, let seen else { return nil }
            return written - seen
        }
        if !jumpDifferences.isEmpty {
            let mean = jumpDifferences.reduce(0, +) / Double(jumpDifferences.count)
            findings.append(Finding(name: "jumps: sample vs picture",
                                    value: "\(milliseconds(mean)) mean over \(jumpDifferences.count)",
                                    // A frame is 16.7 ms and a sample 8.3, so this reading
                                    // alone is only good to about a frame.
                                    passed: abs(mean) < 0.020,
                                    note: "each: " + jumpDifferences.map(milliseconds).joined(separator: ", ")))
        } else {
            findings.append(Finding(name: "jumps: sample vs picture", value: "none matched", passed: false,
                                    note: "picture \(seenArrivals), samples \(writtenArrivals)"))
        }

        // Host time to file time, from the jumps the picture shows.
        let hostOffsets = zip(jumps, seenArrivals).compactMap { jump, seen in seen.map { $0 - jump.hostTime } }
        guard let hostOffset = median(hostOffsets) else { return findings }

        // MARK: Sweeps — the fine reading

        let sweeps = script.filter { $0.label == "sweep" }
        if let lag = sweepLag(sweeps: sweeps, hostOffset: hostOffset, real: real, track: track) {
            let drift = abs(lag.seconds) * MouseScript.sweepSpeed
            findings.append(Finding(name: "clock: pointer vs picture",
                                    value: milliseconds(lag.seconds),
                                    passed: abs(lag.seconds) <= 0.008,
                                    note: "negative means the pointer is drawn ahead of the picture; at \(Int(MouseScript.sweepSpeed)) pt/s that is \(format(drift)) pt out of place (fit residual \(format(lag.residual)) pt over \(lag.frames) frames)"))
        }

        // MARK: Clicks

        let pressed = script.filter { $0.kind == "down" }
        let earlier = pressed.filter { $0.label != "click-after-pause" }
        for (index, press) in earlier.enumerated() {
            guard index < track.clicks.count else {
                findings.append(Finding(name: "click \(index + 1) (\(press.label))", value: "not recorded",
                                        passed: false, note: "the script pressed the button and no mouseDown was written"))
                continue
            }
            findings += clickFindings(index: index, press: press, click: track.clicks[index],
                                      expected: press.hostTime + hostOffset, real: real)
        }

        // MARK: After the pause

        if !laterJumps.isEmpty {
            // Only what came after the last click before the hold: the places used after
            // the pause are on no earlier path, and this makes sure of it.
            let since = (earlier.last.map { $0.hostTime + hostOffset } ?? 0) + 0.2
            let seenLater = arrivals(at: laterJumps.map(\.point),
                                     in: real.filter { $0.time > since }.map { ($0.time, $0.point) }, tolerance: 4)
            let writtenLater = arrivals(at: laterJumps.map(\.point),
                                        in: track.samples.filter { $0.t > since }.map { ($0.t, $0.point) },
                                        tolerance: 4)
            let differences = zip(writtenLater, seenLater).compactMap { written, seen -> Double? in
                guard let written, let seen else { return nil }
                return written - seen
            }
            if differences.isEmpty {
                findings.append(Finding(name: "after a pause: sample vs picture", value: "none matched",
                                        passed: false, note: "picture \(seenLater), samples \(writtenLater)"))
            } else {
                let mean = differences.reduce(0, +) / Double(differences.count)
                findings.append(Finding(name: "after a pause: sample vs picture",
                                        value: "\(milliseconds(mean)) mean over \(differences.count)",
                                        passed: abs(mean) < 0.020,
                                        note: "the pause was \(format(MouseScript.pauseLength))s; a pointer late by that much was never told about it"))
            }

            let laterOffsets = zip(laterJumps, seenLater).compactMap { jump, seen in seen.map { $0 - jump.hostTime } }
            if let laterOffset = median(laterOffsets),
               let press = pressed.first(where: { $0.label == "click-after-pause" }) {
                if let click = track.clicks.dropFirst(earlier.count).first {
                    findings += clickFindings(index: earlier.count, press: press, click: click,
                                              expected: press.hostTime + laterOffset, real: real)
                } else {
                    findings.append(Finding(name: "click \(earlier.count + 1) (\(press.label))", value: "not recorded",
                                            passed: false, note: "clicks stop being written after a pause"))
                }
            }
        }

        // MARK: What is actually drawn

        findings += drawn(document: document, frames: real, clicks: track.clicks)
        return findings
    }

    // MARK: - Pieces

    /// When each place in a list was first reached, in order.
    private static func arrivals(at places: [CGPoint],
                                 in path: [(Double, CGPoint)],
                                 tolerance: Double) -> [Double?] {
        var found = [Double?](repeating: nil, count: places.count)
        var next = 0
        for (time, point) in path {
            guard next < places.count else { break }
            if hypot(point.x - places[next].x, point.y - places[next].y) <= tolerance {
                found[next] = time
                next += 1
            }
        }
        return found
    }

    /// How far the pointer's dark fill is from the point the telemetry names, read while
    /// the pointer is standing still so a clock error cannot leak into it.
    private static func calibration(frames: [FrameObservation],
                                    track: CursorTrack,
                                    before arrivals: [Double]) -> CGPoint? {
        var dx: [Double] = [], dy: [Double] = []
        for arrival in arrivals {
            for frame in frames where frame.time > arrival + 0.2 && frame.time < arrival + 0.4 {
                guard let tip = frame.tip, let written = track.position(at: frame.time) else { continue }
                dx.append(tip.x - written.x)
                dy.append(tip.y - written.y)
            }
        }
        guard let x = median(dx), let y = median(dy) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The shift in time that best lays the written pointer over the real one, read where
    /// the pointer moves at a constant speed.
    private static func sweepLag(sweeps: [ScriptRecord],
                                 hostOffset: Double,
                                 real: [(time: Double, point: CGPoint)],
                                 track: CursorTrack) -> (seconds: Double, residual: Double, frames: Int)? {
        // Each sweep is a run of steps a few milliseconds apart.
        var runs: [(from: Double, to: Double)] = []
        var start: Double?
        var last: Double?
        for step in sweeps {
            if let previous = last, step.hostTime - previous > 0.2, let began = start {
                runs.append((began + hostOffset, previous + hostOffset))
                start = step.hostTime
            }
            if start == nil { start = step.hostTime }
            last = step.hostTime
        }
        if let began = start, let ended = last { runs.append((began + hostOffset, ended + hostOffset)) }

        let moving = real.filter { frame in
            runs.contains { frame.time > $0.from + 0.08 && frame.time < $0.to - 0.08 }
        }
        guard moving.count > 20 else { return nil }

        var best: (shift: Double, error: Double)?
        var shift = -0.25
        while shift <= 0.25 {
            var total = 0.0
            for frame in moving {
                guard let written = track.position(at: frame.time + shift) else { continue }
                let dx = written.x - frame.point.x, dy = written.y - frame.point.y
                total += dx * dx + dy * dy
            }
            if best == nil || total < best!.error { best = (shift, total) }
            shift += 0.0005
        }
        guard let best else { return nil }
        return (best.shift, (best.error / Double(moving.count)).squareRoot(), moving.count)
    }

    private static func clickFindings(index: Int,
                                      press: ScriptRecord,
                                      click: CursorTrack.Click,
                                      expected: Double,
                                      real: [(time: Double, point: CGPoint)]) -> [Finding] {
        let name = "click \(index + 1) (\(press.label))"
        // A frame is a sixtieth of a second, and a pointer on the move covers ground in
        // that time: the nearest frame to a click can show the pointer half a frame of
        // travel away from it, and that is the picture's grain rather than an error.
        let travel = press.label == "click-moving" ? MouseScript.runSpeed / 120 : 0
        let miss = hypot(click.point.x - press.x, click.point.y - press.y)
        var findings = [Finding(name: "\(name): place",
                                value: "\(format(miss)) pt off",
                                passed: miss <= 2,
                                note: "pressed at (\(format(press.x)), \(format(press.y))), written as (\(format(click.point.x)), \(format(click.point.y)))")]
        let late = click.t - expected
        findings.append(Finding(name: "\(name): time",
                                value: milliseconds(late),
                                passed: abs(late) <= 0.015,
                                note: "written at \(format(click.t))s, the picture has it at \(format(expected))s"))
        // What somebody watching sees: the ring is drawn at the written place at the
        // written time, over a picture with the real pointer in it.
        if let frame = real.min(by: { abs($0.time - click.t) < abs($1.time - click.t) }) {
            let apart = hypot(frame.point.x - click.point.x, frame.point.y - click.point.y)
            findings.append(Finding(name: "\(name): ring vs real pointer",
                                    value: "\(format(apart)) pt apart",
                                    passed: apart <= 3 + travel,
                                    note: "in the frame at \(format(frame.time))s the pointer is at (\(format(frame.point.x)), \(format(frame.point.y)))"))
        }
        return findings
    }

    /// The pointer as the renderer would draw it, against the pointer in the picture.
    private static func drawn(document: EditorDocument,
                              frames: [(time: Double, point: CGPoint)],
                              clicks: [CursorTrack.Click]) -> [Finding] {
        let manifest = document.manifest
        guard let size = manifest.track(.screen)?.pixelSize, size.width > 0 else { return [] }
        let builder = SceneBuilder(videoSize: size, displayScale: manifest.displayScale)
        var findings: [Finding] = []

        for (title, smoothing) in [("unsmoothed", 0.0), ("default smoothing", document.timeline.cursor.smoothing)] {
            var timeline = document.timeline
            timeline.cursor.smoothing = smoothing
            // The frame, and nothing round it: padding moves the picture inside the output
            // and this is a reading of where the pointer is on the picture.
            timeline.style.padding = 0
            let track = document.cursorTrack.smoothed(smoothing)

            func drawnPoint(at time: Double) -> CGPoint? {
                let descriptor = builder.descriptor(for: timeline,
                                                    at: CMTime(seconds: time, preferredTimescale: 6_000),
                                                    cursor: track)
                guard let cursor = descriptor.cursor else { return nil }
                return CGPoint(x: cursor.position.x * size.width / manifest.displayScale,
                               y: cursor.position.y * size.height / manifest.displayScale)
            }

            var still: [Double] = []
            var all: [Double] = []
            for (index, frame) in frames.enumerated() {
                guard let point = drawnPoint(at: frame.time) else { continue }
                let apart = hypot(point.x - frame.point.x, point.y - frame.point.y)
                all.append(apart)
                // Standing still: the same place for a fifth of a second either side.
                let neighbours = frames[max(0, index - 12)...min(frames.count - 1, index + 12)]
                if neighbours.allSatisfy({ hypot($0.point.x - frame.point.x, $0.point.y - frame.point.y) < 0.75 }) {
                    still.append(apart)
                }
            }
            if let worst = still.max() {
                findings.append(Finding(name: "drawn pointer at rest (\(title))",
                                        value: "\(format(worst)) pt worst, \(format(mean(still))) mean",
                                        passed: worst <= 2,
                                        note: "\(still.count) frames where the real pointer was standing still"))
            }
            if !all.isEmpty {
                let sorted = all.sorted()
                findings.append(Finding(name: "drawn pointer overall (\(title))",
                                        value: "\(format(mean(all))) pt mean, \(format(sorted[Int(Double(sorted.count) * 0.95)])) pt at 95%, \(format(sorted.last ?? 0)) pt worst",
                                        // Smoothing is allowed to round a corner; the raw path is not.
                                        // Five points is a third of a frame at the speed
                                        // the sweeps run at, which is how finely a frame
                                        // taken every other refresh can place a pointer.
                                        passed: smoothing > 0 || mean(all) <= 5,
                                        note: "jumps and sweeps included"))
            }
            for (index, click) in clicks.enumerated() {
                guard let point = drawnPoint(at: click.t) else { continue }
                let apart = hypot(point.x - click.point.x, point.y - click.point.y)
                findings.append(Finding(name: "drawn pointer at click \(index + 1) (\(title))",
                                        value: "\(format(apart)) pt from its own ring",
                                        passed: apart <= 1,
                                        note: "pointer drawn at (\(format(point.x)), \(format(point.y))), ring at (\(format(click.point.x)), \(format(click.point.y)))"))
            }
        }
        return findings
    }

    // MARK: - Small things

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func format(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func milliseconds(_ seconds: Double) -> String {
        String(format: "%+.1f ms", seconds * 1_000)
    }
}
