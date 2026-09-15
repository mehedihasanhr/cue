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

/// Joins vertically scrolled frames into one image by locating the shift between
/// consecutive frames.
///
/// Two frames are compared only on the columns that actually changed between them
/// (a fixed sidebar, a blank margin or the untouched part of the screen during an
/// animation drops out) and only on rows that carry detail (blank rows agree with
/// every shift). Rows are compared through per-row signatures (brightness sum and
/// horizontal edge energy on a column subsample), so the search over every shift —
/// up, down *and* zero — is O(rows²) on small integers. The winner must beat "did not
/// scroll" by a clear margin and is then verified pixel by pixel; when the evidence is
/// not conclusive the matcher says so instead of guessing. Sticky headers/footers live
/// in guard bands that never take part, and are dropped from the later frame so they
/// appear once in the result.
nonisolated enum FrameStitcher {
    /// What happened between two consecutive frames.
    enum Shift: Sendable, Equatable {
        /// Pixels changed (an animation, a hover state) but the page did not scroll.
        case none
        /// The page scrolled: `delta` > 0 means the content moved up (scrolled down),
        /// `delta` < 0 that it moved down. `seam` describes where to join the frames.
        case moved(delta: Int, seam: Seam)
        /// Not enough evidence to decide; wait for the next frame.
        case ambiguous
    }

    /// Where to join two overlapping frames.
    struct Seam: Sendable, Equatable {
        /// Rows shared by both frames (frame height − |scroll distance|).
        let overlap: Int
        /// Rows at the top of the *lower* frame that are not used — the upper frame
        /// supplies that content. Sits in the middle of the overlap, clear of any sticky header.
        let header: Int
        /// Rows at the bottom of the *upper* frame that are not used, clear of any sticky footer.
        let footer: Int
    }

    /// Fraction of each frame's top / bottom never used for matching: sticky headers,
    /// tab bars and floating footers live there.
    static let topGuard = 0.15
    static let bottomGuard = 0.08

    private static let columnStride = 4
    /// Per-channel mean difference above which a row pair is a pixel mismatch (0…255).
    private static let verificationThreshold = 26.0
    /// Signature difference per sampled column that still counts as the same row —
    /// wide enough for text re-rasterised by a fractional scroll.
    private static let rowTolerance = 20.0
    /// Edge energy per sampled column below which a row is blank and carries no evidence.
    private static let edgeFloor = 4
    private static let minMatchRatio = 0.6
    private static let minMatchedRows = 12
    /// A scroll must agree this much more than "no scroll" to be believed.
    private static let scrollMargin = 0.1
    /// Detailed rows still in place after the change for the page to count as not scrolled
    /// (a scroll moves every detailed row; an animation leaves most of them alone).
    private static let unchangedRatio = 0.2
    private static let maxVerifications = 6
    private static let badRowPercent = 4
    private static let tieTolerance = 0.03
    /// Sampled pixel change (sum of |ΔR|+|ΔG|+|ΔB|) that marks a column as changed.
    private static let staticColumnTolerance = 12
    /// Columns that must have changed for the frame pair to count as a scroll at all.
    private static let minActiveFraction = 0.05

    /// `true` when the two frames are (nearly) pixel-identical.
    static func framesMatch(_ a: Bitmap, _ b: Bitmap) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        return sampledDifference(a, rowsFrom: 0, b, rowsFrom: 0, count: a.height, columns: nil) < 2.0
    }

    /// The scroll between `previous` and `next`. `expected` (a distance, rows) only orders
    /// candidates that the evidence cannot separate — periodic content such as repeated
    /// lines or chat bubbles — and even then the choice is verified before it is accepted.
    static func shift(from previous: Bitmap, to next: Bitmap, expected: Int) -> Shift {
        guard previous.width == next.width, previous.height == next.height else { return .ambiguous }
        let height = previous.height
        let top = Int(Double(height) * topGuard)
        let bottom = Int(Double(height) * bottomGuard)
        let maxShift = height - (top + bottom + minMatchedRows)
        guard maxShift >= 1 else { return .ambiguous }

        // Only columns that changed carry information about the scroll. If almost nothing
        // changed, something moved on screen but the page did not.
        let columns = activeColumns(previous, next)
        let sampledColumns = (previous.width + columnStride - 1) / columnStride
        guard Double(columns.count) >= max(8, Double(sampledColumns) * minActiveFraction) else { return .none }

        let sigA = signature(previous, columns: columns)
        let sigB = signature(next, columns: columns)
        let samples = Double(columns.count)
        let floor = Int32(edgeFloor * columns.count)

        /// Fraction of detailed row pairs that agree when `next` is shifted by `delta`.
        func score(_ delta: Int) -> (ratio: Double, informative: Int)? {
            let offsetA = max(delta, 0), offsetB = max(-delta, 0)
            let overlap = height - abs(delta)
            var matches = 0, informative = 0
            for k in 0..<overlap {
                let a = offsetA + k, b = offsetB + k
                guard a >= top, b >= top, a < height - bottom, b < height - bottom else { continue }
                guard max(sigA.edges[a], sigB.edges[b]) >= floor else { continue }
                informative += 1
                let difference = Double(abs(sigA.brightness[a] - sigB.brightness[b]) + abs(sigA.edges[a] - sigB.edges[b]))
                if difference / samples <= rowTolerance { matches += 1 }
            }
            guard informative >= minMatchedRows else { return nil }
            return (Double(matches) / Double(informative), informative)
        }

        let still = score(0)?.ratio ?? 0
        var candidates: [(delta: Int, ratio: Double)] = []
        for delta in -maxShift...maxShift where delta != 0 {
            guard let scored = score(delta), scored.ratio >= minMatchRatio else { continue }
            candidates.append((delta, scored.ratio))
        }
        // "Did not scroll" is a candidate like any other, and wins ties: an animation
        // changes some rows, a scroll changes them all.
        guard let best = candidates.map(\.ratio).max(), best >= still + scrollMargin else {
            return still >= unchangedRatio ? .none : .ambiguous
        }

        // Candidates the scores cannot separate (within the tolerance) that are more than a
        // few rows apart are a periodic pattern; there the expected distance orders them.
        let leaders = candidates.filter { $0.ratio >= best - tieTolerance }
        let periodic = leaders.contains { abs(abs($0.delta) - abs(leaders[0].delta)) > 3 }
        candidates.sort { a, b in
            let aLeads = a.ratio >= best - tieTolerance, bLeads = b.ratio >= best - tieTolerance
            if aLeads != bLeads { return aLeads }
            if aLeads, periodic { return abs(abs(a.delta) - expected) < abs(abs(b.delta) - expected) }
            return a.ratio > b.ratio
        }
        if debug {
            print("still=\(String(format: "%.2f", still)) candidates (top 12):",
                  candidates.prefix(12).map { "d=\($0.delta) r=\(String(format: "%.2f", $0.ratio))" }.joined(separator: " "))
        }

        for candidate in candidates.prefix(maxVerifications) {
            let delta = candidate.delta
            let overlap = height - abs(delta)
            let band = overlap - top - bottom
            guard band > 0 else { continue }
            let bad = mismatchedRows(previous, rowsFrom: max(delta, 0) + top, next, rowsFrom: max(-delta, 0) + top,
                                     count: band, columns: columns)
            let allowed = max(2, band * badRowPercent / 100)
            if debug { print("  verify d=\(delta) band=\(band) bad=\(bad) allowed=\(allowed)") }
            if bad <= allowed {
                return .moved(delta: delta, seam: seam(overlap: overlap, top: top, bottom: bottom))
            }
        }
        // Rows agreed by signature but not by pixel — a look-alike, not a scroll.
        return still >= unchangedRatio ? .none : .ambiguous
    }

    /// Seam in the middle of the overlap, never inside a guard band.
    private static func seam(overlap: Int, top: Int, bottom: Int) -> Seam {
        let header = min(max(overlap / 2, top), max(top, overlap - bottom))
        return Seam(overlap: overlap, header: header, footer: overlap - header)
    }

    nonisolated(unsafe) static var debug = false

    // MARK: - Relocation

    /// Where `frame` sits inside `stitched` (its row 0 in stitched rows), searched over
    /// every position including ones that overhang either end, or `nil` when no position
    /// is convincing. Used to re-anchor after the frame-to-frame matcher lost track.
    static func locate(_ frame: Bitmap, in stitched: Bitmap) -> Int? {
        guard frame.width == stitched.width, stitched.height >= minMatchedRows else { return nil }
        let height = frame.height
        let top = Int(Double(height) * topGuard)
        let bottom = Int(Double(height) * bottomGuard)
        let columns = Array(stride(from: 0, to: frame.width, by: columnStride))
        let sigF = signature(frame, columns: columns)
        let sigS = signature(stitched, columns: columns)
        let samples = Double(columns.count)
        let floor = Int32(edgeFloor * columns.count)
        let minOverlap = top + bottom + minMatchedRows

        var candidates: [(position: Int, ratio: Double)] = []
        for position in -(height - minOverlap)...(stitched.height - minOverlap) {
            var matches = 0, informative = 0
            for k in top..<(height - bottom) {
                let s = position + k
                guard s >= 0, s < stitched.height, max(sigF.edges[k], sigS.edges[s]) >= floor else { continue }
                informative += 1
                let difference = Double(abs(sigF.brightness[k] - sigS.brightness[s]) + abs(sigF.edges[k] - sigS.edges[s]))
                if difference / samples <= rowTolerance { matches += 1 }
            }
            guard informative >= minMatchedRows else { continue }
            let ratio = Double(matches) / Double(informative)
            if ratio >= 0.8 { candidates.append((position, ratio)) }
        }
        guard let best = candidates.max(by: { $0.ratio < $1.ratio }) else { return nil }
        // A second, clearly separate position that scores nearly as well means the page
        // repeats itself here; better to stay lost than to guess.
        let rival = candidates.filter { abs($0.position - best.position) > 3 }.map(\.ratio).max() ?? 0
        guard rival + scrollMargin <= best.ratio else { return nil }

        let first = max(0, -best.position) + top
        let last = min(height - bottom, stitched.height - best.position)
        let band = last - first
        guard band >= minMatchedRows else { return nil }
        let bad = mismatchedRows(frame, rowsFrom: first, stitched, rowsFrom: best.position + first, count: band, columns: columns)
        return bad <= max(2, band * badRowPercent / 100) ? best.position : nil
    }

    // MARK: - Compose

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

    private struct Signature {
        let brightness: [Int32]
        let edges: [Int32]
    }

    /// Sampled columns (x positions) whose pixels differ between the two frames somewhere
    /// along ~48 sampled rows. Everything else is scenery that moved with neither frame.
    private static func activeColumns(_ a: Bitmap, _ b: Bitmap) -> [Int] {
        let width = a.width
        let bytesPerRow = a.bytesPerRow
        let rowStep = max(1, a.height / 48)
        var active: [Int] = []
        a.data.withUnsafeBytes { bufferA in
            b.data.withUnsafeBytes { bufferB in
                let bytesA = bufferA.bindMemory(to: UInt8.self)
                let bytesB = bufferB.bindMemory(to: UInt8.self)
                var x = 0
                while x < width {
                    var row = 0
                    columnLoop: while row < a.height {
                        let i = row * bytesPerRow + x * 4
                        let change = abs(Int(bytesA[i]) - Int(bytesB[i]))
                            + abs(Int(bytesA[i + 1]) - Int(bytesB[i + 1]))
                            + abs(Int(bytesA[i + 2]) - Int(bytesB[i + 2]))
                        if change > staticColumnTolerance {
                            active.append(x)
                            break columnLoop
                        }
                        row += rowStep
                    }
                    x += columnStride
                }
            }
        }
        return active
    }

    private static func signature(_ bitmap: Bitmap, columns: [Int]) -> Signature {
        var brightness = [Int32](repeating: 0, count: bitmap.height)
        var edges = [Int32](repeating: 0, count: bitmap.height)
        let bytesPerRow = bitmap.bytesPerRow
        bitmap.data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for row in 0..<bitmap.height {
                let rowStart = row * bytesPerRow
                var sum: Int32 = 0
                var edge: Int32 = 0
                var previous: Int32 = -1
                for x in columns {
                    let index = rowStart + x * 4
                    let value = Int32(bytes[index]) + Int32(bytes[index + 1]) + Int32(bytes[index + 2])
                    sum += value
                    if previous >= 0 { edge += abs(value - previous) }
                    previous = value
                }
                brightness[row] = sum
                edges[row] = edge
            }
        }
        return Signature(brightness: brightness, edges: edges)
    }

    /// Number of rows in the range whose sampled pixel difference exceeds the threshold.
    private static func mismatchedRows(
        _ a: Bitmap, rowsFrom rowA: Int, _ b: Bitmap, rowsFrom rowB: Int, count: Int, columns: [Int]
    ) -> Int {
        var bad = 0
        for k in 0..<count where sampledDifference(a, rowsFrom: rowA + k, b, rowsFrom: rowB + k, count: 1, columns: columns) > verificationThreshold {
            bad += 1
        }
        return bad
    }

    /// Mean absolute per-channel difference over a sparse sample of the given row ranges,
    /// on `columns` (or every third column when `nil`).
    private static func sampledDifference(
        _ a: Bitmap, rowsFrom rowA: Int, _ b: Bitmap, rowsFrom rowB: Int, count: Int, columns: [Int]?
    ) -> Double {
        guard count > 0, a.width == b.width else { return .greatestFiniteMagnitude }
        let columns = columns ?? Array(stride(from: 0, to: a.width, by: 3))
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
                    for x in columns {
                        let ia = offsetA + x * 4
                        let ib = offsetB + x * 4
                        total += abs(Int(bytesA[ia]) - Int(bytesB[ib]))
                        total += abs(Int(bytesA[ia + 1]) - Int(bytesB[ib + 1]))
                        total += abs(Int(bytesA[ia + 2]) - Int(bytesB[ib + 2]))
                        samples += 3
                    }
                    k += rowStep
                }
            }
        }
        return samples == 0 ? .greatestFiniteMagnitude : Double(total) / Double(samples)
    }
}
