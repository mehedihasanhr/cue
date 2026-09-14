import CoreGraphics
import CoreVideo
import Foundation

/// A plain RGBA8 bitmap. `Sendable`, so frames can be handed to the concurrent
/// stitching work without touching `CGImage` off the main actor.
nonisolated struct Bitmap: Sendable {
    let width: Int
    let height: Int
    /// Byte order of each pixel: RGBA (drawn via CoreGraphics) or BGRA (straight from a
    /// ScreenCaptureKit frame). Row comparisons don't care; `cgImage` does.
    let bgra: Bool
    var data: Data

    var bytesPerRow: Int { width * 4 }

    init(width: Int, height: Int, bgra: Bool = false) {
        self.width = width
        self.height = height
        self.bgra = bgra
        data = Data(count: width * height * 4)
    }

    /// Copies a 32BGRA pixel buffer into tightly packed rows.
    init?(pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        self.init(width: width, height: height, bgra: true)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * 4
        data.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                destination.baseAddress!.advanced(by: row * rowBytes)
                    .copyMemory(from: base.advanced(by: row * sourceBytesPerRow), byteCount: rowBytes)
            }
        }
    }

    init?(_ image: CGImage) {
        self.init(width: image.width, height: image.height)
        let width = self.width
        let height = self.height
        let bytesPerRow = self.bytesPerRow
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
    }

    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = bgra
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: info),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Joins vertically scrolled frames into one image by locating the overlap between
/// consecutive frames.
///
/// Rows are compared through two per-row signatures (brightness sum and horizontal
/// edge energy, both on a column subsample), which makes the search O(rows²) on
/// small integers. The winner is verified with a sampled pixel comparison. Sticky
/// headers/footers are detected relative to the found shift and dropped from the
/// later frame, so they appear once in the result.
nonisolated enum FrameStitcher {
    private struct Signature {
        let brightness: [Int32]
        let edges: [Int32]
    }

    private static let columnStride = 4
    private static let verificationThreshold = 26.0 // mean absolute channel difference, 0…255

    /// `true` when the two frames are (nearly) pixel-identical — i.e. the scroll did nothing.
    static func framesMatch(_ a: Bitmap, _ b: Bitmap) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        return sampledDifference(a, rowsFrom: 0, b, rowsFrom: 0, count: a.height) < 2.0
    }

    /// Where two consecutive frames overlap and where to place the seam between them.
    struct Match: Sendable {
        /// Rows at the top of `next` that correspond to the bottom of `previous`
        /// (frame height − scroll distance).
        let overlap: Int
        /// Rows of `next` (from its top) that are *not* used — `previous` supplies that
        /// content instead. Sits in the middle of the overlap, clear of any sticky header.
        let header: Int
        /// Rows of `previous` (from its bottom) that are not used, clear of any sticky footer.
        let footer: Int
        let verified: Bool
    }

    /// Fraction of each frame's top / bottom never used for matching: sticky headers,
    /// tab bars and floating footers live there.
    static let topGuard = 0.15
    static let bottomGuard = 0.08

    /// Finds the scroll shift between `previous` and `next`.
    ///
    /// Rows inside the guard bands are ignored, so a sticky header never has to be
    /// detected — it simply doesn't take part. Scoring counts agreeing rows (misses
    /// penalised twice); tolerances are wide enough for text re-rasterised by a
    /// fractional scroll. Near-ties resolve towards `expected` (the previous shift),
    /// which keeps periodic content — repeated lines, chat bubbles — from snapping to the
    /// wrong period. The winner is verified row by row before it's accepted.
    static func overlap(previous: Bitmap, next: Bitmap, expected: Int) -> Match {
        let height = min(previous.height, next.height)
        let sigA = signature(previous)
        let sigB = signature(next)
        let samples = Double((previous.width + columnStride - 1) / columnStride)
        let top = Int(Double(height) * topGuard)
        let bottom = Int(Double(height) * bottomGuard)
        let minOverlap = top + bottom + minMatchedRows
        let maxOverlap = height - 1
        let unverified = Match(overlap: 0, header: 0, footer: 0, verified: false)
        guard maxOverlap >= minOverlap else { return unverified }

        func rowsMatch(_ a: Int, _ b: Int) -> Bool {
            let difference = Double(abs(sigA.brightness[a] - sigB.brightness[b]) + abs(sigA.edges[a] - sigB.edges[b]))
            return difference / samples <= rowTolerance
        }

        // Rank shifts by the fraction of band rows that agree. Blank areas make many shifts
        // agree completely, so near-ties resolve towards the expected shift; shifts with
        // little evidence (a thin band) only count when nothing better exists.
        var candidates: [(overlap: Int, score: Double, band: Int)] = []
        for overlap in minOverlap...maxOverlap {
            let base = previous.height - overlap
            let band = overlap - top - bottom
            var matches = 0
            for k in top..<(overlap - bottom) where rowsMatch(base + k, k) {
                matches += 1
            }
            let ratio = Double(matches) / Double(band)
            guard matches >= minMatchedRows, ratio >= minMatchRatio else { continue }
            candidates.append((overlap, ratio, band))
        }
        let solid = candidates.filter { $0.band >= solidBand }
        guard let best = (solid.isEmpty ? candidates : solid).map(\.score).max() else { return unverified }

        candidates.sort { a, b in
            let aTie = a.score >= best - tieTolerance && (solid.isEmpty || a.band >= solidBand)
            let bTie = b.score >= best - tieTolerance && (solid.isEmpty || b.band >= solidBand)
            if aTie != bTie { return aTie }
            if aTie { return abs(a.overlap - expected) < abs(b.overlap - expected) }
            return a.score > b.score
        }
        if debug {
            print("candidates (top 12):", candidates.prefix(12).map { "o=\($0.overlap) r=\(String(format: "%.2f", $0.score)) b=\($0.band)" }.joined(separator: " "))
        }

        for (overlap, _, band) in candidates.prefix(maxVerifications) {
            let base = previous.height - overlap
            let bad = mismatchedRows(previous, rowsFrom: base + top, next, rowsFrom: top, count: band)
            let allowed = max(2, band * badRowPercent / 100)
            if debug { print("  verify o=\(overlap) band=\(band) bad=\(bad) allowed=\(allowed)") }
            if bad <= allowed {
                // Seam in the middle of the overlap, never inside a guard band.
                let seam = min(max(overlap / 2, top), max(top, overlap - bottom))
                return Match(overlap: overlap, header: seam, footer: overlap - seam, verified: true)
            }
        }
        return unverified
    }

    nonisolated(unsafe) static var debug = false
    private static let rowTolerance = 20.0
    private static let minMatchRatio = 0.55
    private static let minMatchedRows = 12
    private static let maxVerifications = 6
    private static let badRowPercent = 8
    private static let tieTolerance = 0.03
    private static let solidBand = 40

    /// Number of rows in the range whose sampled pixel difference exceeds the threshold.
    private static func mismatchedRows(
        _ a: Bitmap, rowsFrom rowA: Int, _ b: Bitmap, rowsFrom rowB: Int, count: Int
    ) -> Int {
        var bad = 0
        for k in 0..<count where sampledDifference(a, rowsFrom: rowA + k, b, rowsFrom: rowB + k, count: 1) > verificationThreshold {
            bad += 1
        }
        return bad
    }

    private static func rowsEqual(_ a: Bitmap, _ rowA: Int, _ b: Bitmap, _ rowB: Int) -> Bool {
        guard rowA >= 0, rowB >= 0, rowA < a.height, rowB < b.height else { return false }
        return sampledDifference(a, rowsFrom: rowA, b, rowsFrom: rowB, count: 1) < 2.0
    }

    /// Rows of `previous` to keep (frame coordinates, exclusive end) when `next` follows it:
    /// everything above the overlap, plus the content that `next`'s sticky header hides,
    /// but never `previous`'s own sticky footer.
    static func keptEnd(ofPreviousHeight height: Int, match: Match) -> Int {
        min(height - match.overlap + match.header, height - match.footer)
    }

    /// Composes the frames top to bottom (batch variant of the incremental engine).
    @concurrent
    static func stitch(_ frames: [Bitmap], expectedOverlap: Int) async -> Bitmap? {
        guard let first = frames.first else { return nil }
        var pieces = [StitchPiece(frame: first, from: 0, rows: first.height)]
        for frame in frames.dropFirst() where frame.width == first.width {
            let previous = pieces[pieces.count - 1]
            if framesMatch(previous.frame, frame) { continue }
            let match = overlap(previous: previous.frame, next: frame, expected: expectedOverlap)
            guard match.verified else { continue }
            let end = keptEnd(ofPreviousHeight: previous.frame.height, match: match)
            pieces[pieces.count - 1].rows = max(0, end - previous.from)
            pieces.append(StitchPiece(frame: frame, from: match.header, rows: frame.height - match.header))
        }
        return compose(pieces)
    }

    /// Copies the rows each piece contributes into one tall bitmap.
    static func compose(_ pieces: [StitchPiece]) -> Bitmap? {
        guard let first = pieces.first?.frame else { return nil }
        let width = first.width
        let totalHeight = pieces.reduce(0) { $0 + $1.rows }
        guard totalHeight > 0 else { return nil }
        var output = Bitmap(width: width, height: totalHeight, bgra: first.bgra)
        let bytesPerRow = width * 4
        var destinationRow = 0
        output.data.withUnsafeMutableBytes { destination in
            for piece in pieces where piece.rows > 0 && piece.frame.width == width {
                piece.frame.data.withUnsafeBytes { source in
                    let sourceOffset = piece.from * bytesPerRow
                    let destinationOffset = destinationRow * bytesPerRow
                    let count = piece.rows * bytesPerRow
                    destination.baseAddress!.advanced(by: destinationOffset)
                        .copyMemory(from: source.baseAddress!.advanced(by: sourceOffset), byteCount: count)
                }
                destinationRow += piece.rows
            }
        }
        return output
    }

    // MARK: - Internals

    private static func signature(_ bitmap: Bitmap) -> Signature {
        var brightness = [Int32](repeating: 0, count: bitmap.height)
        var edges = [Int32](repeating: 0, count: bitmap.height)
        let width = bitmap.width
        let bytesPerRow = bitmap.bytesPerRow
        bitmap.data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for row in 0..<bitmap.height {
                let rowStart = row * bytesPerRow
                var sum: Int32 = 0
                var edge: Int32 = 0
                var previous: Int32 = -1
                var x = 0
                while x < width {
                    let index = rowStart + x * 4
                    let value = Int32(bytes[index]) + Int32(bytes[index + 1]) + Int32(bytes[index + 2])
                    sum += value
                    if previous >= 0 { edge += abs(value - previous) }
                    previous = value
                    x += columnStride
                }
                brightness[row] = sum
                edges[row] = edge
            }
        }
        return Signature(brightness: brightness, edges: edges)
    }

    /// Mean absolute per-channel difference over a sparse sample of the given row ranges.
    private static func sampledDifference(
        _ a: Bitmap, rowsFrom rowA: Int, _ b: Bitmap, rowsFrom rowB: Int, count: Int
    ) -> Double {
        guard count > 0, a.width == b.width else { return .greatestFiniteMagnitude }
        let width = a.width
        let bytesPerRow = a.bytesPerRow
        let rowStep = max(1, count / 48)
        var total = 0
        var samples = 0
        a.data.withUnsafeBytes { bufferA in
            b.data.withUnsafeBytes { bufferB in
                let bytesA = bufferA.bindMemory(to: UInt8.self)
                let bytesB = bufferB.bindMemory(to: UInt8.self)
                var k = 0
                while k < count {
                    let offsetA = (rowA + k) * bytesPerRow
                    let offsetB = (rowB + k) * bytesPerRow
                    var x = 0
                    while x < width {
                        let ia = offsetA + x * 4
                        let ib = offsetB + x * 4
                        total += abs(Int(bytesA[ia]) - Int(bytesB[ib]))
                        total += abs(Int(bytesA[ia + 1]) - Int(bytesB[ib + 1]))
                        total += abs(Int(bytesA[ia + 2]) - Int(bytesB[ib + 2]))
                        samples += 3
                        x += 3
                    }
                    k += rowStep
                }
            }
        }
        return samples == 0 ? .greatestFiniteMagnitude : Double(total) / Double(samples)
    }
}
