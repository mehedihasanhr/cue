import CoreGraphics
import CoreMedia
import Foundation

/// Where one piece of sensitive text was read, at one moment of the recording.
public struct SensitiveSighting: Codable, Equatable, Sendable {
    /// Seconds into the recording — its own clock, not the edit's.
    public var time: Double
    /// A fraction of the recording, top-left origin, like `BlurRegion.rect`.
    public var rect: CGRect

    public init(time: Double, rect: CGRect) {
        self.time = time
        self.rect = rect
    }
}

/// One thing found on one frame.
public struct SensitiveDetection: Equatable, Sendable {
    public var kind: SensitiveKind
    public var text: String
    /// A fraction of the recording, top-left origin.
    public var rect: CGRect

    public init(kind: SensitiveKind, text: String, rect: CGRect) {
        self.kind = kind
        self.text = text
        self.rect = rect
    }

    /// Whether two readings are the same thing, allowing for how text recognition reads
    /// the same pixels a little differently from one frame to the next: a dropped space, an
    /// `O` for a `0`. A password field's dots are one field however many have been typed.
    public func isSame(as other: SensitiveDetection) -> Bool {
        guard kind == other.kind else { return false }
        if kind == .password, Self.isDots(text), Self.isDots(other.text) { return true }
        let a = SensitiveText.normalised(text), b = SensitiveText.normalised(other.text)
        if a == b { return true }
        let allowed = max(1, min(a.count, b.count) / 8)
        guard abs(a.count - b.count) <= allowed else { return false }
        return Self.editDistance(a, b, limit: allowed) <= allowed
    }

    static func isDots(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { "•●∙⋅◦·*.".contains($0) }
    }

    /// Levenshtein, giving up once it is past `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if current.min() ?? 0 > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}

/// What was read off one sampled frame.
public struct SensitiveSample: Equatable, Sendable {
    /// Seconds into the recording.
    public var time: Double
    public var detections: [SensitiveDetection]

    public init(time: Double, detections: [SensitiveDetection]) {
        self.time = time
        self.detections = detections
    }
}

/// One piece of text seen on consecutive samples: a single line in the review sheet,
/// however long it stayed on screen.
public struct SensitiveStretch: Equatable, Sendable {
    public var kind: SensitiveKind
    /// The reading seen most often.
    public var text: String
    /// In time order, one per sample it was seen on — and one per sample it was missed on
    /// between two it was seen on, placed halfway, so a moving mask does not jump there.
    public var sightings: [SensitiveSighting]
    /// The sample just before it was first seen, where it was not: the first frame it is
    /// on lies after this. `nil` when it was there from the first sample.
    public var unseenBefore: Double?
    /// The sample just after it was last seen, where it was gone again. `nil` when it was
    /// there to the last sample.
    public var unseenAfter: Double?
}

/// Sightings on separate samples made into stretches.
public enum SensitiveGrouping {
    /// The same text on consecutive samples is one stretch; the same text in two places at
    /// once is two, each keeping to its own place.
    ///
    /// - Parameter bridging: how many samples in a row a stretch may be missing from and
    ///   still be one stretch. Text recognition misses a line now and then — a frame caught
    ///   mid-scroll, the pointer over a character — and a mask that lets go of it for half
    ///   a second shows exactly what it was hiding.
    public static func stretches(in samples: [SensitiveSample], bridging: Int = 1) -> [SensitiveStretch] {
        let samples = samples.sorted { $0.time < $1.time }
        struct Track {
            var kind: SensitiveKind
            var latest: SensitiveDetection
            var readings: [String]
            var seen: [(index: Int, rect: CGRect)]
            var unseenBefore: Double?
        }
        var open: [Track] = []
        var finished: [(track: Track, unseenAfter: Double?)] = []

        func close(_ track: Track) {
            let after = track.seen.last.map { $0.index + 1 } ?? samples.count
            finished.append((track, after < samples.count ? samples[after].time : nil))
        }

        for (index, sample) in samples.enumerated() {
            open.removeAll { track in
                guard let last = track.seen.last?.index, index - last > bridging + 1 else { return false }
                close(track)
                return true
            }
            // Every pairing of a stretch still going with a reading of the same thing,
            // nearest first: the same address twice on a page stays two stretches, each
            // following its own copy.
            var pairs: [(track: Int, detection: Int, distance: CGFloat)] = []
            for (t, track) in open.enumerated() {
                for (d, detection) in sample.detections.enumerated() where track.latest.isSame(as: detection) {
                    let a = track.latest.rect, b = detection.rect
                    pairs.append((t, d, hypot(a.midX - b.midX, a.midY - b.midY)))
                }
            }
            pairs.sort { $0.distance < $1.distance }
            var usedTracks = Set<Int>(), usedDetections = Set<Int>()
            for pair in pairs where !usedTracks.contains(pair.track) && !usedDetections.contains(pair.detection) {
                usedTracks.insert(pair.track)
                usedDetections.insert(pair.detection)
                let detection = sample.detections[pair.detection]
                open[pair.track].latest = detection
                open[pair.track].readings.append(detection.text)
                open[pair.track].seen.append((index, detection.rect))
            }
            for (d, detection) in sample.detections.enumerated() where !usedDetections.contains(d) {
                open.append(Track(kind: detection.kind, latest: detection, readings: [detection.text],
                                  seen: [(index, detection.rect)],
                                  unseenBefore: index > 0 ? samples[index - 1].time : nil))
            }
        }
        open.forEach(close)

        return finished.map { track, unseenAfter in
            var sightings: [SensitiveSighting] = []
            for (number, seen) in track.seen.enumerated() {
                if number > 0 {
                    let before = track.seen[number - 1]
                    // A sample it was missed on, between two it was seen on: where it most
                    // likely was, halfway.
                    for missing in (before.index + 1)..<seen.index {
                        let f = CGFloat(missing - before.index) / CGFloat(seen.index - before.index)
                        sightings.append(SensitiveSighting(time: samples[missing].time,
                                                           rect: interpolated(before.rect, seen.rect, f)))
                    }
                }
                sightings.append(SensitiveSighting(time: samples[seen.index].time, rect: seen.rect))
            }
            return SensitiveStretch(kind: track.kind, text: mostCommon(track.readings), sightings: sightings,
                                    unseenBefore: track.unseenBefore, unseenAfter: unseenAfter)
        }
        .sorted { ($0.sightings.first?.time ?? 0, $0.text) < ($1.sightings.first?.time ?? 0, $1.text) }
    }

    /// The reading seen most often; of two seen as often, the longer, since a misread is
    /// more often a character lost than one gained.
    static func mostCommon(_ readings: [String]) -> String {
        var counts: [String: Int] = [:]
        for reading in readings { counts[reading, default: 0] += 1 }
        return counts.max { a, b in (a.value, a.key.count, b.key) < (b.value, b.key.count, a.key) }?.key ?? ""
    }

    static func interpolated(_ a: CGRect, _ b: CGRect, _ f: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * f, y: a.minY + (b.minY - a.minY) * f,
               width: a.width + (b.width - a.width) * f, height: a.height + (b.height - a.height) * f)
    }
}

/// Something sensitive, found on the screen for a stretch of the recording, ready to be
/// hidden.
///
/// Everything here is on the *recording's* clock and in the recording's coordinates, not
/// the edit's: it is what the footage shows, so it can be kept beside the footage and
/// stay right however the edit changes. `masks(in:…)` is where it meets the edit.
public struct SensitiveFinding: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var kind: SensitiveKind
    public var text: String
    /// Seconds into the recording: the first moment it is on screen, and the moment after
    /// the last.
    public var start: Double
    public var end: Double
    /// Where it was read, sample by sample.
    public var sightings: [SensitiveSighting]
    /// Where the mask goes, before any padding, as a fraction of the recording: for text
    /// that stays put, throughout; for text that moves, the place `path` moves it from.
    public var rect: CGRect
    /// How the mask moves, for text that moves: key times in seconds from `start`, offsets
    /// from `rect`. `nil` for text that stays put.
    public var path: MaskPath?

    public init(id: UUID = UUID(), kind: SensitiveKind, text: String, start: Double, end: Double,
                sightings: [SensitiveSighting], rect: CGRect, path: MaskPath? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.start = start
        self.end = end
        self.sightings = sightings
        self.rect = rect
        self.path = path?.isEmpty == true ? nil : path
    }

    /// A finding from a stretch and the moments its edges were pinned down to.
    ///
    /// Text that stays where it is gets one rectangle round every place it was read — the
    /// recogniser's box wobbles by a pixel or two, and a password field grows as it is
    /// typed into. Text that moves gets a rectangle the size of the largest reading, moved
    /// from sighting to sighting in straight lines. That is right for a steady scroll; the
    /// scanner replaces it with a frame-by-frame path where it can.
    public init(stretch: SensitiveStretch, start: Double, end: Double) {
        let rects = stretch.sightings.map(\.rect)
        let union = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
        let largest = rects.map(\.width).max() ?? 0
        let tallest = rects.map(\.height).max() ?? 0
        let moves = union.width * union.height > largest * tallest * 1.6
        if moves, let first = stretch.sightings.first {
            let size = CGSize(width: largest, height: tallest)
            let origin = CGPoint(x: first.rect.midX - size.width / 2, y: first.rect.midY - size.height / 2)
            let keys = stretch.sightings.map { sighting in
                MaskPath.Key(time: sighting.time - start,
                             offset: CGVector(dx: sighting.rect.midX - first.rect.midX,
                                              dy: sighting.rect.midY - first.rect.midY))
            }
            self.init(kind: stretch.kind, text: stretch.text, start: start, end: end, sightings: stretch.sightings,
                      rect: CGRect(origin: origin, size: size), path: MaskPath(keys: keys))
        } else {
            self.init(kind: stretch.kind, text: stretch.text, start: start, end: end, sightings: stretch.sightings,
                      rect: union)
        }
    }

    /// Decoded field by field: a finding the cache cannot read in full is still worth its
    /// text and its place, and a finding with no place at all is dropped by the cache.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        id = value(.id, default: UUID())
        kind = value(.kind, default: .secret)
        text = value(.text, default: "")
        start = value(.start, default: 0)
        end = max(start, value(.end, default: start))
        sightings = value(.sightings, default: [])
        rect = value(.rect, default: .zero)
        let path = (try? container.decodeIfPresent(MaskPath.self, forKey: .path)) ?? nil
        self.path = path?.isEmpty == true ? nil : path
    }

    enum CodingKeys: String, CodingKey { case id, kind, text, start, end, sightings, rect, path }

    public var moves: Bool { path != nil }

    /// Where the mask is at a moment of the recording, before padding.
    public func rect(atSource time: Double) -> CGRect {
        guard let path else { return rect }
        let offset = path.offset(at: time - start)
        return rect.offsetBy(dx: offset.dx, dy: offset.dy)
    }

    // MARK: - Against the edit

    /// Whether any of it is in the edit: footage cut away, or only ever outside the crop,
    /// has nothing to hide.
    public func isShown(in timeline: Timeline) -> Bool {
        guard !timeline.pieces(ofSource: start...end).isEmpty else { return false }
        guard let crop = timeline.style.crop?.rect else { return true }
        return sightings.contains { $0.rect.intersects(crop) } || rect.intersects(crop)
    }

    /// Where it is on the timeline: from the first moment it is shown to the last.
    public func timelineRange(in timeline: Timeline) -> CMTimeRange? {
        let pieces = timeline.pieces(ofSource: start...end)
        guard let first = pieces.map(\.range.start).min(), let last = pieces.map(\.range.end).max() else { return nil }
        return CMTimeRange(start: first, end: last)
    }

    /// Whether masks already on the timeline cover it everywhere it was read — so scanning
    /// again after hiding what was found does not offer the same things twice.
    ///
    /// A spotlight does not count: it shows what it is over.
    public func isHidden(by masks: [BlurRegion], in timeline: Timeline) -> Bool {
        let hiding = masks.filter { $0.style != .spotlight }
        var checked = 0
        for sighting in sightings {
            guard let time = timeline.timelineTime(atSource: CMTime(seconds: sighting.time, preferredTimescale: 600_000))
            else { continue }
            checked += 1
            let covered = hiding.contains { mask in
                mask.contains(time) && mask.rect(at: time).insetBy(dx: -0.002, dy: -0.002).contains(sighting.rect)
            }
            if !covered { return false }
        }
        return checked > 0
    }

    /// The masks that hide it in this edit: one for each clip it is in, each moving the way
    /// the text moves on that clip's own clock.
    ///
    /// - Parameters:
    ///   - padding: extra room on every side, as a fraction of the text's height — the
    ///     same margin in pixels across and down, so a padded mask round a line of text is
    ///     as much wider as it is taller.
    ///   - videoSize: the recording's size, which turns that margin into fractions.
    public func masks(in timeline: Timeline, padding: Double, videoSize: CGSize,
                      style: BlurRegion.Style) -> [BlurRegion] {
        let pad = max(0, padding) * rect.height
        let padX = videoSize.width > 0 ? pad * videoSize.height / videoSize.width : pad
        let padded = rect.insetBy(dx: -padX, dy: -pad)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

        return timeline.pieces(ofSource: start...end).compactMap { piece -> BlurRegion? in
            guard piece.range.duration > .zero else { return nil }
            guard let speed = piece.speed, let path else {
                // Still text, or a freeze frame of moving text: one place for the whole piece.
                let offset = path?.offset(at: piece.source.lowerBound - start) ?? .zero
                let placed = padded.offsetBy(dx: offset.dx, dy: offset.dy).intersection(unit)
                guard !placed.isNull, placed.width > 0, placed.height > 0 else { return nil }
                return BlurRegion(start: piece.range.start, duration: piece.range.duration, rect: placed, style: style)
            }
            // The path's clock is the recording's from `start`; the mask's is the timeline's
            // from where this piece begins, at this clip's speed.
            let keys = path.keys.map { key in
                MaskPath.Key(time: (start + key.time - piece.source.lowerBound) / speed, offset: key.offset)
            }
            let clipped = MaskFollowing.clipped(MaskPath(keys: keys), to: piece.range.duration.seconds)
            return BlurRegion(start: piece.range.start, duration: piece.range.duration, rect: padded, style: style,
                              path: clipped)
        }
    }
}

// MARK: - The recording under the edit

extension Timeline {
    /// A stretch of the recording as the edit shows it, one clip at a time.
    public struct SourcePiece: Equatable, Sendable {
        /// Where it is on the timeline.
        public var range: CMTimeRange
        /// The seconds of the recording it shows.
        public var source: ClosedRange<Double>
        /// Recording seconds per timeline second, or `nil` for a freeze frame, which shows
        /// the one moment `source` starts at for as long as it lasts.
        public var speed: Double?
    }

    /// Every clip that shows part of a stretch of the recording, clipped to that part —
    /// `timelineRanges(ofSource:)` with the speed each piece plays at, and with the freeze
    /// frames that hold a moment of it. A freeze frame is not the stretch playing, but it
    /// shows what was on screen then for as long as it lasts, and anything on it that
    /// should be hidden has to be hidden there too.
    public func pieces(ofSource source: ClosedRange<Double>) -> [SourcePiece] {
        var pieces: [SourcePiece] = []
        var elapsed = CMTime.zero
        for clip in clips {
            defer { elapsed = elapsed + clip.duration }
            if clip.isStill {
                let held = clip.sourceStart.seconds
                guard source.contains(held) else { continue }
                pieces.append(SourcePiece(range: CMTimeRange(start: elapsed, duration: clip.duration),
                                          source: held...held, speed: nil))
                continue
            }
            guard clip.isFootage else { continue }
            let from = max(source.lowerBound, clip.sourceStart.seconds)
            let to = min(source.upperBound, clip.sourceEnd.seconds)
            guard to > from else { continue }
            let start = elapsed + CMTime(seconds: (from - clip.sourceStart.seconds) / clip.speed, preferredTimescale: 60_000)
            let end = elapsed + CMTime(seconds: (to - clip.sourceStart.seconds) / clip.speed, preferredTimescale: 60_000)
            pieces.append(SourcePiece(range: CMTimeRange(start: start, end: end), source: from...to, speed: clip.speed))
        }
        return pieces
    }
}

// MARK: - Commands

public extension Commands {
    /// Several masks added at once, as one edit: hiding everything a scan found is one
    /// decision, and one Undo takes it all back.
    struct AddMasks: TimelineCommand {
        public let regions: [BlurRegion]
        public let name: String

        public init(_ regions: [BlurRegion], name: String) {
            self.regions = regions
            self.name = name
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard !regions.isEmpty else { return false }
            timeline.blurs += regions
            return true
        }
    }
}
