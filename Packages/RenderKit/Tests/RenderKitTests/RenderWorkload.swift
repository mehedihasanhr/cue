import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import TimelineKit
@testable import RenderKit

/// A realistic edit, and the tools to time work against it.
///
/// Shared between the benchmarks and the fidelity guard on purpose: a measurement of one
/// timeline and an equality assertion about a different one prove nothing together. Both
/// read the same project here, built from fixed numbers with no `UUID()` and no clock in
/// it, so two runs describe the same frames.
enum RenderWorkload {
    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Ids drawn from a counter rather than `UUID()`.
    ///
    /// A region's id reaches no descriptor, so it cannot change a pixel — but a golden
    /// hash taken over a project containing random ids would be a hash of the randomness
    /// as much as of the edit, and the point of the guard is that a failure means the
    /// render moved.
    private static func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    static let videoSize = CGSize(width: 3_840, height: 2_160)
    static let displayScale = 2.0

    /// A minute of editing of the kind somebody actually ships: overlapping zooms that
    /// follow the pointer, a couple of blurs over a password field, labels, a full track
    /// of captions, and a stretch where the pointer is hidden and another where it is
    /// held.
    ///
    /// - Parameter regions: how many of each timed thing to lay down. The default is a
    ///   heavy but not absurd project; the scaling benchmark turns this up.
    static func timeline(regions: Int = 24, duration: Double = 60) -> Timeline {
        var timeline = Timeline(sourceDuration: time(duration))
        timeline.style.padding = 0.06
        timeline.style.cornerRadius = 0.02
        timeline.style.shadowRadius = 0.02
        timeline.style.shadowOpacity = 0.35
        timeline.style.backgroundBlur = 0.01
        timeline.style.background = .gradient(from: ColorValue(r: 0.1, g: 0.12, b: 0.3),
                                              to: ColorValue(r: 0.45, g: 0.1, b: 0.35),
                                              angle: 0.2)
        timeline.cursor.motionBlur = true
        timeline.cursor.clickEffect = true
        timeline.cursor.smoothing = 0.4
        timeline.captionStyle.isVisible = true

        let step = duration / Double(regions)
        for index in 0..<regions {
            let at = Double(index) * step
            // Deliberately overlapping: a zoom lasting longer than its slot is what makes
            // the "strongest wins" search in `camera` do real work rather than finding
            // one candidate and stopping.
            timeline.zooms.append(ZoomRegion(id: id(index),
                                             start: time(at),
                                             duration: time(step * 1.6),
                                             scale: 1.4 + Double(index % 4) * 0.4,
                                             center: CGPoint(x: 0.3 + Double(index % 3) * 0.2,
                                                             y: 0.4 + Double(index % 2) * 0.2),
                                             transition: time(0.4),
                                             followsCursor: index % 2 == 0))
            timeline.blurs.append(BlurRegion(id: id(1_000 + index),
                                             start: time(at),
                                             duration: time(step * 0.7),
                                             rect: CGRect(x: 0.1, y: 0.6, width: 0.3, height: 0.1),
                                             style: index % 2 == 0 ? .gaussian : .pixelate,
                                             radius: 20))
            timeline.annotations.append(AnnotationItem(id: id(2_000 + index),
                                                       start: time(at),
                                                       duration: time(step * 0.8),
                                                       kind: .text("Step \(index + 1)"),
                                                       rect: CGRect(x: 0.55, y: 0.1, width: 0.35, height: 0.1)))
            timeline.captions.append(CaptionCue(id: id(3_000 + index),
                                                start: time(at),
                                                duration: time(step * 0.9),
                                                text: "And then we click the button that says step \(index + 1)."))
            timeline.cursorRegions.append(CursorRegion(id: id(4_000 + index),
                                                       start: time(at + step * 0.2),
                                                       duration: time(step * 0.5),
                                                       isHidden: index % 3 == 0,
                                                       smoothing: index % 3 == 1 ? 0.3 : 0,
                                                       isHeld: index % 3 == 2,
                                                       transition: time(0.2)))
        }
        return timeline
    }

    /// A pointer track at 120 Hz, moving the way a hand does: a drift with a tremor on
    /// top, so smoothing and averaging have something to bite on.
    static func cursorTrack(duration: Double = 60, rate: Double = 120) -> CursorTrack {
        let count = Int(duration * rate)
        var samples: [CursorSample] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let t = Double(index) / rate
            let x = 300 + t * 18 + sin(t * 7) * 40 + sin(t * 61) * 3
            let y = 400 + cos(t * 3) * 120 + cos(t * 53) * 2
            samples.append(CursorSample(t: t, x: x, y: y,
                                        shape: index % 400 < 60 ? .iBeam : .arrow))
        }
        var input: [InputSample] = []
        for index in 0..<Int(duration) {
            input.append(.mouseDown(t: Double(index) + 0.5, button: 0, x: 0, y: 0))
        }
        return CursorTrack(samples: samples, input: input)
    }

    static func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: displayScale)
    }

    /// A stand-in for a decoded frame, so a render measurement is of the compositing
    /// rather than of a decoder.
    static func source(_ size: CGSize = videoSize) -> CIImage {
        CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: - Timing

    /// The median of `count` runs, in microseconds.
    ///
    /// Median rather than mean, and never a single run: the first call through Core Image
    /// pays for shader compilation, the machine is shared with whatever else is building,
    /// and a mean lets one outlier tell the story. `warmup` runs are thrown away for the
    /// same reason.
    static func median(count: Int, warmup: Int = 3, _ body: (Int) -> Void) -> Double {
        for index in 0..<warmup { body(index) }
        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let elapsed = clock.measure { body(index) }
            samples.append(Double(elapsed.components.attoseconds) / 1e12
                           + Double(elapsed.components.seconds) * 1e6)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// A one-line report, so a benchmark run reads as a table rather than as prose.
    static func report(_ name: String, microseconds: Double, extra: String = "") {
        let rate = microseconds > 0 ? 1_000_000 / microseconds : .infinity
        print(String(format: "BENCH %-46@ %9.1f µs  %8.1f/s  %@",
                     name as NSString, microseconds, rate, extra as NSString))
    }

    /// Resident memory, for the growth checks. `nil` when the kernel will not say.
    static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }
}
