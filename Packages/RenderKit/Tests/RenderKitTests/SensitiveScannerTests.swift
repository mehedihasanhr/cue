import CoreGraphics
import CoreMedia
import CoreText
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// Finding sensitive text in footage where the truth is known: lines of text drawn on a
/// page, coming and going on known frames, some of them scrolling — written as H.264 and
/// read back the way a recording is. Every check is against where and when each line was
/// really drawn, and the decoys drawn beside them must not be found at all.
@Suite("Sensitive scanner", .serialized)
struct SensitiveScannerTests {
    private static let size = FollowingFootage.size
    private static let rate = Double(FollowingFootage.frameRate)

    /// A line of text on the page: what it says, where its top-left is, and on which frames.
    struct Item: Sendable {
        var text: String
        var origin: CGPoint
        var frames: Range<Int>
        var fontSize: CGFloat = 20
        /// Pixels the line has moved up by on a frame.
        var scroll: @Sendable (Int) -> CGFloat = { _ in 0 }
        /// The part of the line that is sensitive, when that is not all of it.
        var part: String?

        /// Where the sensitive part's letters are on a frame, in pixels, top-left origin.
        func box(at frame: Int) -> CGRect {
            let part = part ?? text
            let prefix = text.range(of: part).map { String(text[..<$0.lowerBound]) } ?? ""
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let before = width(prefix, nil, nil)
            let width = width(part, &ascent, &descent)
            let baseline = origin.y + fontSize - scroll(frame)
            return CGRect(x: origin.x + before, y: baseline - ascent, width: width, height: ascent + descent)
        }

        private func width(_ string: String, _ ascent: UnsafeMutablePointer<CGFloat>?,
                           _ descent: UnsafeMutablePointer<CGFloat>?) -> CGFloat {
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributed = NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), ascent, descent, nil))
        }
    }

    private static func footage(frames: Int, items: [Item]) -> FollowingFootage {
        FollowingFootage(frames: frames) { index in
            ({ context in
                context.setFillColor(CGColor(gray: 0.98, alpha: 1))
                context.fill(CGRect(origin: .zero, size: size))
                for item in items where item.frames.contains(index) {
                    FollowingFootage.text(item.text, in: context,
                                          at: CGPoint(x: item.origin.x, y: item.origin.y - item.scroll(index)),
                                          size: item.fontSize)
                }
            }, .zero)
        }
    }

    private static func scan(_ footage: FollowingFootage) async throws -> [SensitiveFinding] {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("footage.mov")
        try await footage.write(to: url)
        let clock = ContinuousClock()
        let began = clock.now
        let findings = try await SensitiveScanner.scan(videoURL: url)
        print("Sensitive scan · \(footage.frames) frames in \(clock.now - began)")
        return findings
    }

    private static func pixels(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }

    /// How much of `truth` a mask of `finding`, padded as the sheet pads by default,
    /// covers at `frame`: 1 is all of it.
    private static func coverage(_ finding: SensitiveFinding, _ truth: CGRect, at frame: Int, padding: Double = 0.35) -> Double {
        let timeline = Timeline(sourceDuration: CMTime(seconds: 60, preferredTimescale: 600))
        let time = CMTime(seconds: (Double(frame) + 0.5) / rate, preferredTimescale: 600_000)
        let masks = finding.masks(in: timeline, padding: padding, videoSize: size, style: .cover)
        guard let mask = masks.first(where: { $0.contains(time) }) else { return 0 }
        let shown = pixels(mask.rect(at: time))
        let inside = shown.intersection(truth)
        guard !inside.isNull else { return 0 }
        return (inside.width * inside.height) / (truth.width * truth.height)
    }

    // MARK: - A page of things, coming and going

    private static let card = "4242 4242 4242 4242"
    private static let key = "sk-" + "proj-" + "Xk9mQ2vLp8RtW3zN7bY4cH6jD1fG5sA0"

    private static let secrets: [(Item, SensitiveKind)] = [
        (Item(text: "jane.doe@example.com", origin: CGPoint(x: 60, y: 40), frames: 20..<130), .email),
        (Item(text: card, origin: CGPoint(x: 60, y: 100), frames: 0..<180), .card),
        (Item(text: "+1 (415) 555-0132", origin: CGPoint(x: 60, y: 160), frames: 61..<180), .phone),
        (Item(text: key, origin: CGPoint(x: 60, y: 220), frames: 95..<152, fontSize: 18), .secret),
        (Item(text: "192.168.1.24", origin: CGPoint(x: 60, y: 280), frames: 0..<180), .ipAddress),
        // A field's bullets on their own are too small for text recognition to call text
        // at all; beside their label they are read, as full stops.
        (Item(text: "Password    ••••••••••", origin: CGPoint(x: 60, y: 340), frames: 0..<180, part: "••••••••••"), .password),
        (Item(text: "DE89 3704 0044 0532 0130 00", origin: CGPoint(x: 60, y: 400), frames: 0..<180), .account),
    ]

    private static let decoys: [Item] = [
        "Version 10.15.7", "Updated 2024-09-29 10:30", "Total: $129.99", "The quick brown fox jumps over the lazy dog",
        "Build 2.1.0.4", "Order #1234567890", "Page 1 of 12", "a3f5c9e2b1d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2",
    ].enumerated().map { index, text in
        Item(text: text, origin: CGPoint(x: 700, y: 40 + 60 * CGFloat(index)), frames: 0..<180)
    }

    @Test("Finds each thing, when it is there and where, and none of the decoys")
    func page() async throws {
        let findings = try await Self.scan(Self.footage(frames: 180, items: Self.secrets.map(\.0) + Self.decoys))
        var hits = 0
        for (item, kind) in Self.secrets {
            let matching = findings.filter { $0.kind == kind }
            guard let finding = matching.first else {
                Issue.record("missed \(kind): \(item.text)")
                continue
            }
            hits += 1
            #expect(matching.count == 1, "\(kind) found once, not \(matching.count) times")
            #expect(!finding.moves, "\(kind) stays put")
            // On from its first frame to its last, and not much more than a margin either side.
            let first = Double(item.frames.lowerBound) / Self.rate
            let after = Double(item.frames.upperBound) / Self.rate
            #expect(finding.start <= first + 1e-6, "\(kind) covered from its first frame: \(finding.start) vs \(first)")
            #expect(finding.start >= first - 5 / Self.rate, "\(kind) not long before: \(finding.start) vs \(first)")
            #expect(finding.end >= after - 1e-6, "\(kind) covered to its last frame: \(finding.end) vs \(after)")
            #expect(finding.end <= after + 5 / Self.rate, "\(kind) not long after: \(finding.end) vs \(after)")
            for frame in [item.frames.lowerBound, (item.frames.lowerBound + item.frames.upperBound) / 2, item.frames.upperBound - 1] {
                #expect(Self.coverage(finding, item.box(at: frame), at: frame) > 0.97, "\(kind) covered at frame \(frame)")
            }
        }
        let falseAlarms = findings.filter { finding in !Self.secrets.contains { $0.1 == finding.kind } }
            + findings.filter { $0.kind == .secret && !$0.text.hasPrefix("sk-") }
        #expect(falseAlarms.isEmpty, "false alarms: \(falseAlarms.map(\.text))")
        print("Sensitive scan · page: \(hits) of \(Self.secrets.count) found, \(falseAlarms.count) false alarms, "
              + findings.map { "\($0.kind.rawValue) \(String(format: "%.3f–%.3f", $0.start, $0.end))" }.joined(separator: ", "))
    }

    @Test("Small text among a page of ordinary words: measured, and the common kinds found")
    func smallText() async throws {
        // Fourteen pixels — a 1× display's body text — each on a white box over a page of words.
        let items = Self.secrets.map { item, kind in
            var small = item
            small.fontSize = 14
            small.origin.x = 700
            return (small, kind)
        }
        let background = FollowingFootage.background
        let footage = FollowingFootage(frames: 180) { index in
            ({ context in
                FollowingFootage.draw(background, in: context, at: CGRect(origin: .zero, size: Self.size))
                for (item, _) in items where item.frames.contains(index) {
                    let line = Item(text: item.text, origin: item.origin, frames: item.frames, fontSize: item.fontSize)
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.fill(line.box(at: index).insetBy(dx: -12, dy: -8))
                    FollowingFootage.text(item.text, in: context, at: item.origin, size: item.fontSize)
                }
            }, .zero)
        }
        let findings = try await Self.scan(footage)
        let found = items.filter { item, kind in
            findings.contains { finding in
                finding.kind == kind
                    && Self.coverage(finding, item.box(at: item.frames.lowerBound), at: item.frames.lowerBound) > 0.9
            }
        }
        let missed = items.filter { _, kind in !found.contains { $0.1 == kind } }.map(\.1.rawValue)
        let expected = Set(items.map(\.1))
        let falseAlarms = findings.filter { !expected.contains($0.kind) }
        print("Sensitive scan · small text: \(found.count) of \(items.count) found, missed \(missed), "
              + "\(falseAlarms.count) false alarms \(falseAlarms.map(\.text))")
        for kind in [SensitiveKind.email, .card, .phone, .secret, .ipAddress] {
            #expect(found.contains { $0.1 == kind }, "\(kind) found in small text")
        }
        #expect(falseAlarms.isEmpty)
    }

    // MARK: - Moving

    @Test("A line scrolling steadily is covered on every frame")
    func steadyScroll() async throws {
        let email = Item(text: "hunter2@example.com", origin: CGPoint(x: 200, y: 600), frames: 0..<120,
                         scroll: { CGFloat($0) * 4 })
        let words = Item(text: "Nothing to see in this line at all", origin: CGPoint(x: 200, y: 660), frames: 0..<120,
                         scroll: { CGFloat($0) * 4 })
        let findings = try await Self.scan(Self.footage(frames: 120, items: [email, words]))
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.kind == .email)
        #expect(finding.moves)
        let worst = (0..<120).map { Self.coverage(finding, email.box(at: $0), at: $0) }.min() ?? 0
        print("Sensitive scan · steady scroll: worst coverage \(worst), \(finding.path?.keys.count ?? 0) keys")
        #expect(worst > 0.97)
    }

    @Test("A line scrolled in jumps between samples is covered on every frame, not only on the samples")
    func steppedScroll() async throws {
        // A wheel's clicks: 48 pixels at a time, every 7 frames — never on a sample's rhythm.
        let step: @Sendable (Int) -> CGFloat = { CGFloat($0 / 7) * 48 }
        let phone = Item(text: "Call +44 20 7946 0958 today", origin: CGPoint(x: 200, y: 620), frames: 0..<150, scroll: step,
                         part: "+44 20 7946 0958")
        let page = (0..<10).map { row in
            Item(text: "Row \(row) of an ordinary list of settings", origin: CGPoint(x: 200, y: 680 + 50 * CGFloat(row)),
                 frames: 0..<150, scroll: step)
        }
        let findings = try await Self.scan(Self.footage(frames: 150, items: [phone] + page))
        let finding = try #require(findings.first { $0.kind == .phone })
        #expect(findings.count == 1)
        #expect(finding.moves)
        let visible = (0..<150).filter { phone.box(at: $0).minY >= 0 }
        let covered = visible.map { Self.coverage(finding, phone.box(at: $0), at: $0) }
        let worst = covered.min() ?? 0
        print("Sensitive scan · stepped scroll: worst coverage \(worst) over \(visible.count) frames, "
              + "\(finding.path?.keys.count ?? 0) keys")
        #expect(worst > 0.95)
    }

    @Test("Cancelled, it stops and says so rather than finishing or failing")
    func cancels() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("footage.mov")
        try await Self.footage(frames: 180, items: Self.secrets.map(\.0)).write(to: url)
        let scan = Task { try await SensitiveScanner.scan(videoURL: url) }
        scan.cancel()
        await #expect(throws: CancellationError.self) { try await scan.value }
    }

    @Test("A file with no picture is a failure with a reason")
    func unreadable() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("not-a-movie.mov")
        try Data("nothing here".utf8).write(to: url)
        await #expect(throws: SensitiveScanner.Failure.self) { try await SensitiveScanner.scan(videoURL: url) }
    }

    // MARK: - The pieces

    @Test("An edge is found to the frame by halving")
    func edge() async throws {
        let step = 1.0 / 30
        let truth = 1.0 + 7 * step
        let found = try await SensitiveScanner.edge(from: 1, to: 1.5, step: step) { $0 >= truth - 1e-9 }
        #expect(found >= truth - 1e-9 && found - truth < 1.5 * step)
        let gone = try await SensitiveScanner.edge(from: 3, to: 2.5, step: step) { $0 <= 2.8 }
        #expect(gone <= 2.8 && 2.8 - gone < 1.5 * step)
    }

    @Test("The band read around an edge reaches back along the way the text was moving")
    func band() {
        let sightings = [SensitiveSighting(time: 1, rect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.03)),
                         SensitiveSighting(time: 1.5, rect: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.03))]
        let start = SensitiveScanner.searchBand(sightings, atStart: true)
        #expect(start.contains(0.6), "scrolling up, it was lower before")
        let end = SensitiveScanner.searchBand(sightings, atStart: false)
        #expect(end.contains(0.3), "and higher after")
    }

    @Test("A small change in a thumbnail is a change; the same thumbnail is not")
    func changes() {
        let a = [UInt8](repeating: 200, count: 100)
        var b = a
        #expect(!SensitiveScanner.changed(a, b))
        b[40] = 150
        #expect(SensitiveScanner.changed(a, b))
        b[40] = 195
        #expect(!SensitiveScanner.changed(a, b), "noise is not a change")
    }
}
