import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// Reading back where a resized window's picture sat, and the part of the frame to show so
/// the black round it is never seen.
struct PictureTrackTests {
    private let frame = CGSize(width: 1_512, height: 861)
    /// The same window at half the size, in the top-left corner: the shape unchanged.
    private let half = CGRect(x: 0, y: 0, width: 756, height: 430.5)
    /// The real take's: made taller, shrunk by 0.907 to fit the height, a band down the right.
    private let taller = CGRect(x: 0, y: 0, width: 1_371.8, height: 861)

    private func track(_ samples: (Double, CGRect)...) -> PictureTrack {
        PictureTrack(samples: samples.map { PictureSample(t: $0.0, rect: $0.1) })
    }

    // MARK: - When

    @Test func anEmptyTrackIsTheWholeFrameEverywhere() {
        let empty = PictureTrack()
        #expect(empty.picture(at: 3) == nil)
        #expect(empty.shown(at: 3, in: frame) == CGRect(origin: .zero, size: frame))
        #expect(empty.place(CGPoint(x: 40, y: 50), at: 3, in: frame) == CGPoint(x: 40, y: 50))
    }

    @Test func eachSampleHoldsUntilTheNext() {
        let track = track((4, half), (2, taller), (6, CGRect(origin: .zero, size: frame)))
        #expect(track.picture(at: 1) == nil, "before the first change the picture filled the frame")
        #expect(track.picture(at: 2) == taller, "the frame the change was dated by already shows it")
        #expect(track.picture(at: 3.9) == taller)
        #expect(track.picture(at: 4) == half)
        #expect(track.picture(at: 100) == CGRect(origin: .zero, size: frame))
    }

    // MARK: - What is shown

    @Test func aPictureOfTheFramesShapeIsShownWhole() {
        #expect(PictureTrack.filling(half, frame: frame) == half)
    }

    /// Filled evenly, a strip off the top and the bottom, rather than stretched or left
    /// with its band.
    @Test func aPictureOfAnotherShapeFillsTheFrameWithoutStretching() {
        let shown = PictureTrack.filling(taller, frame: frame)
        #expect(abs(shown.width / shown.height - frame.width / frame.height) < 1e-9, "never stretched")
        #expect(shown.width == taller.width, "the whole width of the picture is kept")
        #expect(abs(shown.minY - (taller.height - shown.height) / 2) < 1e-9, "centred on it")
        #expect(taller.contains(shown), "and nothing outside the picture — nothing black — is shown")
    }

    // MARK: - Placing what was recorded in the frame

    @Test func thePicturesCornersBecomeTheFramesCorners() {
        let track = track((0, half))
        #expect(track.place(CGPoint.zero, at: 1, in: frame) == .zero)
        let far = track.place(CGPoint(x: half.maxX, y: half.maxY), at: 1, in: frame)
        #expect(abs(far.x - frame.width) < 1e-9)
        #expect(abs(far.y - frame.height) < 1e-9)
    }

    @Test func aPointInTheBlackIsPlacedOutsideTheFrame() {
        let placed = track((0, half)).place(CGPoint(x: 1_000, y: 100), at: 1, in: frame)
        #expect(placed.x > frame.width)
    }

    @Test func aRectangleGrowsWithThePicture() {
        let placed = track((0, half)).place(CGRect(x: 100, y: 50, width: 200, height: 100), at: 1, in: frame)
        #expect(placed == CGRect(x: 200, y: 100, width: 400, height: 200))
    }

    // MARK: - Auto-zoom

    /// A click on the middle of a half-size picture is a click on the middle of what the
    /// viewer sees, and the zoom it suggests is aimed there — not at the quarter-way point
    /// where it sits in the recorded frame.
    @Test func aSuggestedZoomIsAimedWhereTheClickIsDrawn() throws {
        let suggester = ZoomSuggester(frameSize: frame, picture: track((0, half)))
        let zooms = suggester.suggestions(cursor: [],
                                          input: [.mouseDown(t: 5, button: 0, x: half.midX, y: half.midY)],
                                          duration: CMTime(seconds: 30, preferredTimescale: 600))
        let zoom = try #require(zooms.first)
        #expect(abs(zoom.center.x - 0.5) < 0.01)
        #expect(abs(zoom.center.y - 0.5) < 0.01)
    }

    @Test func aClickInTheBlackSuggestsNothing() {
        let suggester = ZoomSuggester(frameSize: frame, picture: track((0, half)))
        let zooms = suggester.suggestions(cursor: [],
                                          input: [.mouseDown(t: 5, button: 0, x: 1_200, y: 700)],
                                          duration: CMTime(seconds: 30, preferredTimescale: 600))
        #expect(zooms.isEmpty)
    }
}
