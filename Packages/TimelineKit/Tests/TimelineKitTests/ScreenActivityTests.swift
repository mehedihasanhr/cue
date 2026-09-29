import CoreGraphics
import Testing
@testable import TimelineKit

@Suite("Screen activity")
struct ScreenActivityTests {
    private let cells = 32 * 18
    private func frame(_ t: Double, _ value: UInt8, changing count: Int = 0) -> (time: Double, luma: [UInt8]) {
        var luma = [UInt8](repeating: 100, count: cells)
        for i in 0..<count { luma[i] = value }
        return (t, luma)
    }

    @Test("A still picture is still, and a caret's worth of change is still")
    func still() {
        let frames = (0..<20).map { frame(Double($0) * 0.25, $0.isMultiple(of: 2) ? 100 : 255, changing: 3) }
        #expect(ScreenActivity.changing(frames).isEmpty)
    }

    @Test("A page arriving is change, and close changes are one stretch")
    func pageArrives() {
        var frames = (0..<8).map { frame(Double($0) * 0.25, 100) }
        frames.append(frame(2.0, 200, changing: 200))
        frames.append(frame(2.25, 30, changing: 300))
        frames.append(frame(2.5, 30, changing: 300))
        frames.append(frame(2.75, 180, changing: 300))
        frames += (12..<30).map { frame(Double($0) * 0.25, 180, changing: 300) }
        let ranges = ScreenActivity.changing(frames)
        #expect(ranges.count == 1)
        #expect(ranges.first == 1.75...2.75)
    }

    @Test("Separate changes stay separate")
    func separate() {
        let frames = [frame(0, 100), frame(0.25, 200, changing: 100), frame(0.5, 200, changing: 100),
                      frame(0.75, 200, changing: 100), frame(1, 200, changing: 100), frame(1.25, 200, changing: 100),
                      frame(1.5, 50, changing: 100)]
        #expect(ScreenActivity.changing(frames) == [0...0.25, 1.25...1.5])
    }

    @Test("The picture is read as a small grey grid")
    func luma() throws {
        let context = try #require(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let image = try #require(context.makeImage())
        let luma = try #require(ScreenActivity.luma(of: image))
        #expect(luma.count == cells)
        #expect(luma.allSatisfy { $0 > 240 })
    }
}
