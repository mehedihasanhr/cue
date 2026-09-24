import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// Reading a recording's telemetry: where to zoom, and how the pointer should move.
struct AnalysisTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let frame = CGSize(width: 1_000, height: 1_000)

    private func clicks(_ moments: [(Double, Double, Double)]) -> [InputSample] {
        moments.map { .mouseDown(t: $0.0, button: 0, x: $0.1, y: $0.2) }
    }

    // MARK: - Zoom suggestions

    @Test func clicksInOnePlaceBecomeAZoomThere() {
        let suggester = ZoomSuggester(frameSize: frame)
        let regions = suggester.suggestions(cursor: [],
                                            input: clicks([(10, 500, 400), (10.8, 520, 410), (11.5, 480, 390)]),
                                            duration: time(60))
        #expect(regions.count == 1)
        let region = try! #require(regions.first)
        #expect(region.start.seconds < 10, "it starts before the click, so the move is over by then")
        #expect(region.end.seconds > 11.5)
        #expect(abs(region.center.x - 0.5) < 0.05)
        #expect(abs(region.center.y - 0.4) < 0.05)
    }

    @Test func clicksFarApartInTimeBecomeSeparateZooms() {
        let suggester = ZoomSuggester(frameSize: frame)
        let regions = suggester.suggestions(cursor: [],
                                            input: clicks([(5, 100, 100), (30, 800, 800)]),
                                            duration: time(60))
        #expect(regions.count == 2)
        #expect(regions[0].end < regions[1].start, "suggestions never overlap")
    }

    /// Clicking all over the screen is working across it, not a moment to be close to.
    @Test func clicksSpreadAcrossTheScreenSuggestNothing() {
        let suggester = ZoomSuggester(frameSize: frame)
        let regions = suggester.suggestions(cursor: [],
                                            input: clicks([(10, 10, 10), (10.5, 990, 990), (11, 20, 950)]),
                                            duration: time(60))
        #expect(regions.isEmpty)
    }

    @Test func aRecordingWithNoClicksSuggestsNothing() {
        let suggester = ZoomSuggester(frameSize: frame)
        #expect(suggester.suggestions(cursor: [], input: [], duration: time(60)).isEmpty)
    }

    @Test func aSuggestionNeverRunsPastTheEnd() {
        let suggester = ZoomSuggester(frameSize: frame)
        let regions = suggester.suggestions(cursor: [],
                                            input: clicks([(9.5, 500, 500)]),
                                            duration: time(10))
        #expect(regions.allSatisfy { $0.end <= time(10) })
    }

    @Test func overlappingSuggestionsAreMergedIntoOne() {
        let suggester = ZoomSuggester(frameSize: frame, tuning: .init(clusterGap: 0.5, holdAfter: 5))
        let regions = suggester.suggestions(cursor: [],
                                            input: clicks([(10, 500, 500), (11, 520, 520)]),
                                            duration: time(60))
        #expect(regions.count == 1, "two zooms fighting over the camera is never what was meant")
    }

    // MARK: - Zooming at what had focus

    private func focus(_ kind: FocusSample.Kind, at t: Double, _ rect: CGRect) -> FocusSample {
        FocusSample(t: t, kind: kind, rect: rect)
    }

    @Test func aFocusedTextFieldBecomesAZoomOntoIt() {
        let suggester = ZoomSuggester(frameSize: frame)
        let field = CGRect(x: 300, y: 200, width: 400, height: 24)
        let regions = suggester.suggestions(cursor: [], input: [],
                                            focus: [focus(.field, at: 10, field)],
                                            duration: time(60))
        let region = try! #require(regions.first)
        #expect(region.source == .field)
        #expect(abs(region.center.x - 0.5) < 0.01)
        #expect(abs(region.center.y - 0.212) < 0.01)
        #expect(region.scale > 1.25, "close enough in to be able to read it")
        #expect(region.start.seconds < 10, "the move is over by the time the caret lands")
        #expect(!region.followsCursor, "a field does not move while it has focus")
    }

    /// A field's width decides the scale, not its height — fitting a 24-point-tall
    /// field to the frame would be a microscope.
    @Test func aWideShortFieldIsFramedByItsWidth() {
        let suggester = ZoomSuggester(frameSize: frame)
        let regions = suggester.suggestions(cursor: [], input: [],
                                            focus: [focus(.field, at: 5, CGRect(x: 100, y: 100, width: 300, height: 20))],
                                            duration: time(60))
        let region = try! #require(regions.first)
        #expect(abs(region.scale - 2) < 0.01, "1000 x 0.6 / 300, not 1000 x 0.6 / 20")
    }

    @Test func somethingAlreadyFillingTheFrameIsNotZoomedInto() {
        let suggester = ZoomSuggester(frameSize: frame)
        let regions = suggester.suggestions(cursor: [], input: [],
                                            focus: [focus(.field, at: 5, CGRect(x: 0, y: 0, width: 980, height: 900))],
                                            duration: time(60))
        #expect(regions.isEmpty)
    }

    @Test func bringingAWindowForwardIsIgnoredUnlessAskedFor() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let quiet = ZoomSuggester(frameSize: frame)
        #expect(quiet.suggestions(cursor: [], input: [], focus: [focus(.window, at: 5, window)], duration: time(60)).isEmpty)

        let eager = ZoomSuggester(frameSize: frame, tuning: .init(followsWindows: true))
        let regions = eager.suggestions(cursor: [], input: [], focus: [focus(.window, at: 5, window)], duration: time(60))
        #expect(regions.first?.source == .window)
    }

    @Test func focusSuggestionsAreOffWhenTheyAreTurnedOff() {
        let suggester = ZoomSuggester(frameSize: frame, tuning: .init(followsFocus: false))
        let regions = suggester.suggestions(cursor: [], input: [],
                                            focus: [focus(.field, at: 5, CGRect(x: 300, y: 200, width: 400, height: 24))],
                                            duration: time(60))
        #expect(regions.isEmpty)
    }

    /// The whole point of recording both: clicking inside a field that just took focus
    /// is one moment, and the field knows its shape better than the click does.
    @Test func aClickInsideAFocusedFieldIsOneZoomAimedAtTheField() {
        let suggester = ZoomSuggester(frameSize: frame)
        let field = CGRect(x: 300, y: 200, width: 400, height: 24)
        let regions = suggester.suggestions(cursor: [],
                                            input: clicks([(10.2, 480, 210)]),
                                            focus: [focus(.field, at: 10, field)],
                                            duration: time(60))
        #expect(regions.count == 1, "two zooms fighting over the camera is never what was meant")
        let region = try! #require(regions.first)
        #expect(region.source == .field, "the more specific aim wins rather than being averaged away")
        #expect(abs(region.center.y - 0.212) < 0.01)
    }

    @Test func typingHoldsTheZoomUntilItStops() {
        let suggester = ZoomSuggester(frameSize: frame)
        let field = focus(.field, at: 10, CGRect(x: 300, y: 200, width: 400, height: 24))
        let keys: [InputSample] = stride(from: 10.5, through: 18, by: 0.3).map {
            .key(t: $0, modifiers: 0)
        }
        let quiet = try! #require(suggester.suggestions(cursor: [], input: [], focus: [field], duration: time(60)).first)
        let typed = try! #require(suggester.suggestions(cursor: [], input: keys, focus: [field], duration: time(60)).first)

        #expect(typed.end > quiet.end, "the camera stays while there is typing to watch")
        #expect(typed.source == .typing)
    }

    /// Tabbing through fields on the way to the one someone wants is one moment, not
    /// four: a camera that visited each would be unwatchable.
    @Test func focusPassingStraightThroughSomewhereIsNotAZoom() {
        let suggester = ZoomSuggester(frameSize: frame)
        let passed = (0..<4).map { focus(.field, at: 10 + Double($0) * 0.2, CGRect(x: 100 + Double($0) * 150, y: 100, width: 300, height: 24)) }
        let regions = suggester.suggestions(cursor: [], input: [], focus: passed, duration: time(60))
        #expect(regions.count == 1, "only the one focus came to rest on")
    }

    @Test func aFocusZoomStopsWhenTheNextThingTakesFocus() {
        let suggester = ZoomSuggester(frameSize: frame)
        let first = focus(.field, at: 10, CGRect(x: 100, y: 100, width: 300, height: 24))
        let second = focus(.field, at: 12, CGRect(x: 600, y: 700, width: 300, height: 24))
        let regions = suggester.suggestions(cursor: [], input: [], focus: [first, second], duration: time(60))
        #expect(regions.count == 2, "two fields, one after the other, are two moments")
        #expect(regions[0].end <= regions[1].start, "suggestions never overlap")
    }

    @Test func focusEventsPastTheEndAreLeftOut() {
        let suggester = ZoomSuggester(frameSize: frame)
        let regions = suggester.suggestions(cursor: [], input: [],
                                            focus: [focus(.field, at: 9.5, CGRect(x: 300, y: 200, width: 400, height: 24))],
                                            duration: time(10))
        #expect(regions.allSatisfy { $0.end <= time(10) })
    }

    // MARK: - Cursor track

    private func path(_ points: [(Double, Double, Double)]) -> [CursorSample] {
        points.map { CursorSample(t: $0.0, x: $0.1, y: $0.2, shape: .arrow) }
    }

    @Test func aPositionBetweenSamplesIsInterpolated() {
        let track = CursorTrack(samples: path([(0, 0, 0), (1, 100, 200)]))
        let middle = try! #require(track.position(at: 0.5))
        #expect(abs(middle.x - 50) < 0.001)
        #expect(abs(middle.y - 100) < 0.001)
    }

    @Test func beforeAndAfterTheTrackTheCursorStaysPut() {
        let track = CursorTrack(samples: path([(1, 10, 10), (2, 20, 20)]))
        #expect(track.position(at: 0)?.x == 10)
        #expect(track.position(at: 99)?.x == 20)
    }

    @Test func anEmptyTrackHasNoPosition() {
        #expect(CursorTrack(samples: []).position(at: 1) == nil)
    }

    /// Smoothing has to take the jitter out without leaving the pointer trailing behind
    /// where it really was — which is what a one-pass filter does.
    @Test func smoothingRemovesJitterWithoutLag() {
        var samples: [CursorSample] = []
        for index in 0..<100 {
            let t = Double(index) / 100
            let jitter = index.isMultiple(of: 2) ? 6.0 : -6.0
            samples.append(CursorSample(t: t, x: Double(index) + jitter, y: 0, shape: .arrow))
        }
        let raw = CursorTrack(samples: samples)
        let smooth = raw.smoothed(0.8)

        func wobble(_ track: CursorTrack) -> Double {
            let xs = track.samples.map(\.x)
            return zip(xs, xs.dropFirst()).map { abs($1 - $0) }.reduce(0, +)
        }
        #expect(wobble(smooth) < wobble(raw) / 2)

        let rawMid = try! #require(raw.position(at: 0.5))
        let smoothMid = try! #require(smooth.position(at: 0.5))
        #expect(abs(smoothMid.x - rawMid.x) < 8, "smoothed, not delayed")
    }

    @Test func smoothingByZeroChangesNothing() {
        let track = CursorTrack(samples: path([(0, 0, 0), (1, 100, 0), (2, 50, 0)]))
        #expect(track.smoothed(0).samples == track.samples)
    }

    @Test func aClickMakesThePointerBounceAndSettle() {
        let track = CursorTrack(samples: path([(0, 0, 0), (2, 0, 0)]),
                                input: [.mouseDown(t: 1, button: 0, x: 0, y: 0)])
        #expect(track.clickScale(at: 0.5) == 1, "nothing before the click")
        #expect(track.clickScale(at: 1.05) != 1, "something during it")
        #expect(abs(track.clickScale(at: 1.9) - 1) < 0.01, "settled by the end")
    }
}
