import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import TimelineKit
import Vision

/// Reads a recording's text and finds what should not be shown: addresses, numbers, keys,
/// passwords. See `SensitiveText` for what counts, and `SensitiveFinding` for what comes
/// back.
///
/// # How
///
/// 1. **Samples**, twice a second by default: text on a screen stays put for longer than
///    that far more often than not, and reading every frame of a ten-minute take would
///    take longer than the take. A sample whose picture has not changed since the last one
///    read is not read again — most of a screen recording is somebody reading it.
/// 2. **Stretches**: the same text on consecutive samples is one finding
///    (`SensitiveGrouping`).
/// 3. **Edges, to the frame.** Between the last sample without it and the first with it,
///    frames are read by halving the gap until the first frame it is on is found, and the
///    same at the other end — a handful of reads per edge rather than every frame, each
///    only across the band of the picture where the text is. A couple of frames more
///    are added either side, because a frame the recogniser missed is still a frame the
///    viewer can read.
/// 4. **Moving text** is followed frame by frame with `MaskFollower`, from the middle of
///    its stretch — the same tracker a mask told to follow its content uses — so a mask
///    over a scrolling page stays on the line between samples, not just at them. When the
///    tracker's path disagrees with where the text was read, the straight lines between
///    the readings are kept instead.
///
/// Recognition is Vision's, on the device, at its accurate level and without language
/// correction: a key or an address is not a word, and "correcting" one into a word is
/// exactly the misreading that stops it being found.
public enum SensitiveScanner {
    public struct Settings: Equatable, Sendable {
        /// Seconds between samples.
        public var interval = 0.5
        /// Frames added before and after each edge found.
        public var marginFrames = 2
        /// The longest side a frame is read at. Text on a Retina recording is twice as many
        /// pixels as it needs to be for the recogniser, and every pixel costs.
        public var longestSide: CGFloat = 2_048

        public init() {}
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let reason): "The recording could not be read. \(reason)"
            }
        }
    }

    /// Reads the recording at `videoURL` and returns what it found, on the recording's clock.
    ///
    /// - Parameter progress: 0…1, from whatever thread the work is on.
    /// - Throws: `Failure`, or `CancellationError` when the task is cancelled.
    public static func scan(videoURL: URL, settings: Settings = Settings(),
                            progress: @Sendable (Double) -> Void = { _ in }) async throws -> [SensitiveFinding] {
        let asset = AVURLAsset(url: videoURL)
        let duration: Double
        let frameRate: Double
        do {
            duration = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw Failure.unreadable("It has no picture.")
            }
            let rate = Double(try await track.load(.nominalFrameRate))
            frameRate = rate.isFinite && rate >= 1 ? rate : 60
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        guard duration.isFinite, duration > 0 else { return [] }
        try Task.checkCancellation()

        let reader: ExportFrameReader
        do {
            reader = try await ExportFrameReader(url: videoURL)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        defer { reader.cancel() }
        let size = await reader.naturalSize()
        guard size.width >= 1, size.height >= 1 else { throw Failure.unreadable("It has no picture.") }
        let scale = min(1, settings.longestSide / max(size.width, size.height))
        let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])

        var reported = -1.0
        func report(_ fraction: Double) {
            let fraction = min(1, max(0, fraction))
            guard fraction - reported >= 0.01 || fraction == 1 else { return }
            reported = fraction
            progress(fraction)
        }

        // The edges are found with exact seeks of their own. The reader above walks forwards
        // and, asked for a moment a hair before the frame it holds, hands back that frame —
        // right for an export, and wrong for a search that steps back and forth by less
        // than a frame to find where something begins.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: size.width * scale, height: size.height * scale)
        func exactFrame(at seconds: Double) async throws -> CIImage? {
            let time = CMTime(seconds: seconds + 0.000_5, preferredTimescale: 600_000)
            guard let (image, _) = try? await generator.image(at: time) else { return nil }
            return CIImage(cgImage: image)
        }

        func frame(at seconds: Double) throws -> CIImage? {
            // Half a millisecond late, for the reason `MaskFollower` gives.
            let time = CMTime(seconds: seconds + 0.000_5, preferredTimescale: 600_000)
            do {
                return try reader.frame(at: time).map { scaled($0, by: scale) }
            } catch {
                throw Failure.unreadable(error.localizedDescription)
            }
        }

        // 1. Samples.
        let times = Array(stride(from: 0.0, to: duration, by: max(0.05, settings.interval)))
        var samples: [SensitiveSample] = []
        var previous: (luma: [UInt8], detections: [SensitiveDetection])?
        for (index, time) in times.enumerated() {
            try Task.checkCancellation()
            report(0.75 * Double(index) / Double(times.count))
            guard let image = try frame(at: time) else { break }
            let luma = thumbnail(image, context: context)
            if let previous, let luma, !changed(previous.luma, luma) {
                samples.append(SensitiveSample(time: time, detections: previous.detections))
                continue
            }
            let detections = try read(image)
            samples.append(SensitiveSample(time: time, detections: detections))
            previous = luma.map { ($0, detections) }
        }

        // 2. Stretches.
        let stretches = SensitiveGrouping.stretches(in: samples)

        // 3. Edges.
        let step = 1 / frameRate
        let margin = Double(settings.marginFrames) * step
        var findings: [SensitiveFinding] = []
        for (number, stretch) in stretches.enumerated() {
            try Task.checkCancellation()
            report(0.75 + 0.1 * Double(number) / Double(max(1, stretches.count)))
            guard let first = stretch.sightings.first, let last = stretch.sightings.last else { continue }
            let reference = SensitiveDetection(kind: stretch.kind, text: stretch.text, rect: first.rect)
            var start = 0.0
            if let unseen = stretch.unseenBefore {
                let band = searchBand(stretch.sightings, atStart: true)
                start = try await edge(from: unseen, to: first.time, step: step) { time in
                    guard let image = try await exactFrame(at: time) else { return false }
                    return try read(image, band: band).contains { $0.isSame(as: reference) }
                } - margin
            }
            var end = duration
            if let unseen = stretch.unseenAfter {
                let band = searchBand(stretch.sightings, atStart: false)
                // The first frame it is gone from, found from the other side.
                end = try await edge(from: last.time, to: unseen, step: step) { time in
                    guard let image = try await exactFrame(at: time) else { return true }
                    return try !read(image, band: band).contains { $0.isSame(as: reference) }
                } + margin
            }
            start = max(0, min(start, first.time))
            end = min(duration, max(end, last.time + step))
            findings.append(SensitiveFinding(stretch: stretch, start: start, end: end))
        }
        reader.cancel()

        // 4. Moving text, followed.
        let moving = findings.indices.filter { findings[$0].moves }
        for (number, index) in moving.enumerated() {
            try Task.checkCancellation()
            let base = 0.85 + 0.15 * Double(number) / Double(moving.count)
            let share = 0.15 / Double(moving.count)
            if let followed = try await follow(findings[index], duration: duration, videoURL: videoURL,
                                               frameRate: frameRate, progress: { progress(base + share * $0) }) {
                findings[index] = followed
            }
        }
        report(1)
        return findings
    }

    // MARK: - Reading a frame

    /// Every sensitive thing on a picture, as fractions of it, top-left origin.
    ///
    /// - Parameter band: when given, only this band of the picture is read, as fractions
    ///   of its height from the top — a strip the width of the picture, so a line of text
    ///   is never cut in half across.
    static func read(_ image: CIImage, band: ClosedRange<CGFloat>? = nil) throws -> [SensitiveDetection] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // Vision's region of interest is bottom-left and 0…1, like its answers — which then
        // come back as fractions of the region, not of the picture.
        let region: CGRect
        if let band {
            let top = min(max(band.lowerBound, 0), 1), bottom = min(max(band.upperBound, 0), 1)
            guard bottom - top > 0.001 else { return [] }
            region = CGRect(x: 0, y: 1 - bottom, width: 1, height: bottom - top)
            request.regionOfInterest = region
        } else {
            region = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }

        let size = image.extent.size
        func placed(_ box: CGRect) -> CGRect {
            let x = region.minX + box.minX * region.width
            let y = region.minY + box.minY * region.height
            return CGRect(x: x, y: 1 - (y + box.height * region.height),
                          width: box.width * region.width, height: box.height * region.height)
        }

        var detections: [SensitiveDetection] = []
        var lines: [SensitiveText.Line] = []
        var candidates: [VNRecognizedText] = []
        var matched = Set<Int>()
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let index = lines.count
            let box = placed(observation.boundingBox)
            // In pixels for the neighbours' test, which compares distances across and down.
            lines.append(SensitiveText.Line(text: candidate.string,
                                            box: CGRect(x: box.minX * size.width, y: box.minY * size.height,
                                                        width: box.width * size.width, height: box.height * size.height)))
            candidates.append(candidate)
            for match in SensitiveText.matches(in: candidate.string) {
                let part = (try? candidate.boundingBox(for: match.range))?.boundingBox ?? observation.boundingBox
                detections.append(SensitiveDetection(kind: match.kind, text: match.text, rect: placed(part)))
                matched.insert(index)
            }
        }
        for value in SensitiveText.labelledValues(in: lines) where !matched.contains(value.line) {
            let line = lines[value.line]
            detections.append(SensitiveDetection(
                kind: value.kind, text: line.text.trimmingCharacters(in: .whitespaces),
                rect: CGRect(x: line.box.minX / size.width, y: line.box.minY / size.height,
                             width: line.box.width / size.width, height: line.box.height / size.height)))
        }
        return detections
    }

    private static func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
        guard scale < 1 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: - Whether anything changed

    /// A small grey copy of the picture: enough to see a character typed or a line
    /// scrolled, far too little to see compression noise.
    private static func thumbnail(_ image: CIImage, context: CIContext) -> [UInt8]? {
        guard image.extent.width >= 1,
              let plane = LumaPlane(image, scale: 192 / image.extent.width, context: context) else { return nil }
        return plane.pixels.map { UInt8(max(0, min(255, $0))) }
    }

    /// Whether two thumbnails differ anywhere by more than noise.
    static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return true }
        for (x, y) in zip(a, b) where abs(Int(x) - Int(y)) > 8 { return true }
        return false
    }

    // MARK: - Edges

    /// The first moment, to a frame, at which `found` turns true between `from` (where it
    /// is false) and `to` (where it is true) — `from` may be after `to`, for the end of a
    /// stretch. Halving, which trusts that the text does not come and go inside half a
    /// second; the margin added afterwards is for the frame where it half does.
    static func edge(from: Double, to: Double, step: Double,
                     found: (Double) async throws -> Bool) async throws -> Double {
        var outside = from
        var inside = to
        while abs(inside - outside) > step * 1.5 {
            try Task.checkCancellation()
            let middle = (outside + inside) / 2
            if try await found(middle) { inside = middle } else { outside = middle }
        }
        return inside
    }

    /// The band of the picture to read around one end of a stretch: where it was read at
    /// that end, and — for text that was moving — as far again in the direction it came
    /// from or went, since between two samples it was somewhere along that line.
    static func searchBand(_ sightings: [SensitiveSighting], atStart: Bool) -> ClosedRange<CGFloat> {
        guard let end = atStart ? sightings.first : sightings.last else { return 0...1 }
        var box = end.rect
        if sightings.count >= 2 {
            let next = atStart ? sightings[1] : sightings[sightings.count - 2]
            let dy = end.rect.midY - next.rect.midY
            box = box.union(end.rect.offsetBy(dx: 0, dy: dy))
        }
        let slack = max(box.height, end.rect.height * 3)
        return (box.minY - slack)...(box.maxY + slack)
    }

    // MARK: - Following

    /// The finding with a frame-by-frame path, or `nil` to keep the one it has.
    private static func follow(_ finding: SensitiveFinding, duration: Double, videoURL: URL, frameRate: Double,
                               progress: @Sendable (Double) -> Void) async throws -> SensitiveFinding? {
        guard finding.sightings.count >= 2 else { return nil }
        let middle = finding.sightings[finding.sightings.count / 2]
        let source = CMTime(seconds: duration, preferredTimescale: 600_000)
        var timeline = Timeline(sourceDuration: source)
        let mask = BlurRegion(start: CMTime(seconds: finding.start, preferredTimescale: 600_000),
                              duration: CMTime(seconds: finding.end - finding.start, preferredTimescale: 600_000),
                              rect: finding.rect(atSource: middle.time), style: .cover)
        timeline.blurs = [mask]
        let result: MaskFollower.Result
        do {
            result = try await MaskFollower.follow(mask, in: timeline,
                                                   from: CMTime(seconds: middle.time, preferredTimescale: 600_000),
                                                   videoURL: videoURL, frameRate: frameRate, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Nothing the tracker could hold on to: the readings' own path stands.
            return nil
        }
        var followed = finding
        followed.rect = result.rect
        followed.path = result.path.isEmpty ? nil : result.path
        return agrees(followed, with: finding.sightings) ? followed : nil
    }

    /// Whether a followed path is where the text was read, at every reading — within most
    /// of a line's height, which is well past a reading's wobble and well short of the next
    /// line.
    static func agrees(_ finding: SensitiveFinding, with sightings: [SensitiveSighting]) -> Bool {
        sightings.allSatisfy { sighting in
            let shown = finding.rect(atSource: sighting.time)
            let tolerance = max(sighting.rect.height * 0.6, 0.004)
            return abs(shown.midX - sighting.rect.midX) <= max(tolerance, sighting.rect.width * 0.1)
                && abs(shown.midY - sighting.rect.midY) <= tolerance
        }
    }
}
