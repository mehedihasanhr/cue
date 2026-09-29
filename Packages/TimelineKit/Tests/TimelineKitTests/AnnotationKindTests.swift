import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double = 1e-9) -> Bool {
    close(a.x, b.x, tolerance) && close(a.y, b.y, tolerance)
}

private let everyNewKind: [AnnotationItem.Kind] = [
    .ellipse,
    .line(from: CGPoint(x: 0.1, y: 0.9), to: CGPoint(x: 0.8, y: 0.3)),
    .highlight,
    .step(7),
    .callout("Click here", tail: CGPoint(x: 0.3, y: 2.1)),
]

/// A style with every setting away from its default, so a copy that forgot one shows.
private let everythingSet = AnnotationStyle(thickness: 2.5, fill: .translucent, weight: .bold, backdrop: .solid,
                                            outlinesText: true, alignment: .right, hasShadow: true)

/// The kinds added after text, arrow, box and picture, and the settings that came with them.
struct AnnotationKindTests {
    private func item(_ kind: AnnotationItem.Kind, style: AnnotationStyle = AnnotationStyle(),
                      start: Double = 1) -> AnnotationItem {
        AnnotationItem(start: time(start), duration: time(3), kind: kind,
                       rect: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.2), style: style)
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - Old projects

    /// A project from before any of this: no style in the file. It opens with the style
    /// that draws what it always drew.
    @Test func anAnnotationWithoutAStyleOpensLookingAsItDid() throws {
        let original = item(.rectangle)
        var old = try json(original)
        old.removeValue(forKey: "style")
        let decoded = try decode(AnnotationItem.self, old)
        #expect(decoded.style == AnnotationStyle())
        #expect(decoded.style.thickness == 1)
        #expect(decoded.style.fill == .none && decoded.style.backdrop == .none)
        #expect(decoded.style.weight == .semibold, "the weight every label was drawn in")
        #expect(decoded.style.alignment == .left && !decoded.style.outlinesText && !decoded.style.hasShadow)
        #expect(decoded == original)
    }

    /// Each setting is read on its own: one that cannot be read is that setting at its
    /// default, not the whole style — and not the annotation.
    @Test func anUnreadableSettingCostsOnlyThatSetting() throws {
        var file = try json(item(.text("Hi"), style: everythingSet))
        var style = try #require(file["style"] as? [String: Any])
        style["fill"] = "polka dots"
        style["thickness"] = "thick"
        style["hasShadow"] = 3
        file["style"] = style
        let decoded = try decode(AnnotationItem.self, file)
        #expect(decoded.style.fill == .none)
        #expect(decoded.style.thickness == 1)
        #expect(decoded.style.hasShadow == false)
        #expect(decoded.style.weight == .bold, "the settings that could be read are kept")
        #expect(decoded.style.backdrop == .solid && decoded.style.alignment == .right && decoded.style.outlinesText)
        #expect(decoded.kind == .text("Hi"))
    }

    @Test func aStyleThatIsNotAnObjectIsTheDefault() throws {
        var file = try json(item(.ellipse, style: everythingSet))
        file["style"] = "fancy"
        #expect(try decode(AnnotationItem.self, file).style == AnnotationStyle())
    }

    @Test func everyNewKindAndStyleSurvivesSaveAndReopen() throws {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.annotations = everyNewKind.enumerated().map { index, kind in
            item(kind, style: everythingSet, start: Double(index))
        }
        let reopened = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(reopened.annotations == timeline.annotations)
    }

    /// A kind a later version adds is one this version cannot draw. It opens as a box in
    /// the same place, rather than taking the lane with it.
    @Test func aKindFromTheFutureOpensAsABox() throws {
        var file = try json(item(.ellipse))
        file["kind"] = ["spiral": ["turns": 3]]
        let decoded = try decode(AnnotationItem.self, file)
        #expect(decoded.kind == .rectangle)
        #expect(decoded.rect == item(.ellipse).rect)
    }

    // MARK: - Numbers that cannot be drawn

    @Test func aStepNumberIsKeptToOneToNineHundredAndNinetyNine() {
        #expect(item(.step(0)).kind == .step(1))
        #expect(item(.step(-4)).kind == .step(1))
        #expect(item(.step(12_000)).kind == .step(999))
        #expect(item(.step(42)).kind == .step(42))
    }

    @Test func aBrokenTailPointsWhereANewOneWould() {
        #expect(item(.callout("x", tail: CGPoint(x: CGFloat.nan, y: 1))).kind == .callout("x", tail: AnnotationItem.defaultTail))
        guard case .callout(_, let far) = item(.callout("x", tail: CGPoint(x: 90, y: -90))).kind else {
            Issue.record("not a callout")
            return
        }
        #expect(far.x <= 4 && far.y >= -3, "a tail reaches a few bubbles away at most")
    }

    @Test func aLinesBrokenEndsAreMended() {
        let mended = item(.line(from: CGPoint(x: CGFloat.infinity, y: 0), to: CGPoint(x: 0.5, y: CGFloat.nan))).kind
        #expect(mended == .line(from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0)))
    }

    @Test func thicknessIsKeptDrawable() {
        #expect(AnnotationStyle(thickness: .nan).thickness == 1)
        #expect(AnnotationStyle(thickness: 400).thickness == AnnotationStyle.thicknessRange.upperBound)
        #expect(AnnotationStyle(thickness: 0).thickness == AnnotationStyle.thicknessRange.lowerBound)
        var restyled = item(.rectangle)
        restyled.style.thickness = -.infinity
        restyled.sanitise()
        #expect(restyled.style.thickness == 1)
    }

    // MARK: - Copies

    private func differences(_ original: Any, _ copy: Any, except: Set<String>) -> [String] {
        func fields(_ value: Any) -> [String: String] {
            var found: [String: String] = [:]
            for child in Mirror(reflecting: value).children {
                if let label = child.label { found[label] = String(describing: child.value) }
            }
            return found
        }
        let before = fields(original), after = fields(copy)
        return before.keys.sorted().filter { !except.contains($0) && before[$0] != after[$0] }
    }

    /// The reflection tests in `CopiesKeepEverythingTests` with a style that is not the
    /// default and every new kind — a copy that dropped the style would pass those, since
    /// the default copied and the default forgotten look the same.
    @Test func aPastedAnnotationKeepsItsKindAndStyle() throws {
        let timeline = Timeline(sourceDuration: time(60))
        for kind in everyNewKind {
            let original = item(kind, style: everythingSet)
            let placed = try #require(CopiedRegion.annotation(original).placed(at: time(20), in: timeline))
            guard case .annotation(let copy) = placed else {
                Issue.record("not an annotation")
                continue
            }
            #expect(differences(original, copy, except: ["id", "start", "duration", "isLocked"]).isEmpty)
            #expect(copy.style == everythingSet)
        }
    }

    @Test func copiedFootageKeepsKindAndStyle() {
        let originals = everyNewKind.map { item($0, style: everythingSet) }
        let footage = CopiedFootage(clips: Timeline(sourceDuration: time(60)).clips, annotations: originals,
                                    sourceDuration: time(60)).freshened()
        for (original, copy) in zip(originals, footage.annotations) {
            #expect(differences(original, copy, except: ["id", "isLocked"]).isEmpty)
        }
    }

    @Test func eachNewKindHasAPlainSummaryForOtherApps() {
        for kind in everyNewKind {
            let summary = CopiedRegion.annotation(item(kind)).summary
            #expect(summary.hasPrefix("Klik "))
        }
        #expect(CopiedRegion.annotation(item(.step(4))).summary.contains("step 4"))
        #expect(CopiedRegion.annotation(item(.callout("Save", tail: .zero))).summary.contains("Save"))
    }

    // MARK: - Numbered steps

    @Test func theFirstStepIsOne() {
        #expect(Timeline(sourceDuration: time(10)).nextStepNumber == 1)
        var timeline = Timeline(sourceDuration: time(10))
        timeline.annotations = [item(.text("1")), item(.rectangle)]
        #expect(timeline.nextStepNumber == 1, "only steps count")
    }

    @Test func theNextStepFollowsTheHighestNotTheCount() {
        var timeline = Timeline(sourceDuration: time(10))
        timeline.annotations = [item(.step(1)), item(.step(5)), item(.step(2))]
        #expect(timeline.nextStepNumber == 6)
    }

    /// Deleting the last step makes its number free again; deleting one from the middle
    /// does not, or the next would repeat a number still on screen. Undo brings back the
    /// step, and with it the number after it.
    @Test func deletingAndUndoingMoveTheNextNumber() {
        var timeline = Timeline(sourceDuration: time(10))
        let steps = [item(.step(1)), item(.step(2)), item(.step(3))]
        timeline.annotations = steps
        #expect(timeline.nextStepNumber == 4)

        var undo = UndoStack()
        undo.record(timeline, name: "Delete")
        #expect(Commands.DeleteRegion(id: steps[2].id).apply(to: &timeline))
        #expect(timeline.nextStepNumber == 3)

        let restored = undo.undo(current: timeline)
        timeline = restored?.timeline ?? timeline
        #expect(timeline.nextStepNumber == 4)

        undo.record(timeline, name: "Delete")
        #expect(Commands.DeleteRegion(id: steps[1].id).apply(to: &timeline))
        #expect(timeline.nextStepNumber == 4, "a gap in the middle is not filled")

        let redone = undo.undo(current: timeline)
        timeline = redone?.timeline ?? timeline
        #expect(timeline.annotations.count == 3)
    }

    @Test func aRenumberedStepMovesTheNextNumber() {
        var timeline = Timeline(sourceDuration: time(10))
        let step = item(.step(1))
        timeline.annotations = [step]
        #expect(Commands.RestyleAnnotation(id: step.id, name: "Step Number") { $0.kind = .step(9) }.apply(to: &timeline))
        #expect(timeline.nextStepNumber == 10)
    }

    @Test func theNextNumberStopsAtTheLargest() {
        var timeline = Timeline(sourceDuration: time(10))
        timeline.annotations = [item(.step(999))]
        #expect(timeline.nextStepNumber == 999)
    }

    // MARK: - Switching kind

    @Test func wordsSurviveASwitchBetweenLabelAndCallout() {
        let callout = AnnotationItem.Kind.text("Save").converted(to: .callout, nextStep: 1)
        #expect(callout == .callout("Save", tail: AnnotationItem.defaultTail))
        #expect(callout.converted(to: .text, nextStep: 1) == .text("Save"))
    }

    @Test func endsSurviveASwitchBetweenArrowAndLine() {
        let from = CGPoint(x: 0.2, y: 0.1), to = CGPoint(x: 0.9, y: 0.8)
        #expect(AnnotationItem.Kind.arrow(from: from, to: to).converted(to: .line, nextStep: 1) == .line(from: from, to: to))
        #expect(AnnotationItem.Kind.line(from: from, to: to).converted(to: .arrow, nextStep: 1) == .arrow(from: from, to: to))
    }

    /// A box turned into a label used to become an empty label, which draws nothing — it
    /// looked as if switching had deleted it.
    @Test func aSwitchNeverMakesSomethingThatDrawsNothing() {
        #expect(AnnotationItem.Kind.rectangle.converted(to: .text, nextStep: 1) == .text("Text"))
        #expect(AnnotationItem.Kind.text("  ").converted(to: .callout, nextStep: 1).text == "Callout")
        #expect(AnnotationItem.Kind.rectangle.converted(to: .arrow, nextStep: 1)
                == .arrow(from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0)))
    }

    @Test func aStepKeepsItsNumberAndANewStepTakesTheNext() {
        #expect(AnnotationItem.Kind.ellipse.converted(to: .step, nextStep: 4) == .step(4))
        #expect(AnnotationItem.Kind.step(2).converted(to: .step, nextStep: 4) == .step(2))
        #expect(AnnotationItem.Kind.step(2).converted(to: .ellipse, nextStep: 4) == .ellipse)
    }

    @Test func thePictureIsNotSwitchable() {
        #expect(!AnnotationItem.KindName.switchable.contains(.image))
        #expect(AnnotationItem.KindName.switchable.count == 8)
    }

    @Test func labelsNameWhatIsOnTheLane() {
        #expect(AnnotationItem.Kind.step(3).label == "Step 3")
        #expect(AnnotationItem.Kind.callout("Here", tail: .zero).label == "Here")
        #expect(AnnotationItem.Kind.callout(" ", tail: .zero).label == "Callout")
        #expect(AnnotationItem.Kind.highlight.label == "Highlight")
        #expect(AnnotationItem.Kind.rectangle.label == "Box")
    }

    @Test func whatEachKindCanBeToldToDo() {
        #expect(AnnotationItem.Kind.ellipse.canBeFilled && AnnotationItem.Kind.rectangle.canBeFilled)
        #expect(!AnnotationItem.Kind.highlight.canBeFilled, "a highlight is always see-through")
        #expect(AnnotationItem.Kind.line(from: .zero, to: .zero).hasThickness)
        #expect(!AnnotationItem.Kind.step(1).hasThickness)
        #expect(AnnotationItem.Kind.callout("", tail: .zero).hasWords && !AnnotationItem.Kind.ellipse.hasWords)
    }

    // MARK: - Ends and tails on the picture

    @Test func aPointOnATurnedBoxRoundTrips() {
        let rect = CGRect(x: 100, y: 50, width: 200, height: 80)
        for rotation in [0.0, 30, -90, 180] {
            for local in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.3, y: 2.2)] {
                let onPicture = AnnotationGeometry.point(local, in: rect, rotation: rotation)
                #expect(close(AnnotationGeometry.local(onPicture, in: rect, rotation: rotation), local, 1e-9))
            }
        }
        // A corner, turned a quarter clockwise about the centre, is where the handle is.
        #expect(close(AnnotationGeometry.point(CGPoint(x: 1, y: 0), in: rect, rotation: 90),
                      AnnotationGeometry.point(of: .topRight, in: rect, rotation: 90), 1e-9))
    }

    @Test func movingAnEndRebuildsTheBoxAroundBothEnds() {
        let result = AnnotationGeometry.ends(from: CGPoint(x: 300, y: 40), to: CGPoint(x: 100, y: 240), minimumSide: 16)
        #expect(result.rect == CGRect(x: 100, y: 40, width: 200, height: 200))
        #expect(close(result.from, CGPoint(x: 1, y: 0)))
        #expect(close(result.to, CGPoint(x: 0, y: 1)))
    }

    /// A flat line still has a box with some height to it — to grab, and to draw the head in.
    @Test func aFlatLineHasABoxYouCanTakeHoldOf() {
        let result = AnnotationGeometry.ends(from: CGPoint(x: 10, y: 100), to: CGPoint(x: 210, y: 100), minimumSide: 16)
        #expect(result.rect.height == 16)
        #expect(result.rect.midY == 100)
        #expect(close(result.from, CGPoint(x: 0, y: 0.5)) && close(result.to, CGPoint(x: 1, y: 0.5)))
    }

    // MARK: - Legibility

    @Test func contrastIsMeasuredTheWayWCAGMeasuresIt() {
        #expect(close(ColorValue.black.contrastRatio(with: .white), 21, 1e-6))
        #expect(close(ColorValue.white.contrastRatio(with: .white), 1))
        #expect(close(ColorValue(r: 0.5, g: 0.5, b: 0.5).relativeLuminance, 0.214, 0.001))
    }

    @Test func onASolidPlateTheWordsAreBlackOrWhite() {
        let solid = AnnotationStyle(backdrop: .solid)
        let yellow = ColorValue(r: 1, g: 0.85, b: 0.1)
        let navy = ColorValue(r: 0.05, g: 0.1, b: 0.35)
        #expect(solid.textColour(for: yellow).relativeLuminance < 0.05, "dark words on yellow")
        #expect(solid.textColour(for: navy) == .white, "white words on navy")
        for colour in [yellow, navy, ColorValue(r: 1, g: 0.23, b: 0.19), ColorValue.white, ColorValue.black] {
            #expect(solid.textColour(for: colour).contrastRatio(with: colour) >= AnnotationStyle.minimumContrast)
        }
        #expect(solid.textColour(for: ColorValue(r: 1, g: 0.23, b: 0.19)) == .white, "white on the default red")
    }

    @Test func onASoftPlateTheColourIsKeptWhereItReads() {
        let white = ColorValue.white, orange = ColorValue(r: 1, g: 0.6, b: 0.1)
        #expect(AnnotationStyle(backdrop: .dark).textColour(for: white) == white)
        #expect(AnnotationStyle(backdrop: .dark).textColour(for: orange) == orange)
        #expect(AnnotationStyle(backdrop: .light).textColour(for: .black) == .black)
        let yellow = ColorValue(r: 1, g: 0.9, b: 0.2)
        #expect(AnnotationStyle().textColour(for: yellow) == yellow, "no plate, no change")
    }

    /// A colour that would vanish keeps its hue and moves just far enough to read: navy
    /// goes lighter on the dark plate, yellow and red go deeper on the light one.
    @Test func onASoftPlateAColourThatWouldVanishIsMovedUntilItReads() {
        let darkPlate = AnnotationStyle.darkPlate.composited(over: .white)
        let lightPlate = AnnotationStyle.lightPlate.composited(over: .black)
        let navy = ColorValue(r: 0.05, g: 0.1, b: 0.35)
        let lighter = AnnotationStyle(backdrop: .dark).textColour(for: navy)
        #expect(lighter != navy && lighter.b > lighter.r, "still blue")
        #expect(lighter.contrastRatio(with: darkPlate) >= AnnotationStyle.minimumContrast)
        for colour in [ColorValue(r: 1, g: 0.9, b: 0.2), ColorValue(r: 1, g: 0.23, b: 0.19)] {
            let deeper = AnnotationStyle(backdrop: .light).textColour(for: colour)
            #expect(deeper.r > deeper.b, "still warm")
            #expect(deeper.contrastRatio(with: lightPlate) >= AnnotationStyle.minimumContrast)
            #expect(deeper.relativeLuminance < colour.relativeLuminance)
        }
    }
}
