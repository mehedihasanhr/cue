import CoreMedia
import Foundation
import RecordKit
import RenderKit
import TimelineKit

/// `studiolab camera <recording.cuerec>` — how the camera actually moves through every
/// zoom of a recording, measured frame by frame from the same scenes the editor draws.
///
/// "The zoom is too fast" and "it shakes before it settles" are judgements about motion,
/// and motion can be measured: for each ramp in or out this prints how far the scale went
/// past where it was going, how hard it started, how far the thing being zoomed at wandered
/// off the straight line to the middle of the screen, and how many times the camera changed
/// its mind about which way to go. Over the whole take it counts how often the source crop
/// changed, which is the picture itself jumping.
@MainActor
enum CameraCheck {
    struct Sample {
        let time: Double
        let zoom: Double
        let center: CGPoint
        let crop: CGRect
        /// How far the shutter smears the picture this frame, in output pixels.
        var blur: Double = 0
    }

    static func run(_ arguments: [String]) async -> Int32 {
        guard let path = arguments.first else {
            print("usage: studiolab camera <recording.cuerec>")
            return 2
        }
        let package = RecordingPackage(url: URL(fileURLWithPath: path))
        let document: EditorDocument
        do {
            document = try EditorDocument(package: package)
        } catch {
            print("could not open the recording: \(error)")
            return 1
        }
        var timeline = document.timeline
        // `--speed slow|medium|fast`: the recording as it would play with that zoom speed.
        if let flag = arguments.firstIndex(of: "--speed"), flag + 1 < arguments.count,
           let speed = ZoomSpeed(rawValue: arguments[flag + 1]) {
            _ = Commands.setZoomSpeed(speed).apply(to: &timeline)
            print("zoom speed: \(speed.title), \(speed.transition) s each way")
        }
        // `--suggest`: with the zooms the editor adds the first time a take is opened, for a
        // take nobody has edited yet — which is exactly the one being complained about.
        if arguments.contains("--suggest") {
            let size = document.manifest.track(.screen)?.pixelSize ?? CGSize(width: 1_920, height: 1_080)
            let points = size.width / max(0.1, document.manifest.displayScale)
            let suggester = ZoomSuggester(frameSize: CGSize(width: points, height: size.height / max(0.1, document.manifest.displayScale)),
                                          crop: timeline.style.crop?.rect ?? CropRect.full.rect,
                                          picture: document.pictureTrack,
                                          tuning: ZoomSuggester.Tuning(transition: timeline.camera.zoomSpeed.transition))
            let found = suggester.smartSuggestions(cursor: document.cursorTrack.samples, input: document.inputSamples,
                                              focus: document.focusSamples, duration: timeline.sourceDuration)
            if arguments.contains("--moments") {
                for moment in suggester.suggestions(cursor: document.cursorTrack.samples, input: document.inputSamples,
                                                    focus: document.focusSamples, duration: timeline.sourceDuration) {
                    print(String(format: "moment %6.2f–%6.2f  %@  centre %.2f, %.2f", moment.start.seconds, moment.end.seconds,
                                 moment.source?.rawValue ?? "manual", moment.center.x, moment.center.y))
                }
            }
            _ = Commands.SuggestZooms(timeline.placedOnTimeline(found)).apply(to: &timeline)
        }
        if arguments.contains("--no-follow") {
            timeline.camera.follow = 0
            print("pointer following off")
        }
        let pixelSize = document.manifest.track(.screen)?.pixelSize ?? CGSize(width: 1_920, height: 1_080)
        let scale = max(0.1, document.manifest.displayScale)
        let points = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        let builder = SceneBuilder(videoSize: pixelSize, displayScale: document.manifest.displayScale,
                                   packageURL: package.url, cursorArtwork: document.cursorArtwork,
                                   picture: document.pictureTrack)
        let cursor = document.cursorTrack.smoothed(timeline.cursor.smoothing)

        let rate = 60.0
        let count = Int(timeline.duration.seconds * rate)
        var samples: [Sample] = []
        samples.reserveCapacity(count)
        for frame in 0..<count {
            let time = Double(frame) / rate
            let scene = builder.descriptor(for: timeline, at: CMTime(seconds: time, preferredTimescale: 60_000), cursor: cursor)
            var sample = Sample(time: time, zoom: scene.zoom, center: scene.zoomCenter, crop: scene.sourceCrop)
            if let motion = scene.cameraMotion {
                let reach = hypot(scene.outputSize.width, scene.outputSize.height) / 2
                sample.blur = max(hypot(motion.travel.dx, motion.travel.dy), abs(motion.growth) * reach)
            }
            samples.append(sample)
        }

        // `--trace from to`: the camera every tenth of a second over a stretch.
        if let flag = arguments.firstIndex(of: "--trace"), flag + 2 < arguments.count,
           let from = Double(arguments[flag + 1]), let to = Double(arguments[flag + 2]) {
            for sample in samples where sample.time >= from && sample.time <= to
                && (to - from < 1 || arguments.contains("--every-frame") || Int((sample.time * 60).rounded()) % 6 == 0) {
                print(String(format: "  %6.2f s  zoom %.4f  centre %.6f, %.6f  blur %.2f", sample.time, sample.zoom,
                             sample.center.x, sample.center.y, sample.blur))
            }
        }
        var cropChanges = 0
        for (a, b) in zip(samples, samples.dropFirst()) where a.crop != b.crop { cropChanges += 1 }
        print(String(format: "%.1f s, %d frames, %d zooms, picture %.0f × %.0f pt", timeline.duration.seconds,
                     samples.count, timeline.zooms.count, points.width, points.height))
        print("source crop changed \(cropChanges) times")
        print("ramp        start   len   target  overshoot  start-speed  peak-speed  drift(pt)  reversals")

        var worstOvershoot = 0.0, worstDrift = 0.0, totalReversals = 0
        for zoom in timeline.zooms where zoom.isEnabled {
            let transition = zoom.transition.seconds
            guard transition > 0 else { continue }
            for (name, from, to) in [("in ", zoom.start.seconds, zoom.start.seconds + transition),
                                      ("out", zoom.end.seconds - transition, zoom.end.seconds)] {
                let ramp = samples.filter { $0.time >= from && $0.time <= to }
                guard ramp.count > 3 else { continue }
                let target = ramp.map(\.zoom).max() ?? 1
                // Past the zoom's own level, and for the whole zoom, not just this ramp:
                // an overshoot shows as the scale going above where it then holds.
                let held = samples.filter { $0.time > zoom.start.seconds + transition && $0.time < zoom.end.seconds - transition }
                let settledScale = held.isEmpty ? zoom.scale : held.map(\.zoom).reduce(0, +) / Double(held.count)
                let overshoot = max(0, (ramp.map(\.zoom).max() ?? 1) - settledScale) / max(0.001, settledScale - 1)

                // How hard the ramp starts: the first frame's change of scale against the
                // ramp's average change per frame. 1 is linear; an ease starts near 0.
                let steps = zip(ramp, ramp.dropFirst()).map { abs($1.zoom - $0.zoom) }
                let average = steps.reduce(0, +) / Double(max(1, steps.count))
                let first = name == "in " ? steps.first ?? 0 : steps.last ?? 0
                let startSpeed = average > 0 ? first / average : 0
                let peakSpeed = average > 0 ? (steps.max() ?? 0) / average : 0

                // The point being zoomed at, on screen, through the ramp. It should travel
                // a straight line from where it was to the middle of the screen; how far it
                // strays from that line is the sideways wander.
                let aim = (name == "in " ? ramp.last! : ramp.first!).center
                let onScreen: [CGPoint] = ramp.map { s in
                    let x: Double = ((aim.x - s.center.x) * s.zoom + 0.5) * points.width
                    let y: Double = ((aim.y - s.center.y) * s.zoom + 0.5) * points.height
                    return CGPoint(x: x, y: y)
                }
                let a = onScreen.first!, b = onScreen.last!
                let length = max(0.001, hypot(b.x - a.x, b.y - a.y))
                var drift = 0.0
                for p in onScreen {
                    let cross: Double = (b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)
                    drift = max(drift, abs(cross) / length)
                }

                // Times the centre turned back on itself, on either axis, ignoring
                // movements too small to see (a hundredth of a point).
                var reversals = 0
                for axis in 0..<2 {
                    var last = 0.0
                    for (p, q) in zip(ramp, ramp.dropFirst()) {
                        let step = axis == 0 ? (q.center.x - p.center.x) * points.width : (q.center.y - p.center.y) * points.height
                        guard abs(step) > 0.01 else { continue }
                        if last != 0, (step > 0) != (last > 0) { reversals += 1 }
                        last = step
                    }
                }
                worstOvershoot = max(worstOvershoot, overshoot)
                worstDrift = max(worstDrift, drift)
                totalReversals += reversals
                print(String(format: "%@ %6.2f  %5.2f   %5.2f×   %6.1f%%     %5.2f       %5.2f     %7.1f     %d",
                             name, from, to - from, target, overshoot * 100, startSpeed, peakSpeed, drift, reversals))
            }
        }
        // Shake: while zoomed in, how often the picture turns back on itself frame to frame,
        // in output points of the picture as it is shown. A camera that follows calmly turns
        // round a few times a second at most; one that shakes does it every other frame.
        var turns = 0, zoomedFrames = 0, worstJerk = 0.0, worstAt = 0.0
        var lastStep = CGVector.zero
        for (p, q) in zip(samples, samples.dropFirst()) where p.zoom > 1.01 && q.zoom > 1.01 {
            zoomedFrames += 1
            let step = CGVector(dx: (q.center.x - p.center.x) * points.width * q.zoom,
                                dy: (q.center.y - p.center.y) * points.height * q.zoom)
            for (a, b) in [(step.dx, lastStep.dx), (step.dy, lastStep.dy)]
                where abs(a) > 0.05 && abs(b) > 0.05 && (a > 0) != (b > 0) {
                turns += 1
                let jerk = abs(a - b)
                if jerk > worstJerk { worstJerk = jerk; worstAt = q.time }
            }
            lastStep = step
        }
        print(String(format: "shake: %d turn-backs over %d zoomed frames (%.1f a second), worst %.2f pt at %.2f s",
                     turns, zoomedFrames, Double(turns) / max(1, Double(zoomedFrames)) * 60, worstJerk, worstAt))
        print(String(format: "worst: overshoot %.1f%%, drift %.1f pt, reversals %d in total, crop changes %d",
                     worstOvershoot * 100, worstDrift, totalReversals, cropChanges))
        return 0
    }
}
