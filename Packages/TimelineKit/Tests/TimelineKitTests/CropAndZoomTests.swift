import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// A zoom and a crop agreeing about what is being pointed at.
///
/// A zoom's centre is a fraction of the picture, and a crop changes what the picture is.
/// Two things went wrong where they met: suggestions were aimed against the whole recording
/// whatever the crop, and changing the crop left every existing zoom pointing at the same
/// fraction of a different picture.
struct CropAndZoomTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// 1600 × 1000 points of recording.
    private let frame = CGSize(width: 1_600, height: 1_000)
    private let rightHalf = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)

    private func click(at point: CGPoint, t: Double = 5) -> [InputSample] {
        [.mouseDown(t: t, button: 0, x: point.x, y: point.y)]
    }

    // MARK: - Suggesting

    @Test func withNoCropAClickInTheMiddleIsAimedAtTheMiddle() throws {
        let suggester = ZoomSuggester(frameSize: frame)
        let zoom = try #require(suggester.suggestions(cursor: [], input: click(at: CGPoint(x: 800, y: 500)),
                                                      duration: time(20)).first)
        #expect(abs(zoom.center.x - 0.5) < 0.001)
        #expect(abs(zoom.center.y - 0.5) < 0.001)
    }

    /// Three-quarters of the way across the recording is the middle of its right half.
    @Test func aClickIsAimedAtWhereItIsInTheCroppedPicture() throws {
        let suggester = ZoomSuggester(frameSize: frame, crop: rightHalf)
        let zoom = try #require(suggester.suggestions(cursor: [], input: click(at: CGPoint(x: 1_200, y: 500)),
                                                      duration: time(20)).first)
        #expect(abs(zoom.center.x - 0.5) < 0.001, "aimed at \(zoom.center.x) of the picture")
        #expect(abs(zoom.center.y - 0.5) < 0.001)
    }

    /// A click in the part that was cropped away is not in the picture, and a zoom onto
    /// something that is not in the picture is a zoom onto nothing.
    @Test func aClickThatWasCroppedAwayMakesNoZoom() {
        let suggester = ZoomSuggester(frameSize: frame, crop: rightHalf)
        let zooms = suggester.suggestions(cursor: [], input: click(at: CGPoint(x: 300, y: 500)),
                                          duration: time(20))
        #expect(zooms.isEmpty)
    }

    @Test func aCropThatCannotBeOneIsNoCrop() {
        #expect(ZoomSuggester(frameSize: frame, crop: .zero).crop == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: - Cropping afterwards

    private func timeline(zoomAt center: CGPoint) -> Timeline {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.zooms = [ZoomRegion(start: time(2), duration: time(3), scale: 2, center: center)]
        return timeline
    }

    /// Aimed at something three-quarters of the way across. Crop to the right half and it
    /// is the same thing, now in the middle of the picture.
    @Test func croppingReAimsAZoomAtWhatItWasAlreadyAimedAt() {
        var timeline = timeline(zoomAt: CGPoint(x: 0.75, y: 0.4))
        #expect(Commands.SetCrop(CropRect(rect: rightHalf)).apply(to: &timeline))
        #expect(abs(timeline.zooms[0].center.x - 0.5) < 0.0001)
        #expect(abs(timeline.zooms[0].center.y - 0.4) < 0.0001)
    }

    @Test func takingTheCropOffPutsItBack() {
        var timeline = timeline(zoomAt: CGPoint(x: 0.75, y: 0.4))
        Commands.SetCrop(CropRect(rect: rightHalf)).apply(to: &timeline)
        Commands.SetCrop(nil).apply(to: &timeline)
        #expect(abs(timeline.zooms[0].center.x - 0.75) < 0.0001)
        #expect(abs(timeline.zooms[0].center.y - 0.4) < 0.0001)
    }

    @Test func changingOneCropForAnotherGoesThroughTheRecording() {
        var timeline = timeline(zoomAt: CGPoint(x: 0.75, y: 0.5))
        Commands.SetCrop(CropRect(rect: rightHalf)).apply(to: &timeline)
        // The right three-quarters: the same place is two-thirds of the way across it.
        Commands.SetCrop(CropRect(rect: CGRect(x: 0.25, y: 0, width: 0.75, height: 1))).apply(to: &timeline)
        #expect(abs(timeline.zooms[0].center.x - 2.0 / 3) < 0.0001)
    }

    /// Something that has been cropped out of the picture cannot be pointed at. The zoom
    /// goes to the edge it left by rather than off the picture.
    @Test func aZoomOnSomethingCroppedAwayGoesToTheNearestEdge() {
        var timeline = timeline(zoomAt: CGPoint(x: 0.2, y: 0.5))
        Commands.SetCrop(CropRect(rect: rightHalf)).apply(to: &timeline)
        #expect(timeline.zooms[0].center.x == 0)
    }

    @Test func aCropThatChangesNothingIsNotAnEdit() {
        var timeline = timeline(zoomAt: CGPoint(x: 0.75, y: 0.4))
        #expect(!Commands.SetCrop(nil).apply(to: &timeline))
        #expect(timeline.zooms[0].center == CGPoint(x: 0.75, y: 0.4))
    }
}
