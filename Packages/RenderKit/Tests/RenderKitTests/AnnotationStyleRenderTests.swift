import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import RenderKit
import TimelineKit

/// How an annotation is styled, read back off the picture: plates that make words legible,
/// rings round letters, weights, alignment, shadows — and that the cache tells them apart.
struct AnnotationStyleRenderTests {
    private typealias R = AnnotationRendering
    private let wide = CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2)

    /// The most-contrasting pair of plate and word: the plate sampled beside the words, the
    /// words as the pixel inside the plate that stands out from it most.
    private func contrast(_ frame: AnnotationFrame, plateAt plate: CGPoint, words area: CGRect) -> Double {
        let behind = frame.colour(Int(plate.x), Int(plate.y))
        return frame.colours(in: area).map { $0.contrastRatio(with: behind) }.max() ?? 1
    }

    /// Words on every backdrop, in colours chosen to be hard — yellow, navy, white, black —
    /// over a white picture and a black one. Each must stand out from its own plate.
    @Test func wordsOnAPlateReadAgainstIt() throws {
        let area = R.pixels(wide)
        for backdrop in [AnnotationStyle.Backdrop.dark, .light, .solid] {
            for colour in [R.red, R.yellow, R.navy, ColorValue.white, ColorValue.black] {
                for background in [ColorValue.white, ColorValue.black] {
                    let label = R.layer(.text("HHH"), rect: wide, colour: colour, fontSize: 0.1,
                                        style: AnnotationStyle(weight: .bold, backdrop: backdrop))
                    let frame = try R.render([label], on: background)
                    // The plate's left padding, halfway down the first line.
                    let ratio = contrast(frame, plateAt: CGPoint(x: area.minX + 3, y: area.minY + 22),
                                         words: CGRect(x: area.minX + 14, y: area.minY + 8, width: 90, height: 30))
                    #expect(ratio >= 3,
                            "\(backdrop) with \(colour) over \(background): \(ratio):1")
                }
            }
        }
    }

    /// The same check with no plate finds yellow on white unreadable — so the test above is
    /// measuring something.
    @Test func withoutAPlateYellowOnWhiteDoesNotRead() throws {
        let label = R.layer(.text("HHH"), rect: wide, colour: R.yellow, fontSize: 0.1,
                            style: AnnotationStyle(weight: .bold))
        let frame = try R.render([label], on: .white)
        let area = R.pixels(wide)
        #expect(contrast(frame, plateAt: CGPoint(x: 5, y: 5),
                         words: CGRect(x: area.minX, y: area.minY, width: 100, height: 40)) < 2)
    }

    /// A plate hugs the words and stays inside the box.
    @Test func aPlateStaysInsideTheBox() throws {
        for backdrop in [AnnotationStyle.Backdrop.dark, .light, .solid] {
            for alignment in AnnotationStyle.Alignment.allCases {
                let label = R.layer(.text("Hi"), rect: wide, fontSize: 0.08,
                                    style: AnnotationStyle(backdrop: backdrop, alignment: alignment))
                let frame = try R.render([label], on: .white)
                let ink = try #require(frame.ink(against: .white, threshold: 0.03))
                #expect(R.pixels(wide).insetBy(dx: -1, dy: -1).contains(ink), "\(backdrop) \(alignment): \(ink)")
                #expect(ink.width < R.pixels(wide).width / 2, "hugs two letters rather than filling the box")
            }
        }
    }

    /// White words over white vanish; with a ring round each letter they read.
    @Test func anOutlineMakesWordsReadOnTheirOwnColour() throws {
        let area = R.pixels(wide)
        let words = CGRect(x: area.minX, y: area.minY, width: 160, height: area.height)
        func best(_ outline: Bool) throws -> Double {
            let label = R.layer(.text("HHH"), rect: wide, colour: .white, fontSize: 0.1,
                                style: AnnotationStyle(weight: .bold, outlinesText: outline))
            let frame = try R.render([label], on: .white)
            return frame.colours(in: words).map { $0.contrastRatio(with: .white) }.max() ?? 1
        }
        #expect(try best(false) < 1.2)
        #expect(try best(true) >= 7, "a dark ring round white letters")
    }

    @Test func aHeavierWeightIsMoreInk() throws {
        func ink(_ weight: AnnotationStyle.Weight) throws -> Int {
            let label = R.layer(.text("Weight"), rect: wide, fontSize: 0.1, style: AnnotationStyle(weight: weight))
            return try R.render([label], on: .black).inkCount(against: .black)
        }
        let regular = try ink(.regular), semibold = try ink(.semibold), bold = try ink(.bold)
        #expect(regular < semibold && semibold < bold, "\(regular) < \(semibold) < \(bold)")
    }

    @Test func alignmentMovesTheWordsAcrossTheBox() throws {
        let area = R.pixels(wide)
        for backdrop in [AnnotationStyle.Backdrop.none, .solid] {
            func centre(_ alignment: AnnotationStyle.Alignment) throws -> Double {
                let label = R.layer(.text("Hi"), rect: wide, fontSize: 0.08,
                                    style: AnnotationStyle(backdrop: backdrop, alignment: alignment))
                return try #require(R.render([label], on: .black).ink(against: .black)).midX
            }
            let left = try centre(.left), middle = try centre(.center), right = try centre(.right)
            #expect(left < area.minX + area.width * 0.2, "\(backdrop) left: \(left)")
            #expect(abs(middle - area.midX) <= 3, "\(backdrop) centre: \(middle)")
            #expect(right > area.maxX - area.width * 0.2, "\(backdrop) right: \(right)")
        }
    }

    /// Every kind can cast a shadow: dark just outside it on a white picture, soft, and
    /// gone a short way off.
    @Test func everyKindCastsASoftShadow() throws {
        let box = CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.4)
        let area = R.pixels(box)
        let reach = AnnotationArtwork.shadowBlur(400) * 2 + AnnotationArtwork.shadowDrop(400)
        for kind in R.everyKind {
            let plain = try #require(R.render([R.layer(kind)], on: .white).ink(against: .white, threshold: 0.02))
            let shaded = try R.render([R.layer(kind, style: AnnotationStyle(hasShadow: true))], on: .white)
            let ink = try #require(shaded.ink(against: .white, threshold: 0.02))
            #expect(ink.maxY > plain.maxY, "\(kind) casts a shadow below it")
            #expect(area.insetBy(dx: -reach - 2, dy: -reach - 2).contains(ink), "\(kind)'s shadow is soft, not long: \(ink)")
        }
        let without = try R.render([R.layer(.rectangle, style: AnnotationStyle(fill: .solid))], on: .white)
        let with = try R.render([R.layer(.rectangle, style: AnnotationStyle(fill: .solid, hasShadow: true))], on: .white)
        let under = (Int(area.midX), Int(area.maxY) + 3)
        #expect(!without.differs(under.0, under.1, from: .white, by: 0.02))
        #expect(with.colour(under.0, under.1).relativeLuminance < 0.85, "darkened under the box")
    }

    // MARK: - The cache

    /// A cached drawing is only right if its key names everything it depends on. Each of
    /// these draws the default first, so the cache is warm, then changes one thing: a key
    /// that left it out would hand back the default's pixels.
    @Test func theCacheTellsEveryStyleApart() throws {
        let variants: [(String, AnnotationItem.Kind, AnnotationStyle)] = [
            ("thickness", .rectangle, AnnotationStyle(thickness: 3)),
            ("fill", .ellipse, AnnotationStyle(fill: .solid)),
            ("weight", .text("Words"), AnnotationStyle(weight: .bold)),
            ("backdrop", .text("Words"), AnnotationStyle(backdrop: .light)),
            ("outline", .text("Words"), AnnotationStyle(outlinesText: true)),
            ("alignment", .text("Words"), AnnotationStyle(alignment: .right)),
            ("shadow", .step(2), AnnotationStyle(hasShadow: true)),
        ]
        // Grey, so a shadow shows.
        let grey = ColorValue(r: 0.5, g: 0.5, b: 0.5)
        for (name, kind, style) in variants {
            let plain = try R.render([R.layer(kind)], on: grey)
            let styled = try R.render([R.layer(kind, style: style)], on: grey)
            #expect(plain.bytes != styled.bytes, "changing \(name) changed nothing: it is missing from the key")
            AnnotationArtwork.clearCache()
            let cold = try R.render([R.layer(kind, style: style)], on: grey)
            #expect(cold.bytes == styled.bytes, "\(name): warm and cold draws agree")
        }
    }

    @Test func theCacheTellsEveryKindsPayloadApart() throws {
        let pairs: [(AnnotationItem.Kind, AnnotationItem.Kind)] = [
            (.step(2), .step(3)),
            (.callout("A", tail: CGPoint(x: 0.2, y: 1.5)), .callout("A", tail: CGPoint(x: 0.8, y: 1.5))),
            (.callout("A", tail: CGPoint(x: 0.2, y: 1.5)), .callout("B", tail: CGPoint(x: 0.2, y: 1.5))),
            (.line(from: .zero, to: CGPoint(x: 1, y: 1)), .line(from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0))),
            (.line(from: .zero, to: CGPoint(x: 1, y: 1)), .arrow(from: .zero, to: CGPoint(x: 1, y: 1))),
            (.rectangle, .ellipse),
            (.rectangle, .highlight),
        ]
        for (first, second) in pairs {
            let a = try R.render([R.layer(first)], on: .black)
            let b = try R.render([R.layer(second)], on: .black)
            #expect(a.bytes != b.bytes, "\(first) and \(second) drew the same")
        }
    }

    // MARK: - Moving, turning and fading

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    /// The layers the builder makes for one item at `seconds`, which is the path both the
    /// preview and the export take from the model to the renderer.
    private func layers(_ item: AnnotationItem, at seconds: Double) -> [AnnotationLayer] {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.annotations = [item]
        return SceneBuilder(videoSize: CGSize(width: 400, height: 400), displayScale: 1)
            .descriptor(for: timeline, at: time(seconds)).annotations
    }

    /// Halfway through a scale-in every kind is smaller and fainter than at rest, turned
    /// a quarter it stands on end, and at half opacity it is half as strong.
    @Test func everyKindAnimatesTurnsAndFades() throws {
        let box = CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.2)
        let kinds = R.everyKind.map { kind -> AnnotationItem.Kind in
            // A tail inside the bubble has nothing to point across; point it out of it.
            if case .callout(let text, _) = kind { return .callout(text, tail: CGPoint(x: 0.5, y: 2)) }
            return kind
        }
        for kind in kinds {
            let item = AnnotationItem(start: time(2), duration: time(4), kind: kind, rect: box, fontSize: 0.08,
                                      animation: AnnotationAnimation(entrance: .scale, exit: .fade,
                                                                     entranceDuration: 1, easing: .linear),
                                      style: AnnotationStyle(fill: .solid, backdrop: .solid))
            let rest = try #require(layers(item, at: 4).first)
            let arriving = try #require(layers(item, at: 2.5).first)
            #expect(arriving.scale < 1 && arriving.opacity < 1, "\(kind) mid-entrance")
            #expect(arriving.style == item.style, "\(kind) keeps its style while it moves")

            let still = try R.render([rest], on: .black)
            let moving = try R.render([arriving], on: .black)
            let restInk = try #require(still.ink(against: .black), "\(kind) at rest")
            let movingInk = try #require(moving.ink(against: .black), "\(kind) arriving")
            #expect(movingInk.width < restInk.width - 4, "\(kind) is smaller halfway in")
            if kind.name != .callout {
                // A callout's ink includes its tail, which hangs off one side of its box.
                #expect(abs(movingInk.midY - restInk.midY) < 6, "\(kind) grows about its middle")
            }
            let strongest = { (frame: AnnotationFrame) in frame.colours(in: restInk).map(\.r).max() ?? 0 }
            #expect(strongest(moving) < strongest(still) * 0.8, "\(kind) is fainter halfway in")

            var turned = item
            turned.rotation = 90
            let upright = try R.render([try #require(layers(turned, at: 4).first)], on: .black)
            let uprightInk = try #require(upright.ink(against: .black))
            if case .step = kind {
                #expect(abs(uprightInk.midX - restInk.midX) < 2, "a step turns in place")
            } else {
                #expect(uprightInk.height > uprightInk.width, "\(kind) stands on end: \(uprightInk)")
            }

            var faint = item
            faint.opacity = 0.5
            let half = try R.render([try #require(layers(faint, at: 4).first)], on: .black)
            let ratio = strongest(half) / max(0.01, strongest(still))
            #expect(ratio > 0.35 && ratio < 0.8, "\(kind) at half opacity: \(ratio)")
        }
    }
}
