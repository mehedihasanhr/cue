import CoreGraphics
import XCTest

/// Stitching against a synthetic page: text-like rows, a blank gap, a repeating footer,
/// a sticky header and a fixed sidebar painted on every frame. Frames are exact
/// viewport slices, so the stitched result can be compared pixel for pixel.
final class FrameStitcherTests: XCTestCase {
    private static let width = 400
    private static let viewport = 600
    private static let pageHeight = 3000
    private static let headerRows = 40
    private static let sidebar = 320..<380
    private static let content = 40..<300
    private static let blankGap = 1200..<1400
    private static let footer = 2400..<3000
    private static let footerPeriod = 100

    // MARK: - Scenarios

    func testForwardScrollReproducesThePage() {
        let engine = ScrollingCaptureEngine()
        XCTAssertEqual(engine.ingest(frame(at: 0)), .first)
        var offset = 0
        for step in [150, 220, 90, 300, 180, 160, 110, 240, 200, 150, 300, 130] {
            offset = min(offset + step, Self.pageHeight - Self.viewport)
            XCTAssertEqual(engine.ingest(frame(at: offset)), .appended, "step to \(offset)")
        }
        while offset < Self.pageHeight - Self.viewport {
            offset = min(offset + 250, Self.pageHeight - Self.viewport)
            XCTAssertEqual(engine.ingest(frame(at: offset)), .appended, "step to \(offset)")
        }
        assertMatchesPage(engine)
    }

    func testAnimationWithoutScrollAddsNothing() {
        let engine = ScrollingCaptureEngine()
        _ = engine.ingest(frame(at: 0))
        for seed in 1...5 {
            XCTAssertEqual(engine.ingest(frame(at: 0, heroSeed: seed)), .unchanged, "animation frame \(seed)")
        }
        XCTAssertEqual(engine.frameCount, 1)
        XCTAssertEqual(engine.totalRows, Self.viewport)

        // Scrolling on from the animated look still works.
        XCTAssertEqual(engine.ingest(frame(at: 200, heroSeed: 5)), .appended)
        XCTAssertEqual(engine.totalRows, 800)
    }

    func testScrollingBackAndForthNeverDuplicates() {
        let engine = ScrollingCaptureEngine()
        _ = engine.ingest(frame(at: 0))
        for offset in [300, 600, 900] { XCTAssertEqual(engine.ingest(frame(at: offset)), .appended) }
        XCTAssertEqual(engine.totalRows, 1500)

        for offset in [600, 300, 700] { XCTAssertEqual(engine.ingest(frame(at: offset)), .covered, "back to \(offset)") }
        XCTAssertEqual(engine.totalRows, 1500)

        XCTAssertEqual(engine.ingest(frame(at: 1000)), .appended)
        XCTAssertEqual(engine.totalRows, 1600)
        assertMatchesPage(engine, rows: 1600)
    }

    func testRubberBandAtPageEndAddsNoContent() {
        let engine = ScrollingCaptureEngine()
        _ = engine.ingest(frame(at: 0))
        var offset = 0
        while offset < Self.pageHeight - Self.viewport {
            offset = min(offset + 300, Self.pageHeight - Self.viewport)
            _ = engine.ingest(frame(at: offset))
        }
        XCTAssertEqual(engine.totalRows, Self.pageHeight)

        // Over-scroll pulls the content up by 40 rows, exposing blank background below;
        // then it springs back. Nothing but (at most) that blank strip may be added.
        _ = engine.ingest(frame(at: offset, overscroll: 40))
        XCTAssertEqual(engine.ingest(frame(at: offset)), .covered)
        XCTAssertLessThanOrEqual(engine.totalRows, Self.pageHeight + 40)
        assertMatchesPage(engine, rows: Self.pageHeight)
    }

    func testRepeatingFooterInSmallStepsIsNotRepeated() {
        let engine = ScrollingCaptureEngine()
        _ = engine.ingest(frame(at: 0))
        var offset = 0
        while offset < 2100 {
            offset += 300
            _ = engine.ingest(frame(at: offset))
        }
        // Steps shorter than the footer's period, right through it.
        while offset < Self.pageHeight - Self.viewport {
            offset = min(offset + 60, Self.pageHeight - Self.viewport)
            let result = engine.ingest(frame(at: offset))
            XCTAssertTrue([.appended, .unmatched, .covered].contains(result), "\(result) at \(offset)")
        }
        XCTAssertLessThanOrEqual(engine.totalRows, Self.pageHeight)
        assertMatchesPage(engine, rows: engine.totalRows)
    }

    func testFixedSidebarDoesNotDisturbMatching() {
        let plain = ScrollingCaptureEngine()
        let decorated = ScrollingCaptureEngine()
        _ = plain.ingest(frame(at: 0, sidebar: false))
        _ = decorated.ingest(frame(at: 0, sidebar: true))
        for offset in [180, 420, 500, 760, 1000] {
            XCTAssertEqual(plain.ingest(frame(at: offset, sidebar: false)), .appended)
            XCTAssertEqual(decorated.ingest(frame(at: offset, sidebar: true)), .appended)
        }
        XCTAssertEqual(plain.totalRows, decorated.totalRows)
        assertMatchesPage(decorated, rows: 1600)
    }

    func testFrameOfDifferentSizeIsDropped() {
        let engine = ScrollingCaptureEngine()
        _ = engine.ingest(frame(at: 0))
        _ = engine.ingest(frame(at: 300))
        XCTAssertEqual(engine.ingest(Bitmap(width: Self.width, height: Self.viewport - 10)), .dropped)
        XCTAssertEqual(engine.totalRows, 900)
        XCTAssertEqual(engine.ingest(frame(at: 600)), .appended)
    }

    func testRecoversAfterLosingTrack() {
        let engine = ScrollingCaptureEngine()
        _ = engine.ingest(frame(at: 0))
        for offset in [300, 600, 900] { _ = engine.ingest(frame(at: offset)) }
        XCTAssertEqual(engine.totalRows, 1500)

        // Something unrelated fills the region (a modal, a different page)…
        for seed in 1...ScrollingCaptureEngine.resyncAfter {
            XCTAssertEqual(engine.ingest(noise(seed: seed)), .unmatched)
        }
        XCTAssertEqual(engine.totalRows, 1500, "nothing may be added while lost")

        // …then the user is back on captured content: relocated, and appends resume.
        XCTAssertEqual(engine.ingest(frame(at: 600)), .covered)
        XCTAssertEqual(engine.ingest(frame(at: 1000)), .appended)
        XCTAssertEqual(engine.totalRows, 1600)
        assertMatchesPage(engine, rows: 1600)
    }

    func testLocateFindsAFrameInsideAndOverhangingTheResult() {
        let stitched = Self.slice(of: page, rows: 0..<1000)
        XCTAssertEqual(FrameStitcher.locate(frame(at: 300, sidebar: false), in: stitched), 300)
        XCTAssertEqual(FrameStitcher.locate(frame(at: 700, sidebar: false), in: stitched), 700, "overhanging the end")
        XCTAssertNil(FrameStitcher.locate(noise(seed: 3), in: stitched))
    }

    // MARK: - Fixture

    /// Deterministic page: 4×6 px "glyph" cells in the content column, a blank gap, and a
    /// footer whose pattern repeats every `footerPeriod` rows.
    private lazy var page: Bitmap = {
        var bitmap = Bitmap(width: Self.width, height: Self.pageHeight)
        bitmap.data.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for y in 0..<Self.pageHeight {
                for x in 0..<Self.width {
                    let i = (y * Self.width + x) * 4
                    var shade: UInt8 = 255
                    if Self.content.contains(x), !Self.blankGap.contains(y) {
                        let row = Self.footer.contains(y) ? (y - Self.footer.lowerBound) % Self.footerPeriod + 100_000 : y
                        let line = row % 16 < 12 // 12 rows of glyphs, 4 rows of leading
                        if line, Self.hash(row / 4, x / 6) % 3 == 0 { shade = 30 }
                    }
                    bytes[i] = shade; bytes[i + 1] = shade; bytes[i + 2] = shade; bytes[i + 3] = 255
                }
            }
        }
        return bitmap
    }()

    private func frame(at offset: Int, sidebar: Bool = true, heroSeed: Int = 0, overscroll: Int = 0) -> Bitmap {
        var bitmap = Bitmap(width: Self.width, height: Self.viewport)
        bitmap.data.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            page.data.withUnsafeBytes { source in
                let src = source.bindMemory(to: UInt8.self)
                for y in 0..<Self.viewport {
                    let pageRow = offset + overscroll + y
                    for x in 0..<Self.width {
                        let i = (y * Self.width + x) * 4
                        var r: UInt8 = 255, g: UInt8 = 255, b: UInt8 = 255
                        if pageRow < Self.pageHeight {
                            let s = (pageRow * Self.width + x) * 4
                            r = src[s]; g = src[s + 1]; b = src[s + 2]
                        }
                        if y < Self.headerRows { // sticky header: a dark bar with a light pattern
                            (r, g, b) = Self.hash(y / 4, x / 10) % 4 == 0 ? (200, 200, 220) : (40, 40, 60)
                        } else if sidebar, Self.sidebar.contains(x) { // fixed widget column
                            (r, g, b) = Self.hash(y / 5, x / 5) % 5 == 0 ? (90, 120, 200) : (235, 238, 245)
                        }
                        if heroSeed > 0, (100..<400).contains(pageRow), (60..<260).contains(x) { // animated hero (page-anchored)
                            let v: UInt8 = Self.hash(pageRow / 8 + heroSeed * 977, x / 8) % 2 == 0 ? 120 : 250
                            (r, g, b) = (v, UInt8(255 &- v), v)
                        }
                        bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
                    }
                }
            }
        }
        return bitmap
    }

    private func noise(seed: Int) -> Bitmap {
        var bitmap = Bitmap(width: Self.width, height: Self.viewport)
        bitmap.data.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for y in 0..<Self.viewport {
                for x in 0..<Self.width {
                    let i = (y * Self.width + x) * 4
                    let v = UInt8(truncatingIfNeeded: Self.hash(y * 31 + seed * 7919, x))
                    bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
                }
            }
        }
        return bitmap
    }

    private static func slice(of bitmap: Bitmap, rows: Range<Int>) -> Bitmap {
        var out = Bitmap(width: bitmap.width, height: rows.count)
        let bytesPerRow = bitmap.bytesPerRow
        out.data = bitmap.data.subdata(in: rows.lowerBound * bytesPerRow..<rows.upperBound * bytesPerRow)
        return out
    }

    private static func hash(_ a: Int, _ b: Int) -> Int {
        var h = UInt64(truncatingIfNeeded: a) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(truncatingIfNeeded: b) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= h >> 29; h &*= 0xBF58_476D_1CE4_E5B9; h ^= h >> 32
        return Int(h & 0x7FFF_FFFF)
    }

    /// The stitched content column must equal the page row for row (below the first
    /// frame's sticky header; the sidebar and header are per-frame decoration).
    private func assertMatchesPage(_ engine: ScrollingCaptureEngine, rows: Int? = nil, file: StaticString = #filePath, line: UInt = #line) {
        guard let composed = engine.compose() else { return XCTFail("nothing composed", file: file, line: line) }
        let rows = rows ?? Self.pageHeight
        XCTAssertGreaterThanOrEqual(composed.height, rows, "stitched height", file: file, line: line)
        var mismatched = 0
        composed.data.withUnsafeBytes { c in
            page.data.withUnsafeBytes { p in
                let cb = c.bindMemory(to: UInt8.self), pb = p.bindMemory(to: UInt8.self)
                for y in Self.headerRows..<min(rows, composed.height) {
                    for x in Self.content {
                        let i = (y * Self.width + x) * 4
                        if cb[i] != pb[i] { mismatched += 1 }
                    }
                }
            }
        }
        XCTAssertEqual(mismatched, 0, "content pixels differ from the page", file: file, line: line)
    }
}
