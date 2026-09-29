import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// Freeze frames, title slides and transitions: what a frame is described as, and what
/// it comes out looking like.
struct ClipSceneTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// 1600 × 1000 at padding 0.1: the frame is 1280 × 800, at (160, 100).
    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 2)
    }

    private func timeline(seconds: Double = 30) -> Timeline {
        var timeline = Timeline(sourceDuration: time(seconds))
        timeline.style.padding = 0.1
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.style.background = .color(ColorValue(r: 0, g: 0, b: 1))
        timeline.cursor.smoothing = 0
        return timeline
    }

    /// A pointer that moves steadily right, and clicks at ten seconds.
    private func track() -> CursorTrack {
        let samples = stride(from: 0.0, through: 30.0, by: 0.02).map {
            CursorSample(t: $0, x: 100 + $0 * 20, y: 250, shape: .arrow)
        }
        return CursorTrack(samples: samples, input: [.mouseDown(t: 10, button: 0, x: 300, y: 250)])
    }

    private func picture(_ red: Double, _ green: Double, _ blue: Double) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue))
            .cropped(to: CGRect(origin: .zero, size: videoSize))
    }

    /// A pixel in Core Image's coordinates — `y` up from the bottom.
    private func pixel(_ image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int)? {
        let column = Int(x.rounded(.down)), row = image.height - 1 - Int(y.rounded(.down))
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              column >= 0, row >= 0, column < image.width, row < image.height else { return nil }
        let offset = row * image.bytesPerRow + column * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func render(_ scene: SceneDescriptor, source: CIImage?, blending: CIImage? = nil) throws -> CGImage {
        try #require(SceneRenderer().cgImage(for: scene, source: source, blending: blending))
    }

    // MARK: - A freeze frame

    @Test func aFreezeFrameIsTheHeldFramePointerAndAll() throws {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10), for: time(2))
        let builder = builder()
        let first = builder.descriptor(for: timeline, at: time(10.2), cursor: track())
        let later = builder.descriptor(for: timeline, at: time(11.8), cursor: track())

        #expect(first.sourceTime == time(10))
        #expect(later.sourceTime == time(10))
        #expect(first.cursor?.position == later.cursor?.position, "the pointer stands where it was")
        #expect(first.cursor?.velocity == .zero, "and is not smeared for movement it is not making")
    }

    /// A ring frozen half-spread reads as a fault, so a still has none — and the same
    /// click is marked in the footage after it, where it is seen happening.
    @Test func aFreezeFrameCatchesNoClickMidRing() {
        var timeline = timeline()
        timeline.cursor.clickHighlight = true
        ClipSequence.freeze(&timeline, at: time(10.1), for: time(2))
        let still = builder().descriptor(for: timeline, at: time(11), cursor: track())
        #expect(still.clicks.isEmpty)
        let after = builder().descriptor(for: timeline, at: time(12.15), cursor: track())
        #expect(!after.clicks.isEmpty)
    }

    @Test func footageIsDescribedExactlyAsItAlwaysWas() {
        let timeline = timeline()
        let scene = builder().descriptor(for: timeline, at: time(5), cursor: track())
        #expect(scene.title == nil)
        #expect(scene.blend == nil)
        #expect(scene == builder().clipDescriptor(for: timeline, at: time(5), cursor: track()))
    }

    // MARK: - A title

    private func titled(_ card: TitleCard = TitleCard(title: "Hello", subtitle: "World")) -> Timeline {
        var timeline = timeline()
        _ = Commands.AddTitle(card, at: .zero).apply(to: &timeline)
        return timeline
    }

    @Test func aTitleShowsNoRecording() {
        var timeline = titled()
        timeline.webcam.isEnabled = true
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(3), scale: 2)]
        timeline.blurs = [BlurRegion(start: .zero, duration: time(3), rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))]
        timeline.annotations = [AnnotationItem(start: .zero, duration: time(3), kind: .text("note"),
                                               rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1))]
        let scene = builder().descriptor(for: timeline, at: time(1.5), cursor: track())

        #expect(scene.title?.title == "Hello")
        #expect(!scene.showsRecording)
        #expect(scene.cursor == nil)
        #expect(scene.clicks.isEmpty)
        #expect(scene.webcam == nil)
        #expect(scene.blurs.isEmpty)
        #expect(scene.zoom == 1, "a zoom over a title would crop words it was never placed on")
        #expect(scene.annotations.count == 1, "notes on top are the timeline's, and stay")
    }

    @Test func aTitleArrivesWithItsEntrance() {
        let timeline = titled(TitleCard(title: "Hi", entrance: .rise))
        let start = builder().descriptor(for: timeline, at: .zero)
        let settled = builder().descriptor(for: timeline, at: time(1))
        #expect(start.title?.opacity == 0)
        #expect((start.title?.drop ?? 0) > 0)
        #expect(settled.title?.opacity == 1)
        #expect(settled.title?.drop == 0)
    }

    /// No recording is drawn: the recording is red, and nothing red comes out.
    @Test func aTitleOnTheBackgroundDrawsNoPictureAndItsWords() throws {
        let scene = builder().descriptor(for: titled(), at: time(2))
        let image = try render(scene, source: picture(1, 0, 0))

        var sawRed = false
        var sawWords = false
        for x in stride(from: 170.0, to: 1_430, by: 20) {
            for y in stride(from: 110.0, to: 890, by: 20) {
                guard let p = pixel(image, x: x, y: y) else { continue }
                if p.r > 180 && p.g < 80 && p.b < 80 { sawRed = true }
                if p.r > 200 && p.g > 200 && p.b > 200 { sawWords = true }
            }
        }
        #expect(!sawRed, "the recording is not drawn under a title")
        #expect(sawWords, "white words on the blue background")
        let corner = try #require(pixel(image, x: 180, y: 120))
        #expect(corner.b > 200 && corner.r < 40, "the background shows where there are no words")
    }

    /// A panel stands where the picture would, framed as the picture is.
    @Test func aTitleOnAPanelFillsThePicturesPlace() throws {
        let card = TitleCard(title: "Hello", backdrop: .panel, textColor: .black,
                             panelColor: ColorValue(r: 0, g: 1, b: 0))
        let scene = builder().descriptor(for: titled(card), at: time(2))
        let image = try render(scene, source: picture(1, 0, 0))
        let inside = try #require(pixel(image, x: 170, y: 110))
        #expect(inside.g > 200 && inside.r < 40, "the panel, just inside the frame")
        let outside = try #require(pixel(image, x: 150, y: 90))
        #expect(outside.b > 200 && outside.g < 40, "the background, just outside it")
    }

    @Test func theLayoutsPutTheWordsInDifferentPlaces() throws {
        func inkedRows(_ layout: TitleCard.Layout) throws -> (low: Double, high: Double, left: Double) {
            let scene = builder().descriptor(for: titled(TitleCard(title: "Title", layout: layout)), at: time(2))
            let image = try render(scene, source: nil)
            var low = Double.infinity, high = -Double.infinity, left = Double.infinity
            for x in stride(from: 160.0, to: 1_440, by: 8) {
                for y in stride(from: 100.0, to: 900, by: 8) {
                    guard let p = pixel(image, x: x, y: y), p.r > 200 && p.g > 200 else { continue }
                    low = min(low, y); high = max(high, y); left = min(left, x)
                }
            }
            return (low, high, left)
        }
        let centred = try inkedRows(.centred)
        let left = try inkedRows(.left)
        let lower = try inkedRows(.lowerThird)
        #expect(left.left < centred.left, "left-aligned starts nearer the edge")
        #expect(lower.high < centred.low, "the lower third sits below the middle")
        #expect(abs((centred.low + centred.high) / 2 - 500) < 60, "centred is in the middle")
    }

    // MARK: - Transitions

    private func cutAtTen(_ style: ClipTransition.Style) -> Timeline {
        var timeline = timeline()
        ClipSequence.split(&timeline, at: time(10))
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id, to: ClipTransition(style, duration: time(1)))
        return timeline
    }

    @Test func aDipIsDescribedAsHowFarToTheColour() {
        let timeline = cutAtTen(.dipToBlack)
        let builder = builder()
        #expect(builder.descriptor(for: timeline, at: time(9.4)).blend == nil)
        #expect(builder.descriptor(for: timeline, at: time(9.75)).blend == .dip(amount: 0.5, toBackground: false))
        #expect(builder.descriptor(for: timeline, at: time(10)).blend == .dip(amount: 1, toBackground: false))
        #expect(builder.descriptor(for: timeline, at: time(10.25)).blend == .dip(amount: 0.5, toBackground: false))
        #expect(builder.descriptor(for: cutAtTen(.dipToBackground), at: time(10)).blend
                == .dip(amount: 1, toBackground: true))
    }

    /// Each side lends the frame at its edge, and the notes on top are this moment's.
    @Test func aCrossfadeBorrowsTheFrameAtTheOtherSidesEdge() throws {
        var timeline = cutAtTen(.crossfade)
        _ = ClipSequence.trim(&timeline, clipID: timeline.clips[1].id, head: time(15), tail: nil)
        timeline.captions = [CaptionCue(start: time(9.8), duration: time(1), text: "over the cut")]
        let builder = builder()

        let before = builder.descriptor(for: timeline, at: time(9.75))
        let lentBefore = try #require(before.blendedScene)
        #expect(before.sourceTime == time(9.75))
        #expect(lentBefore.sourceTime == time(15), "the incoming clip's first frame")
        #expect(before.blend == .crossfade(lentBefore, amount: 0.25))
        #expect(lentBefore.caption == before.caption, "the caption is this moment's on both sides")

        let after = builder.descriptor(for: timeline, at: time(10.25))
        let lentAfter = try #require(after.blendedScene)
        #expect(after.sourceTime == time(15.25))
        #expect(abs(lentAfter.sourceTime.seconds - 9.999) < 0.0005, "the outgoing clip's last frame")
        #expect(after.blend == .crossfade(lentAfter, amount: 0.25))
    }

    @Test func dippingToBlackAtTheCutIsBlack() throws {
        let scene = builder().descriptor(for: cutAtTen(.dipToBlack), at: time(10))
        let image = try render(scene, source: picture(1, 0, 0))
        for (x, y) in [(800.0, 500.0), (50.0, 50.0)] {
            let p = try #require(pixel(image, x: x, y: y))
            #expect(p.r < 5 && p.g < 5 && p.b < 5)
        }
    }

    @Test func dippingToTheBackgroundAtTheCutShowsOnlyTheBackground() throws {
        let scene = builder().descriptor(for: cutAtTen(.dipToBackground), at: time(10))
        let image = try render(scene, source: picture(1, 0, 0))
        let middle = try #require(pixel(image, x: 800, y: 500))
        #expect(middle.b > 240 && middle.r < 10, "the picture has gone; the frame's background stays")
    }

    @Test func halfwayIntoADipIsHalfwayToBlack() throws {
        let scene = builder().descriptor(for: cutAtTen(.dipToBlack), at: time(9.75))
        let image = try render(scene, source: picture(1, 0, 0))
        let middle = try #require(pixel(image, x: 800, y: 500))
        #expect(abs(middle.r - 128) < 20, "half of the red is left")
    }

    @Test func aCrossfadeAtTheCutIsHalfOfEach() throws {
        let scene = builder().descriptor(for: cutAtTen(.crossfade), at: time(10))
        let image = try render(scene, source: picture(0, 1, 0), blending: picture(1, 0, 0))
        let middle = try #require(pixel(image, x: 800, y: 500))
        #expect(abs(middle.r - 128) < 20 && abs(middle.g - 128) < 20, "red and green, half each")
        let border = try #require(pixel(image, x: 50, y: 50))
        #expect(border.b > 240, "the background is the same on both sides, and mixes to itself")
    }

    /// The preview draws a smaller frame while playing; the other side must shrink with it.
    @Test func scalingAFrameScalesTheOtherSideOfItsCrossfade() throws {
        let scene = builder().descriptor(for: cutAtTen(.crossfade), at: time(9.9))
        let half = scene.scaled(by: 0.5)
        let lent = try #require(half.blendedScene)
        #expect(lent.outputSize == half.outputSize)
        #expect(lent.videoFrame == half.videoFrame)
        #expect(scene.scaled(by: 1) == scene)
    }
}
