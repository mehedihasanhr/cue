import CoreGraphics
import Foundation
import CoreMedia
import Testing
@testable import RenderKit
import TimelineKit

/// The loop, and the Draw and Erase animations that trace a shape's stroke on and off.
struct AnnotationDrawOnTests {
    private typealias R = AnnotationRendering
    private let white = ColorValue(r: 1, g: 1, b: 1)

    private func traced(_ kind: AnnotationItem.Kind, drawn: Double, erased: Double = 0) throws -> AnnotationFrame {
        var layer = R.layer(kind)
        layer.drawn = drawn
        layer.erased = erased
        return try R.render([layer], on: white)
    }

    @Test func aLoopGoesRoundItsBoxAndCrossesItself() throws {
        let frame = try R.render([R.layer(.loop)], on: white)
        let box = R.pixels(R.layer(.loop).rect)
        let ink = try #require(frame.ink(against: white))
        // Round the box, not a dot in it: nearly as wide and tall as the box.
        #expect(ink.width > box.width * 0.75 && ink.height > box.height * 0.75)
        #expect(box.insetBy(dx: -2, dy: -2).contains(ink), "drawn inside its own box: \(ink) in \(box)")
        // A ring: the middle, where the thing circled is, is left alone.
        #expect(!frame.differs(Int(box.midX), Int(box.midY), from: white))
    }

    @Test(arguments: [AnnotationItem.Kind.loop, .rectangle, .ellipse,
                      .line(from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0)),
                      .arrow(from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0))])
    func drawingOnShowsMoreAndMoreOfTheStroke(_ kind: AnnotationItem.Kind) throws {
        let quarter = try traced(kind, drawn: 0.25).inkCount(against: white)
        let half = try traced(kind, drawn: 0.5).inkCount(against: white)
        let whole = try traced(kind, drawn: 1).inkCount(against: white)
        #expect(quarter > 0)
        #expect(quarter < half && half < whole, "\(kind): \(quarter), \(half), \(whole)")
    }

    @Test func erasingTakesTheStrokeAwayFromItsStart() throws {
        let line = AnnotationItem.Kind.line(from: CGPoint(x: 0, y: 0.5), to: CGPoint(x: 1, y: 0.5))
        let ink = try #require(try traced(line, drawn: 1, erased: 0.5).ink(against: white))
        let box = R.pixels(R.layer(line).rect)
        // The left half is gone; the right half, where it ends, is still there.
        #expect(ink.minX > box.midX - 6 && ink.maxX > box.maxX - 8)
    }

    @Test func aHighlightIsSweptOnLeftToRight() throws {
        let ink = try #require(try traced(.highlight, drawn: 0.5).ink(against: white))
        let box = R.pixels(R.layer(.highlight).rect)
        #expect(abs(ink.minX - box.minX) < 2 && abs(ink.maxX - box.midX) < 3)
    }

    // MARK: - Through the timeline

    private func scene(_ kind: AnnotationItem.Kind, entrance: AnnotationAnimation.Entrance,
                       exit: AnnotationAnimation.Exit = .none, at seconds: Double) -> AnnotationLayer? {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 20, preferredTimescale: 600))
        var item = AnnotationItem(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600),
                                  kind: kind, rect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3))
        item.animation = AnnotationAnimation(entrance: entrance, exit: exit, entranceDuration: 1, exitDuration: 1)
        timeline.annotations = [item]
        return SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000))
            .descriptor(for: timeline, at: CMTime(seconds: seconds, preferredTimescale: 600))
            .annotations.first
    }

    @Test func drawReachesTheRendererAsAShareOfTheStroke() throws {
        let halfway = try #require(scene(.loop, entrance: .draw, at: 0.5))
        #expect(abs(halfway.drawn - 0.5) < 0.01 && halfway.opacity > 0.99)
        let done = try #require(scene(.loop, entrance: .draw, at: 2))
        #expect(done.drawn == 1 && done.erased == 0)
        let leaving = try #require(scene(.rectangle, entrance: .none, exit: .erase, at: 3.5))
        #expect(abs(leaving.erased - 0.5) < 0.01)
    }

    @Test func wordsHaveNoStrokeSoDrawFadesThem() throws {
        let halfway = try #require(scene(.text("Hello"), entrance: .draw, at: 0.5))
        #expect(halfway.drawn == 1 && abs(halfway.opacity - 0.5) < 0.01)
    }

    @Test func aLoopSurvivesTheProjectFile() throws {
        let item = AnnotationItem(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600),
                                  kind: .loop, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                                  animation: AnnotationAnimation(entrance: .draw, exit: .erase))
        let back = try JSONDecoder().decode(AnnotationItem.self, from: JSONEncoder().encode(item))
        #expect(back.kind == .loop && back.animation.entrance == .draw && back.animation.exit == .erase)
    }
}

/// Every shape draws on, not only the outlined ones: a step's ring and a callout's bubble
/// go round, then fill, then show their number or words.
struct EveryShapeDrawsOnTests {
    private typealias R = AnnotationRendering
    private let white = ColorValue(r: 1, g: 1, b: 1)

    private func ink(_ kind: AnnotationItem.Kind, drawn: Double, style: AnnotationStyle = AnnotationStyle()) throws -> Int {
        var layer = R.layer(kind, style: style)
        layer.drawn = drawn
        return try R.render([layer], on: white).inkCount(against: white)
    }

    @Test(arguments: [AnnotationItem.Kind.step(3), .callout("Hello", tail: CGPoint(x: 0.5, y: 1.6))])
    func aBadgeOrABubbleBuildsUp(_ kind: AnnotationItem.Kind) throws {
        let early = try ink(kind, drawn: 0.2), late = try ink(kind, drawn: 0.7), whole = try ink(kind, drawn: 1)
        // Within a little of the whole at the end: a step's white number counts as paper,
        // so its badge with the number still faint has a few more pixels of ink, not fewer.
        #expect(early > 0 && early < late && Double(late) <= Double(whole) * 1.1, "\(kind): \(early), \(late), \(whole)")
    }

    @Test func aPlatedCalloutBuildsUpToo() throws {
        var style = AnnotationStyle()
        style.backdrop = .solid
        let kind = AnnotationItem.Kind.callout("Hello", tail: CGPoint(x: 0.5, y: 1.6))
        let early = try ink(kind, drawn: 0.2, style: style), whole = try ink(kind, drawn: 1, style: style)
        #expect(early > 0 && early < whole / 2)
    }

    @Test func onlyWordsAndPicturesFade() {
        #expect(!AnnotationItem.Kind.text("Hi").canBeTraced)
        #expect(!AnnotationItem.Kind.image(path: "a.png").canBeTraced)
        for kind in AnnotationRendering.everyKind where kind.name != .text {
            #expect(kind.canBeTraced, "\(kind)")
        }
    }
}

/// A pen starts at the top left and goes round clockwise, as anybody drawing a box or a
/// ring by hand does.
struct DrawOnStartsTopLeftTests {
    private typealias R = AnnotationRendering
    private let white = ColorValue(r: 1, g: 1, b: 1)

    @Test(arguments: [AnnotationItem.Kind.rectangle, .ellipse, .loop, .step(1)])
    func theFirstOfTheStrokeIsAtTheTopLeft(_ kind: AnnotationItem.Kind) throws {
        var layer = R.layer(kind)
        layer.drawn = 0.12
        let ink = try #require(try R.render([layer], on: white).ink(against: white))
        let box = R.pixels(layer.rect)
        // Top-left origin here: the start is in the upper half, and has not reached the right.
        #expect(ink.minY < box.midY && ink.minX < box.midX, "\(kind): \(ink) in \(box)")
        #expect(ink.maxY < box.midY + 2, "\(kind) went down first: \(ink) in \(box)")
    }

    @Test(arguments: [AnnotationItem.Kind.rectangle, .ellipse])
    func itGoesRoundClockwise(_ kind: AnnotationItem.Kind) throws {
        // A third of the way round a clockwise pen is on the right, not the left.
        var layer = R.layer(kind)
        layer.drawn = 0.4
        let ink = try #require(try R.render([layer], on: white).ink(against: white))
        let box = R.pixels(layer.rect)
        #expect(ink.maxX > box.maxX - 6, "\(kind): \(ink) in \(box)")
    }
}
