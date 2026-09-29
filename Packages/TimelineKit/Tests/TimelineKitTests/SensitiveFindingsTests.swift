import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// From what was read on each sampled frame to masks on the timeline: stretches, their
/// places, and how they meet an edit that has cut, sped up and frozen the footage.
@Suite("Sensitive findings")
struct SensitiveFindingsTests {
    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private func email(_ rect: CGRect, _ text: String = "jane.doe@example.com") -> SensitiveDetection {
        SensitiveDetection(kind: .email, text: text, rect: rect)
    }

    private let box = CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.04)

    /// Samples every half second from 0 to `count - 1`, with what `detections` says was on
    /// each.
    private func samples(_ count: Int, _ detections: (Int) -> [SensitiveDetection]) -> [SensitiveSample] {
        (0..<count).map { SensitiveSample(time: Double($0) * 0.5, detections: detections($0)) }
    }

    private func close(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 1e-6) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // MARK: - Grouping

    @Test("The same text on consecutive samples is one stretch, with the samples either side")
    func oneStretch() throws {
        let stretches = SensitiveGrouping.stretches(in: samples(10) { (2...6).contains($0) ? [email(box)] : [] })
        #expect(stretches.count == 1)
        let stretch = try #require(stretches.first)
        #expect(stretch.kind == .email)
        #expect(stretch.sightings.map(\.time) == [1, 1.5, 2, 2.5, 3])
        #expect(stretch.unseenBefore == 0.5)
        #expect(stretch.unseenAfter == 3.5)
    }

    @Test("There from the first sample, or to the last, has nothing unseen on that side")
    func toTheEnds() throws {
        let stretch = try #require(SensitiveGrouping.stretches(in: samples(4) { _ in [email(box)] }).first)
        #expect(stretch.unseenBefore == nil)
        #expect(stretch.unseenAfter == nil)
    }

    @Test("One missed sample is bridged, halfway between; two are a new stretch")
    func bridging() throws {
        let moving = { (i: Int) in self.box.offsetBy(dx: 0, dy: CGFloat(i) * 0.02) }
        let bridged = SensitiveGrouping.stretches(in: samples(8) { $0 == 3 ? [] : [email(moving($0))] })
        #expect(bridged.count == 1)
        let missed = try #require(bridged.first?.sightings.first { $0.time == 1.5 })
        #expect(close(missed.rect, moving(3)))

        let split = SensitiveGrouping.stretches(in: samples(8) { (3...4).contains($0) ? [] : [email(box)] })
        #expect(split.count == 2)
        #expect(split[0].unseenAfter == 1.5)
        #expect(split[1].unseenBefore == 2)
    }

    @Test("The same address twice on a scrolling page is two stretches, each keeping to its own")
    func twoCopies() {
        let stretches = SensitiveGrouping.stretches(in: samples(6) { i in
            let dy = CGFloat(i) * 0.05
            // Handed over in a different order each sample: nearness decides, not order.
            let top = email(CGRect(x: 0.1, y: 0.1 + dy, width: 0.2, height: 0.04))
            let bottom = email(CGRect(x: 0.1, y: 0.6 + dy, width: 0.2, height: 0.04))
            return i.isMultiple(of: 2) ? [top, bottom] : [bottom, top]
        })
        #expect(stretches.count == 2)
        for stretch in stretches {
            let ys = stretch.sightings.map(\.rect.minY)
            #expect(zip(ys, ys.dropFirst()).allSatisfy { abs($1 - $0 - 0.05) < 1e-9 })
        }
    }

    @Test("A misread character is the same text; another address or another kind is not")
    func sameness() {
        let readings = ["jane.doe@example.com", "jane.doe@exarnple.com", "jane.doe@example.com", "jane.doe @example.com"]
        let one = SensitiveGrouping.stretches(in: samples(4) { [email(box, readings[$0])] })
        #expect(one.count == 1)
        #expect(one.first?.text == "jane.doe@example.com")

        let two = SensitiveGrouping.stretches(in: samples(4) { $0 < 2 ? [email(box, "jane@example.com")] : [email(box, "john@example.org")] })
        #expect(two.count == 2)

        let kinds = SensitiveGrouping.stretches(in: samples(4) {
            $0 < 2 ? [email(box)] : [SensitiveDetection(kind: .secret, text: "jane.doe@example.com", rect: box)]
        })
        #expect(kinds.count == 2)
    }

    @Test("A password field is one field however many dots have been typed")
    func growingDots() throws {
        let stretches = SensitiveGrouping.stretches(in: samples(5) { i in
            [SensitiveDetection(kind: .password, text: String(repeating: "•", count: 5 + i),
                                rect: CGRect(x: 0.3, y: 0.5, width: 0.02 * CGFloat(5 + i), height: 0.03))]
        })
        #expect(stretches.count == 1)
        let stretch = try #require(stretches.first)
        let finding = SensitiveFinding(stretch: stretch, start: 0, end: 2.5)
        #expect(!finding.moves, "a field growing to the right is still where it was")
        #expect(abs(finding.rect.width - 0.18) < 1e-9, "the mask covers the longest it got")
    }

    // MARK: - Where the mask goes

    @Test("Still text is one rectangle round every reading")
    func stillFinding() throws {
        let stretch = try #require(SensitiveGrouping.stretches(in: samples(4) { i in
            [email(box.offsetBy(dx: i.isMultiple(of: 2) ? 0.001 : -0.001, dy: 0))]
        }).first)
        let finding = SensitiveFinding(stretch: stretch, start: 0, end: 2)
        #expect(!finding.moves)
        #expect(close(finding.rect, box.insetBy(dx: -0.001, dy: 0)))
    }

    @Test("Moving text is a rectangle that moves from reading to reading")
    func movingFinding() throws {
        let place = { (i: Int) in self.box.offsetBy(dx: 0, dy: -0.06 * CGFloat(i)) }
        let stretch = try #require(SensitiveGrouping.stretches(in: samples(6) { i in [email(place(i))] }).first)
        let finding = SensitiveFinding(stretch: stretch, start: -0.1, end: 2.6)
        #expect(finding.moves)
        for (i, sighting) in stretch.sightings.enumerated() {
            #expect(close(finding.rect(atSource: sighting.time), place(i), 1e-9))
        }
        // Between two readings, in between.
        #expect(close(finding.rect(atSource: 0.25), box.offsetBy(dx: 0, dy: -0.03), 1e-9))
    }

    // MARK: - Against the edit

    private func finding(from start: Double, to end: Double, moving: Bool = false) -> SensitiveFinding {
        let sightings = stride(from: start + 0.05, to: end, by: 0.5).map { time in
            SensitiveSighting(time: time, rect: moving ? box.offsetBy(dx: 0, dy: -0.05 * time) : box)
        }
        let stretch = SensitiveStretch(kind: .email, text: "jane.doe@example.com", sightings: sightings,
                                       unseenBefore: nil, unseenAfter: nil)
        return SensitiveFinding(stretch: stretch, start: start, end: end)
    }

    private let videoSize = CGSize(width: 1_600, height: 900)

    @Test("Pieces are the edit's own ranges, with each piece's speed")
    func piecesAgree() {
        let timeline = Timeline(sourceDuration: t(20), clips: [
            Clip(sourceStart: t(0), sourceDuration: t(4)),
            Clip(sourceStart: t(8), sourceDuration: t(6), speed: 2),
            Clip(sourceStart: t(2), sourceDuration: t(3)),
        ])
        let source = 1.0...10.0
        let pieces = timeline.pieces(ofSource: source)
        #expect(pieces.map(\.range) == timeline.timelineRanges(ofSource: source))
        #expect(pieces.map(\.speed) == [1, 2, 1])
        #expect(pieces.map(\.source) == [1...4, 8...10, 2...5])
    }

    @Test("In an untouched edit: one mask, its stretch, padded the same pixels both ways")
    func plainMask() throws {
        let timeline = Timeline(sourceDuration: t(10))
        let masks = finding(from: 2, to: 5).masks(in: timeline, padding: 0.5, videoSize: videoSize, style: .cover)
        let mask = try #require(masks.first)
        #expect(masks.count == 1)
        #expect(abs(mask.start.seconds - 2) < 1e-4 && abs(mask.end.seconds - 5) < 1e-4)
        #expect(mask.style == .cover)
        #expect(mask.path == nil)
        let padY = 0.5 * box.height
        let padX = padY * videoSize.height / videoSize.width
        #expect(close(mask.rect, box.insetBy(dx: -padX, dy: -padY), 1e-9))
        // Equal in pixels.
        #expect(abs((box.minX - mask.rect.minX) * videoSize.width - (box.minY - mask.rect.minY) * videoSize.height) < 1e-6)
    }

    @Test("A mask at the edge of the picture stays inside it")
    func edgeMask() throws {
        var finding = finding(from: 0, to: 2)
        finding.rect = CGRect(x: 0, y: 0.97, width: 0.2, height: 0.03)
        let mask = try #require(finding.masks(in: Timeline(sourceDuration: t(10)), padding: 1, videoSize: videoSize,
                                              style: .gaussian).first)
        #expect(mask.rect.minX >= 0 && mask.rect.maxY <= 1 + 1e-9)
    }

    @Test("Cut in two by the edit: two masks, the moving path right on each side of the cut")
    func acrossACut() throws {
        var timeline = Timeline(sourceDuration: t(10))
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: t(3), end: t(4))))
        let found = finding(from: 1, to: 6, moving: true)
        let masks = found.masks(in: timeline, padding: 0, videoSize: videoSize, style: .gaussian)
        #expect(masks.count == 2)
        #expect(abs(masks[0].start.seconds - 1) < 1e-4 && abs(masks[0].end.seconds - 3) < 1e-4)
        #expect(abs(masks[1].start.seconds - 3) < 1e-4 && abs(masks[1].end.seconds - 5) < 1e-4)
        for sighting in found.sightings {
            guard let time = timeline.timelineTime(atSource: t(sighting.time)),
                  let mask = masks.first(where: { $0.contains(time) }) else { continue }
            #expect(close(mask.rect(at: time), found.rect(atSource: sighting.time), 1e-4), "at \(sighting.time)")
        }
    }

    @Test("Sped up: the path runs on the clip's clock")
    func spedUp() throws {
        let timeline = Timeline(sourceDuration: t(10), clips: [Clip(sourceStart: .zero, sourceDuration: t(10), speed: 2)])
        let found = finding(from: 2, to: 6, moving: true)
        let mask = try #require(found.masks(in: timeline, padding: 0, videoSize: videoSize, style: .gaussian).first)
        #expect(abs(mask.start.seconds - 1) < 1e-4 && abs(mask.duration.seconds - 2) < 1e-4)
        for sighting in found.sightings {
            let time = t(sighting.time / 2)
            #expect(close(mask.rect(at: time), found.rect(atSource: sighting.time), 1e-4))
        }
    }

    @Test("A freeze frame of it is hidden too, where it was at that moment")
    func frozen() throws {
        let timeline = Timeline(sourceDuration: t(10), clips: [
            Clip(sourceStart: .zero, sourceDuration: t(2)),
            .still(of: t(3), for: t(2)),
            Clip(sourceStart: t(8), sourceDuration: t(2)),
        ])
        let found = finding(from: 2.5, to: 4, moving: true)
        let masks = found.masks(in: timeline, padding: 0, videoSize: videoSize, style: .cover)
        let mask = try #require(masks.first)
        #expect(masks.count == 1)
        #expect(mask.start == t(2) && mask.duration == t(2))
        #expect(mask.path == nil)
        #expect(close(mask.rect, found.rect(atSource: 3), 1e-9))
        #expect(found.isShown(in: timeline))
    }

    @Test("Cut away, or only outside the crop: nothing to hide")
    func notShown() {
        var timeline = Timeline(sourceDuration: t(10), clips: [Clip(sourceStart: t(5), sourceDuration: t(5))])
        let found = finding(from: 1, to: 3)
        #expect(!found.isShown(in: timeline))
        #expect(found.masks(in: timeline, padding: 0.3, videoSize: videoSize, style: .cover).isEmpty)
        #expect(found.timelineRange(in: timeline) == nil)

        timeline = Timeline(sourceDuration: t(10))
        #expect(found.isShown(in: timeline))
        timeline.style.crop = CropRect(rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        #expect(!found.isShown(in: timeline))
        timeline.style.crop = CropRect(rect: CGRect(x: 0.3, y: 0, width: 0.7, height: 1))
        #expect(found.isShown(in: timeline), "half in the crop is still shown")
    }

    @Test("Masks already over it count as hiding it; a spotlight does not")
    func alreadyHidden() {
        var timeline = Timeline(sourceDuration: t(10))
        let found = finding(from: 2, to: 5)
        #expect(!found.isHidden(by: timeline.blurs, in: timeline))
        timeline.blurs = found.masks(in: timeline, padding: 0.2, videoSize: videoSize, style: .pixelate)
        #expect(found.isHidden(by: timeline.blurs, in: timeline))
        timeline.blurs = found.masks(in: timeline, padding: 0.2, videoSize: videoSize, style: .spotlight)
        #expect(!found.isHidden(by: timeline.blurs, in: timeline))
        // Covering only part of the time is not hiding it.
        timeline.blurs = [BlurRegion(start: t(2), duration: t(1), rect: box.insetBy(dx: -0.01, dy: -0.01))]
        #expect(!found.isHidden(by: timeline.blurs, in: timeline))
    }

    @Test("Hiding several is one edit")
    func addMasks() {
        var timeline = Timeline(sourceDuration: t(10))
        let masks = [finding(from: 1, to: 2), finding(from: 3, to: 4)].flatMap {
            $0.masks(in: timeline, padding: 0.2, videoSize: videoSize, style: .cover)
        }
        let command = Commands.AddMasks(masks, name: "Hide Sensitive Information")
        #expect(command.apply(to: &timeline))
        #expect(timeline.blurs.count == 2)
        #expect(!Commands.AddMasks([], name: "Hide Sensitive Information").apply(to: &timeline))
    }

    // MARK: - Kept

    @Test("A finding survives the file, with or without a path")
    func roundTrip() throws {
        for found in [finding(from: 1, to: 3), finding(from: 1, to: 3, moving: true)] {
            let data = try JSONEncoder().encode(found)
            #expect(try JSONDecoder().decode(SensitiveFinding.self, from: data) == found)
        }
    }

    @Test("A finding written with fields missing still reads")
    func lenient() throws {
        let json = #"{"kind":"phone","text":"+1 415 555 0132","start":2,"end":1,"sightings":[{"time":2,"rect":[[0.1,0.2],[0.3,0.04]]}],"path":{"keys":"nonsense"}}"#
        let found = try JSONDecoder().decode(SensitiveFinding.self, from: Data(json.utf8))
        #expect(found.kind == .phone)
        #expect(found.end == 2, "an end before the start is the start")
        #expect(found.path == nil)
        #expect(found.sightings.count == 1)
        let unknown = try JSONDecoder().decode(SensitiveFinding.self, from: Data(#"{"kind":"retina-scan"}"#.utf8))
        #expect(unknown.kind == .secret)
    }

    @Test("The cache keeps a scan until the video changes")
    func cache() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sensitive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = RecordingPackage(url: folder)
        let video = folder.appendingPathComponent("screen.mov")
        try Data("pretend".utf8).write(to: video)

        #expect(SensitiveScanCache.cached(in: package, source: video) == nil)
        let findings = [finding(from: 1, to: 3), finding(from: 4, to: 6, moving: true)]
        SensitiveScanCache.cache(findings, in: package, source: video)
        #expect(SensitiveScanCache.cached(in: package, source: video) == findings)

        try Data("another take".utf8).write(to: video)
        #expect(SensitiveScanCache.cached(in: package, source: video) == nil)
    }
}
