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
        /// Rows of sticky UI found at the top of the frames.
        let stickyTop: Int
    }

    /// Fraction of a frame's top / bottom never used when relocating a lost frame in the
    /// whole result (sticky headers, tab bars and floating footers live there). Frame to
    /// frame, sticky bands are detected instead — see `stickyBands`.
    static let topGuard = 0.15
    static let bottomGuard = 0.08
    /// Rows at the very edges of a frame skipped frame to frame (partial rows, shadows).
    private static let edgeGuardPercent = 2
    /// A sticky band can take up to this much of the frame.
    private static let maxStickyPercent = 40
    /// Below this many detailed rows a candidate needs to be unrivalled to be trusted.
    private static let solidEvidence = 24

    private static let columnStride = 4
    /// Per-channel mean difference above which a row pair is a pixel mismatch (0…255).
    private static let verificationThreshold = 26.0
    /// Signature difference per sampled column that still counts as the same row —
    /// wide enough for text re-rasterised by a fractional scroll.
    private static let rowTolerance = 20.0
    /// Edge energy per sampled column below which a row is blank and carries no evidence.
    private static let edgeFloor = 4
    private static let minMatchRatio = 0.6
    private static let minMatchedRows = 8
    /// A scroll must agree this much more than "no scroll" to be believed.
    private static let scrollMargin = 0.1
    /// Detailed rows still in place after the change for the page to count as not scrolled
    /// (a scroll moves every detailed row; an animation leaves most of them alone).
    private static let unchangedRatio = 0.2
    private static let maxVerifications = 6
    /// Relocation is judged on what is left unchanged, so it tolerates an animated region.
    private static let relocateRatio = 0.45
    private static let relocateAgreement = 0.6
    /// Share of detailed blocks that must agree pixel-wise for a shift to be accepted.
    /// A fixed widget or an animation disqualifies only its own blocks.
    private static let minBlockAgreement = 0.7
    private static let blockRows = 32
    private static let blockColumns = 16
    private static let tieTolerance = 0.03
    /// Sampled pixel change (sum of |ΔR|+|ΔG|+|ΔB|) that marks a column as changed.
    private static let staticColumnTolerance = 12
    /// Share of the detailed columns that must have changed for the pair to count as a scroll.
    private static let minActiveFraction = 0.3
    /// Spread of a column's sampled values (sum of three channels) that marks it as detailed.
    private static let detailSpread = 60

    /// `true` when the two frames are (nearly) pixel-identical.
    static func framesMatch(_ a: Bitmap, _ b: Bitmap) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        return sampledDifference(a, rowsFrom: 0, b, rowsFrom: 0, count: a.height, columns: nil) < 2.0
    }

    /// The scroll between `previous` and `next`. Candidates the evidence cannot separate
    /// — periodic content such as repeated lines or chat bubbles — resolve to the smallest
    /// shift: at worst a repeating region comes out shorter, never repeated. Either way the
    /// choice is verified pixel-wise before it is accepted.
    static func shift(from previous: Bitmap, to next: Bitmap) -> Shift {
        guard previous.width == next.width, previous.height == next.height else { return .ambiguous }
        let height = previous.height
        let guardRows = max(2, height * edgeGuardPercent / 100)

        // Only columns that changed carry information about the scroll. If most of the
        // columns that hold any detail did not change, something moved on screen (a video
        // widget, a spinner) but the page did not.
        let (columns, detailed) = activeColumns(previous, next)
        guard columns.count >= 8, Double(columns.count) >= Double(detailed) * minActiveFraction else { return .none }

        let sigA = signature(previous, columns: columns)
        let sigB = signature(next, columns: columns)
        let samples = Double(columns.count)
        let floor = Int32(edgeFloor * columns.count)
        /// Signature difference (integer) that still counts as the same row.
        let rowBudget = Int32(rowTolerance * samples)
        /// Scoring reads every other row on tall frames: hundreds of votes either way.
        let rowStep = height > 800 ? 2 : 1

        // Per row: does it carry detail, and did it stay put (same row in both frames)?
        var informative = [Bool](repeating: false, count: height)
        var still = [Bool](repeating: false, count: height)
        var stillInformative = 0, stillMatches = 0
        for k in 0..<height {
            informative[k] = max(sigA.edges[k], sigB.edges[k]) >= floor
            let difference = Double(abs(sigA.brightness[k] - sigB.brightness[k]) + abs(sigA.edges[k] - sigB.edges[k]))
            still[k] = difference / samples <= rowTolerance
            if informative[k] {
                stillInformative += 1
                if still[k] { stillMatches += 1 }
            }
        }
        let stillRatio = stillInformative > 0 ? Double(stillMatches) / Double(stillInformative) : 0

        // Sticky bands are found, not assumed: the run of unmoved detailed rows at the top
        // (a navigation bar) and at the bottom (a cookie banner, a tab bar). Blank rows
        // inside the run are tolerated but do not extend it.
        let sticky = stickyBands(still: still, informative: informative, height: height)
        let low = sticky.top + guardRows
        let high = height - sticky.bottom - guardRows
        let maxShift = high - low - minMatchedRows
        guard maxShift >= 1 else { return stillRatio >= unchangedRatio ? .none : .ambiguous }

        /// Fraction of detailed row pairs that agree when `next` is shifted by `delta`.
        func score(_ delta: Int) -> (ratio: Double, informative: Int)? {
            let offsetA = max(delta, 0), offsetB = max(-delta, 0)
            let from = max(low - offsetA, low - offsetB, 0)
            let to = min(high - offsetA, high - offsetB)
            guard to - from >= minMatchedRows else { return nil }
            var matches = 0, count = 0
            sigA.brightness.withUnsafeBufferPointer { brightA in
                sigA.edges.withUnsafeBufferPointer { edgesA in
                    sigB.brightness.withUnsafeBufferPointer { brightB in
                        sigB.edges.withUnsafeBufferPointer { edgesB in
                            var k = from
                            while k < to {
                                let a = offsetA + k, b = offsetB + k
                                k += rowStep
                                guard max(edgesA[a], edgesB[b]) >= floor else { continue }
                                count += 1
                                let difference = abs(brightA[a] - brightB[b]) + abs(edgesA[a] - edgesB[b])
                                if difference <= rowBudget { matches += 1 }
                            }
                        }
                    }
                }
            }
            guard count * rowStep >= minMatchedRows else { return nil }
            return (Double(matches) / Double(count), count * rowStep)
        }

        var candidates: [(delta: Int, ratio: Double, informative: Int)] = []
        for delta in -maxShift...maxShift where delta != 0 {
            guard let scored = score(delta), scored.ratio >= minMatchRatio else { continue }
            candidates.append((delta, scored.ratio, scored.informative))
        }
        // "Did not scroll" is a candidate like any other, and wins ties: an animation
        // changes some rows, a scroll changes them all.
        guard let best = candidates.map(\.ratio).max(), best >= stillRatio + scrollMargin else {
            return stillRatio >= unchangedRatio ? .none : .ambiguous
        }

        // Candidates the scores cannot separate (within the tolerance) are a periodic
        // pattern; the smallest shift among them is the safe reading.
        candidates.sort { a, b in
            let aLeads = a.ratio >= best - tieTolerance, bLeads = b.ratio >= best - tieTolerance
            if aLeads != bLeads { return aLeads }
            if aLeads { return abs(a.delta) < abs(b.delta) }
            return a.ratio > b.ratio
        }
        if debug {
            print("still=\(String(format: "%.2f", stillRatio)) sticky=\(sticky) candidates (top 12):",
                  candidates.prefix(12).map { "d=\($0.delta) r=\(String(format: "%.2f", $0.ratio)) n=\($0.informative)" }.joined(separator: " "))
        }

        for candidate in candidates.prefix(maxVerifications) {
            let delta = candidate.delta
            let overlap = height - abs(delta)
            // The seam must keep the lower frame's sticky header and the upper frame's
            // sticky footer out of the result.
            guard sticky.top <= overlap - sticky.bottom else { continue }
            let offsetA = max(delta, 0), offsetB = max(-delta, 0)
            let from = max(low - offsetA, low - offsetB, 0)
            let to = min(high - offsetA, high - offsetB)
            guard to > from else { continue }
            // Thin evidence is accepted only when nothing else comes close.
            if candidate.informative < solidEvidence {
                let rival = candidates.filter { abs($0.delta - delta) > 3 }.map(\.ratio).max() ?? 0
                guard rival + scrollMargin <= candidate.ratio else { continue }
            }
            let agreement = blockAgreement(previous, rowsFrom: offsetA + from, next, rowsFrom: offsetB + from,
                                           count: to - from, columns: columns)
            if debug { print("  verify d=\(delta) rows=\(to - from) agreement=\(String(format: "%.2f", agreement))") }
            if agreement >= minBlockAgreement {
                let header = min(max(overlap / 2, sticky.top), overlap - sticky.bottom)
                return .moved(delta: delta, seam: Seam(overlap: overlap, header: header, footer: overlap - header, stickyTop: sticky.top))
            }
        }
        // Rows agreed by signature but not by pixel — a look-alike, not a scroll.
        return stillRatio >= unchangedRatio ? .none : .ambiguous
    }

    /// Rows of unmoved detail at the top and bottom of the frame pair (sticky UI).
    private static func stickyBands(still: [Bool], informative: [Bool], height: Int) -> (top: Int, bottom: Int) {
        let cap = height * maxStickyPercent / 100
        var top = 0, k = 0
        while k < cap, still[k] || !informative[k] {
            if informative[k] { top = k + 1 }
            k += 1
        }
        var bottom = 0
        k = height - 1
        while height - 1 - k < cap, still[k] || !informative[k] {
            if informative[k] { bottom = height - k }
            k -= 1
        }
        return (top, bottom)
    }

    nonisolated(unsafe) static var debug = false

    // MARK: - Relocation

    /// A stitched result prepared for repeated `locate` calls (its signatures are the
    /// expensive part and don't change while the engine is lost).
    struct LocateIndex: Sendable {
        fileprivate let stitched: Bitmap
        fileprivate let columns: [Int]
        fileprivate let signature: Signature

        init(_ stitched: Bitmap) {
            self.stitched = stitched
            columns = Array(stride(from: 0, to: stitched.width, by: columnStride))
            signature = FrameStitcher.signature(stitched, columns: columns)
        }
    }

    /// Where `frame` sits inside the indexed result (its row 0 in stitched rows), searched
    /// over every position including ones that overhang either end, or `nil` when no
    /// position is convincing. Used to re-anchor after the frame-to-frame matcher lost track.
    static func locate(_ frame: Bitmap, in index: LocateIndex) -> Int? {
        let stitched = index.stitched
        guard frame.width == stitched.width, stitched.height >= minMatchedRows else { return nil }
        let height = frame.height
        let top = Int(Double(height) * topGuard)
        let bottom = Int(Double(height) * bottomGuard)
        let columns = index.columns
        let sigF = signature(frame, columns: columns)
        let sigS = index.signature
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
            if ratio >= relocateRatio { candidates.append((position, ratio)) }
        }
        // Best first, one candidate per neighbourhood; the pixels decide, so a page whose
        // hero changed since it was captured (a carousel) is still found by the rest.
        candidates.sort { $0.ratio > $1.ratio }
        var tried: [Int] = []
        for candidate in candidates where !tried.contains(where: { abs($0 - candidate.position) <= 3 }) {
            tried.append(candidate.position)
            guard tried.count <= maxVerifications else { break }
            let first = max(0, -candidate.position) + top
            let last = min(height - bottom, stitched.height - candidate.position)
            let band = last - first
            guard band >= minMatchedRows else { continue }
            let agreement = blockAgreement(frame, rowsFrom: first, stitched, rowsFrom: candidate.position + first, count: band, columns: columns)
            if debug { print("  locate p=\(candidate.position) r=\(String(format: "%.2f", candidate.ratio)) agreement=\(String(format: "%.2f", agreement))") }
            if agreement >= relocateAgreement { return candidate.position }
        }
        return nil
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

    struct Signature: Sendable {
        fileprivate let brightness: [Int32]
        fileprivate let edges: [Int32]
    }

    /// Sampled columns (x positions) whose pixels differ between the two frames somewhere
    /// along ~48 sampled rows, plus how many sampled columns hold any detail at all.
    /// Everything else is scenery that moved with neither frame.
    private static func activeColumns(_ a: Bitmap, _ b: Bitmap) -> (active: [Int], detailed: Int) {
        let width = a.width
        let bytesPerRow = a.bytesPerRow
        let rowStep = max(1, a.height / 48)
        var active: [Int] = []
        var detailed = 0
        a.data.withUnsafeBytes { bufferA in
            b.data.withUnsafeBytes { bufferB in
                let bytesA = bufferA.bindMemory(to: UInt8.self)
                let bytesB = bufferB.bindMemory(to: UInt8.self)
                var x = 0
                while x < width {
                    var changed = false
                    var low = Int.max, high = Int.min
                    var row = 0
                    while row < a.height {
                        let i = row * bytesPerRow + x * 4
                        let valueA = Int(bytesA[i]) + Int(bytesA[i + 1]) + Int(bytesA[i + 2])
                        let valueB = Int(bytesB[i]) + Int(bytesB[i + 1]) + Int(bytesB[i + 2])
                        low = min(low, valueA, valueB)
                        high = max(high, valueA, valueB)
                        if !changed {
                            let change = abs(Int(bytesA[i]) - Int(bytesB[i]))
                                + abs(Int(bytesA[i + 1]) - Int(bytesB[i + 1]))
                                + abs(Int(bytesA[i + 2]) - Int(bytesB[i + 2]))
                            changed = change > staticColumnTolerance
                        }
                        row += rowStep
                    }
                    if changed { active.append(x) }
                    if high - low > detailSpread { detailed += 1 }
                    x += columnStride
                }
            }
        }
        return (active, detailed)
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

    /// Pixel verification of a shift, in blocks (`blockRows` × a slice of `columns`):
    /// the share of blocks with detail whose mean per-channel difference stays under
    /// `verificationThreshold`. Blank blocks carry no vote; a fixed or animated widget
    /// only loses the blocks it covers, and re-rasterised text averages out.
    private static func blockAgreement(
        _ a: Bitmap, rowsFrom rowA: Int, _ b: Bitmap, rowsFrom rowB: Int, count: Int, columns: [Int]
    ) -> Double {
        guard count > 0, !columns.isEmpty, a.width == b.width else { return 0 }
        let groups = min(blockColumns, columns.count)
        let columnsPerGroup = (columns.count + groups - 1) / groups
        let strips = (count + blockRows - 1) / blockRows
        var difference = [Int](repeating: 0, count: strips * groups)
        var detail = [Int](repeating: 0, count: strips * groups)
        var pixels = [Int](repeating: 0, count: strips * groups)
        let bytesPerRow = a.bytesPerRow
        let rowStep = count > 256 ? 2 : 1
        a.data.withUnsafeBytes { bufferA in
            b.data.withUnsafeBytes { bufferB in
                let bytesA = bufferA.bindMemory(to: UInt8.self)
                let bytesB = bufferB.bindMemory(to: UInt8.self)
                for k in stride(from: 0, to: count, by: rowStep) {
                    let strip = (k / blockRows) * groups
                    let offsetA = (rowA + k) * bytesPerRow
                    let offsetB = (rowB + k) * bytesPerRow
                    var previousA = -1, previousB = -1
                    for (index, x) in columns.enumerated() {
                        let block = strip + index / columnsPerGroup
                        let ia = offsetA + x * 4, ib = offsetB + x * 4
                        let ra = Int(bytesA[ia]), ga = Int(bytesA[ia + 1]), ba = Int(bytesA[ia + 2])
                        let rb = Int(bytesB[ib]), gb = Int(bytesB[ib + 1]), bb = Int(bytesB[ib + 2])
                        difference[block] += abs(ra - rb) + abs(ga - gb) + abs(ba - bb)
                        let valueA = ra + ga + ba, valueB = rb + gb + bb
                        if previousA >= 0 { detail[block] += max(abs(valueA - previousA), abs(valueB - previousB)) }
                        previousA = valueA; previousB = valueB
                        pixels[block] += 1
                    }
                }
            }
        }
        var informative = 0, agreeing = 0
        for block in 0..<(strips * groups) where pixels[block] > 0 {
            guard detail[block] >= edgeFloor * pixels[block] else { continue }
            informative += 1
            if Double(difference[block]) / Double(pixels[block] * 3) <= verificationThreshold { agreeing += 1 }
        }
        guard informative > 0 else { return 0 }
        return Double(agreeing) / Double(informative)
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
