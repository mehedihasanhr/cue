import CoreGraphics
import Testing
@testable import RecordKit

/// A window's picture measured from a frame, so the file can be sized to it.
struct WindowPictureTests {
    /// A full-screen Chrome, as a real take reported it: the page window is 1512 × 861, but
    /// the frame holds the tab strip and toolbar above it as well, shrunk by 0.907 to fit
    /// 861 points of height. The file was sized to the page and recorded 140 points of
    /// black down the right. The picture itself is 1512 × 949.
    @Test func fullScreenChromeIsTallerThanItsPage() throws {
        let frame = FrameGeometry(screenRect: CGRect(x: 0, y: 121, width: 1512, height: 861),
                                  contentRect: CGRect(x: 0, y: 0, width: 1371.793433189392, height: 860.9999788999557),
                                  contentScale: 0.907271,
                                  scaleFactor: 2)
        let size = try #require(WindowPicture.size(of: frame))
        #expect(abs(size.width - 1512) < 1)
        #expect(abs(size.height - 949) < 1)
    }

    /// A window that fits its frame exactly measures as itself.
    @Test func windowThatFitsMeasuresAsItself() throws {
        let frame = FrameGeometry(screenRect: CGRect(x: 59, y: 35, width: 1301, height: 816),
                                  contentRect: CGRect(x: 0, y: 0, width: 1301, height: 816),
                                  contentScale: 1,
                                  scaleFactor: 2)
        #expect(WindowPicture.size(of: frame) == CGSize(width: 1301, height: 816))
    }

    /// A frame that doesn't say how it was scaled measures as nothing, and the file keeps
    /// the size the window reports.
    @Test func frameWithoutAScaleMeasuresAsNothing() {
        let frame = FrameGeometry(screenRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                                  contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                                  contentScale: 0,
                                  scaleFactor: 2)
        #expect(WindowPicture.size(of: frame) == nil)
    }
}

/// How many bits a second a recording is written at.
struct CaptureBitrateTests {
    /// A Retina MacBook screen at 60 fps. It used to come out at about 3 Mb/s — the
    /// formula divided a figure already in bits by eight — and a real 47 s take of this
    /// screen was 18 MB. Good is now about 25 Mb/s.
    @Test func retinaScreenAtSixtyIsRecordedAtTheIntendedRate() {
        let pixels = 3024 * 1722
        let good = CaptureQuality.good.bitrate(forPixels: pixels, frameRate: 60)
        #expect(good > 24_000_000 && good < 26_000_000)
        #expect(CaptureQuality.better.bitrate(forPixels: pixels, frameRate: 60) > good)
        #expect(CaptureQuality.best.bitrate(forPixels: pixels, frameRate: 60) > CaptureQuality.better.bitrate(forPixels: pixels, frameRate: 60))
    }

    /// Half the frames, half the bits; and never below the floor nor above the ceiling.
    @Test func followsTheFrameRateWithinItsLimits() {
        let pixels = 1920 * 1080
        #expect(CaptureQuality.good.bitrate(forPixels: pixels, frameRate: 30) * 2
                == CaptureQuality.good.bitrate(forPixels: pixels, frameRate: 60))
        #expect(CaptureQuality.good.bitrate(forPixels: 100, frameRate: 30) == 2_000_000)
        #expect(CaptureQuality.best.bitrate(forPixels: 7680 * 4320, frameRate: 120) == 120_000_000)
    }
}
