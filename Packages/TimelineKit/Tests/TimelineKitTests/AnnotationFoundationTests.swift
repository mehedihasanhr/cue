import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// The annotation model underneath every kind: what is stored, how it is read back, how it
/// is moved, turned and animated, and what can never get into a project file.
struct AnnotationFoundationTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private func item(start: Double = 0, duration: Double = 3,
                      rect: CGRect = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1)) -> AnnotationItem {
        AnnotationItem(start: time(start), duration: time(duration), kind: .text("Hi"), rect: rect)
    }

    private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) < tolerance }

    private func close(_ a: CGRect, _ b: CGRect, _ tolerance: Double = 1e-9) -> Bool {
        close(a.minX, b.minX, tolerance) && close(a.minY, b.minY, tolerance)
            && close(a.width, b.width, tolerance) && close(a.height, b.height, tolerance)
    }

    // MARK: - Reading old projects

    /// A project written before the shared fields existed: none of the new keys are in the
    /// file. It has to open, and look exactly as it did.
    @Test func anAnnotationFromBeforeTheSharedFieldsOpensAsItWas() throws {
        let original = item()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["rotation", "opacity", "animation", "isLocked", "isHidden", "attachment"] {
            json.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(AnnotationItem.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == original)
        #expect(decoded.rotation == 0)
        #expect(decoded.opacity == 1)
        #expect(decoded.animation == AnnotationAnimation())
        #expect(!decoded.isLocked && !decoded.isHidden)
        #expect(decoded.attachment == .canvas)
    }

    /// The lane is decoded as one array; a field in one item that cannot be read must not
    /// take every other annotation in the project with it.
    @Test func oneUnreadableFieldDoesNotLoseTheLane() throws {
        var timeline = Timeline(sourceDuration: time(10))
        timeline.annotations = [item(), item(start: 4)]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline)) as? [String: Any])
        var lane = try #require(json["annotations"] as? [[String: Any]])
        lane[0]["rotation"] = "sideways"
        lane[1]["animation"] = ["entrance": "cartwheel"]
        json["annotations"] = lane
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.annotations.count == 2)
        #expect(decoded.annotations[0].rotation == 0)
        #expect(decoded.annotations[1].animation.entrance == .fade)
    }

    /// Everything an annotation has survives a save and a reopen, including the order.
    @Test func everyFieldSurvivesSaveAndReopen() throws {
        var timeline = Timeline(sourceDuration: time(10))
        let styled = AnnotationItem(start: time(1.25), duration: time(2.5),
                                    kind: .arrow(from: CGPoint(x: 0.1, y: 0.9), to: CGPoint(x: 0.8, y: 0.2)),
                                    rect: CGRect(x: -0.05, y: 0.4, width: 0.5, height: 0.2),
                                    color: ColorValue(r: 0.1, g: 0.5, b: 0.9, a: 0.8),
                                    fontSize: 0.09,
                                    rotation: -32.5,
                                    opacity: 0.6,
                                    animation: AnnotationAnimation(entrance: .pop, exit: .slideDown,
                                                                   entranceDuration: 0.4, exitDuration: 0.6,
                                                                   easing: .spring),
                                    isLocked: true,
                                    isHidden: true,
                                    attachment: .content)
        timeline.annotations = [item(), styled, item(start: 5)]
        let reopened = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(reopened.annotations == timeline.annotations)
    }

    // MARK: - Nothing undrawable gets in

    @Test func unreadableNumbersBecomeDefaultsRatherThanBrokenAnnotations() {
        let broken = AnnotationItem(start: time(1), duration: time(2), kind: .text("x"),
                                    rect: CGRect(x: .nan, y: 0.2, width: 0.3, height: .infinity),
                                    fontSize: .nan, rotation: .infinity, opacity: .nan)
        #expect(broken.rect.origin.x.isFinite && broken.rect.width.isFinite && broken.rect.height.isFinite)
        #expect(broken.fontSize.isFinite)
        #expect(broken.rotation == 0)
        #expect(broken.opacity == 1)
    }

    @Test func aNegativeOrZeroSizeIsNeverStored() {
        let flipped = AnnotationItem(start: .zero, duration: time(1), kind: .rectangle,
                                     rect: CGRect(x: 0.5, y: 0.5, width: -0.2, height: 0))
        #expect(flipped.rect.width > 0 && flipped.rect.height > 0)
        #expect(close(flipped.rect.minX, 0.3), "a negative width is the same box drawn the other way")
    }

    @Test func aRestyleCannotWriteNaNIntoTheProject() {
        var timeline = Timeline(sourceDuration: time(10))
        let annotation = item()
        timeline.annotations = [annotation]
        _ = Commands.RestyleAnnotation(id: annotation.id, name: "Rotate") { $0.rotation = .nan }
            .apply(to: &timeline)
        #expect(timeline.annotations[0].rotation.isFinite)
    }

    @Test func anglesAreKeptInOneTurn() {
        #expect(AnnotationGeometry.normalisedDegrees(370) == 10)
        #expect(AnnotationGeometry.normalisedDegrees(-190) == 170)
        #expect(AnnotationGeometry.normalisedDegrees(180) == 180)
        #expect(AnnotationGeometry.normalisedDegrees(-180) == 180)
    }

    // MARK: - Resizing

    private let box = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test func draggingACornerHoldsTheOppositeOne() {
        let resized = AnnotationGeometry.resize(box, rotation: 0, dragging: .bottomRight,
                                                to: CGPoint(x: 400, y: 260), minimumSide: 10)
        #expect(close(resized, CGRect(x: 100, y: 100, width: 300, height: 160)))
    }

    @Test func draggingAnEdgeChangesOnlyThatDirection() {
        let resized = AnnotationGeometry.resize(box, rotation: 0, dragging: .left,
                                                to: CGPoint(x: 50, y: 999), minimumSide: 10)
        #expect(close(resized, CGRect(x: 50, y: 100, width: 250, height: 100)))
    }

    @Test func aHandleDraggedPastTheOtherSideStopsAtTheMinimum() {
        let resized = AnnotationGeometry.resize(box, rotation: 0, dragging: .right,
                                                to: CGPoint(x: 0, y: 150), minimumSide: 10)
        #expect(close(resized, CGRect(x: 100, y: 100, width: 10, height: 100)))
    }

    @Test func aCornerCanKeepTheShape() {
        let resized = AnnotationGeometry.resize(box, rotation: 0, dragging: .bottomRight,
                                                to: CGPoint(x: 500, y: 210), minimumSide: 10,
                                                keepingAspect: true)
        #expect(close(resized.width / resized.height, 2))
        #expect(close(resized.width, 400))
        #expect(close(resized.minX, 100) && close(resized.minY, 100))
    }

    /// Turned, the held corner is held *on the picture*: where it was drawn before the drag
    /// is where it is drawn after.
    @Test func aTurnedBoxHoldsItsOppositeCornerOnThePicture() {
        let rotation = 30.0
        let held = AnnotationGeometry.point(of: .topLeft, in: box, rotation: rotation)
        let target = CGPoint(x: 420, y: 330)
        let resized = AnnotationGeometry.resize(box, rotation: rotation, dragging: .bottomRight,
                                                to: target, minimumSide: 10)
        let heldAfter = AnnotationGeometry.point(of: .topLeft, in: resized, rotation: rotation)
        #expect(close(held.x, heldAfter.x, 1e-6) && close(held.y, heldAfter.y, 1e-6))
        let dragged = AnnotationGeometry.point(of: .bottomRight, in: resized, rotation: rotation)
        #expect(close(dragged.x, target.x, 1e-6) && close(dragged.y, target.y, 1e-6),
                "the dragged corner lands under the pointer")
    }

    /// The same resize, asked in normalised coordinates of a 16:9 frame, lands on the same
    /// picture as asking in pixels. This is the check that rotation is not being done in a
    /// squashed space.
    @Test func normalisedAndPixelResizesAgree() {
        let size = CGSize(width: 1920, height: 1080)
        let rotation = 25.0
        let normalised = CGRect(x: 0.2, y: 0.3, width: 0.25, height: 0.15)
        let pointer = CGPoint(x: 0.62, y: 0.58)
        let inPixels = AnnotationGeometry.resize(
            CGRect(x: normalised.minX * size.width, y: normalised.minY * size.height,
                   width: normalised.width * size.width, height: normalised.height * size.height),
            rotation: rotation, dragging: .bottomRight,
            to: CGPoint(x: pointer.x * size.width, y: pointer.y * size.height),
            minimumSide: 1)
        let inFrame = AnnotationGeometry.resize(normalised, rotation: rotation, dragging: .bottomRight,
                                                to: pointer, minimumSide: 0.001,
                                                aspect: size.width / size.height)
        #expect(close(inFrame.minX * size.width, inPixels.minX, 1e-6))
        #expect(close(inFrame.minY * size.height, inPixels.minY, 1e-6))
        #expect(close(inFrame.width * size.width, inPixels.width, 1e-6))
        #expect(close(inFrame.height * size.height, inPixels.height, 1e-6))
    }

    // MARK: - Rotating

    @Test func pointingStraightUpIsLevel() {
        #expect(close(AnnotationGeometry.rotation(of: box, toward: CGPoint(x: 200, y: 0)), 0))
    }

    @Test func pointingRightIsAQuarterTurnClockwise() {
        #expect(close(AnnotationGeometry.rotation(of: box, toward: CGPoint(x: 500, y: 150)), 90))
    }

    @Test func snappingLandsOnTheStep() {
        let angle = AnnotationGeometry.rotation(of: box, toward: CGPoint(x: 260, y: 20), snapping: true)
        #expect(angle.truncatingRemainder(dividingBy: 15) == 0)
    }

    @Test func theRotationHandleTurnsWithTheBox() {
        let handle = AnnotationGeometry.rotationHandle(of: box, rotation: 90, reach: 20)
        // Turned a quarter clockwise, "above" is to the right of the centre.
        #expect(close(handle.x, 200 + 50 + 20, 1e-6) && close(handle.y, 150, 1e-6))
    }

    // MARK: - Animation

    @Test func theDefaultIsTheQuarterSecondFadeEveryAnnotationAlwaysHad() {
        let animation = AnnotationAnimation()
        #expect(animation.pose(atOffset: 0, of: 3).opacity == 0)
        #expect(close(animation.pose(atOffset: 0.125, of: 3).opacity, 0.5))
        #expect(animation.pose(atOffset: 1.5, of: 3).opacity == 1)
        #expect(close(animation.pose(atOffset: 2.875, of: 3).opacity, 0.5))
        #expect(animation.pose(atOffset: 3, of: 3).opacity == 0)
    }

    @Test func noneMeansThereFromTheFirstFrameToTheLast() {
        let animation = AnnotationAnimation(entrance: .none, exit: .none)
        #expect(animation.pose(atOffset: 0, of: 3) == AnnotationPose())
        #expect(animation.pose(atOffset: 3, of: 3) == AnnotationPose())
    }

    @Test func aSlideArrivesFromBelowAndSettlesAtHome() {
        let animation = AnnotationAnimation(entrance: .slideUp, exit: .none, entranceDuration: 0.5)
        #expect(close(animation.pose(atOffset: 0, of: 3).offset.dy, AnnotationAnimation.slideDistance))
        #expect(animation.pose(atOffset: 0.5, of: 3).offset == .zero)
    }

    @Test func aSlideDownExitLeavesDownwards() {
        let animation = AnnotationAnimation(entrance: .none, exit: .slideDown, exitDuration: 0.5)
        #expect(animation.pose(atOffset: 3, of: 3).offset.dy > 0)
        #expect(animation.pose(atOffset: 2.5, of: 3).offset == .zero)
    }

    @Test func aPopOvershootsBeforeItSettles() {
        let animation = AnnotationAnimation(entrance: .pop, exit: .none, entranceDuration: 1)
        let peak = stride(from: 0.0, through: 1, by: 0.01).map { animation.pose(atOffset: $0, of: 4).scale }.max() ?? 0
        #expect(peak > 1.01)
        #expect(close(animation.pose(atOffset: 1, of: 4).scale, 1, 1e-6))
    }

    /// A one-second annotation with one-second ends: each end gets half, so the middle
    /// frame is still fully there.
    @Test func aShortAnnotationStillReachesFullStrength() {
        let animation = AnnotationAnimation(entrance: .fade, exit: .fade, entranceDuration: 1, exitDuration: 1)
        #expect(animation.pose(atOffset: 0.5, of: 1).opacity == 1)
    }

    @Test func theAnnotationsOwnOpacityIsOnTopOfTheAnimation() {
        var faint = item()
        faint.opacity = 0.5
        #expect(faint.pose(atOffset: 1.5).opacity == 0.5)
    }

    @Test func aZeroLengthAnnotationHasAPoseRatherThanANaN() {
        let pose = AnnotationAnimation().pose(atOffset: 0, of: 0)
        #expect(pose.opacity.isFinite && pose.scale.isFinite)
    }

    // MARK: - Locked

    @Test func aLockedAnnotationDoesNotMoveOnThePicture() {
        var timeline = Timeline(sourceDuration: time(10))
        var locked = item()
        locked.isLocked = true
        timeline.annotations = [locked]
        let moved = Commands.SetRegionRect(id: locked.id, rect: CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.1))
            .apply(to: &timeline)
        #expect(!moved)
        #expect(timeline.annotations[0].rect == locked.rect)
    }

    @Test func aLockedAnnotationDoesNotMoveOnTheTimeline() {
        var timeline = Timeline(sourceDuration: time(10))
        var locked = item(start: 1)
        locked.isLocked = true
        timeline.annotations = [locked]
        #expect(!Commands.MoveRegion(id: locked.id, start: time(4)).apply(to: &timeline))
        #expect(timeline.annotations[0].start == time(1))
    }

    @Test func aLockedAnnotationCanStillBeRestyled() {
        var timeline = Timeline(sourceDuration: time(10))
        var locked = item()
        locked.isLocked = true
        timeline.annotations = [locked]
        #expect(Commands.RestyleAnnotation(id: locked.id, name: "Colour") { $0.opacity = 0.4 }.apply(to: &timeline))
    }

    // MARK: - Stacking order

    private func stack(_ items: [AnnotationItem]) -> Timeline {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.annotations = items
        return timeline
    }

    @Test func bringToFrontPutsItLast() {
        let a = item(), b = item(), c = item()
        var timeline = stack([a, b, c])
        #expect(Commands.ReorderAnnotation(id: a.id, .toFront).apply(to: &timeline))
        #expect(timeline.annotations.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func sendToBackPutsItFirst() {
        let a = item(), b = item(), c = item()
        var timeline = stack([a, b, c])
        #expect(Commands.ReorderAnnotation(id: c.id, .toBack).apply(to: &timeline))
        #expect(timeline.annotations.map(\.id) == [c.id, a.id, b.id])
    }

    /// Forward means past the next one it can actually be seen with — not past one that
    /// is on screen at a different time, which would change nothing anybody could see.
    @Test func bringForwardSkipsAnnotationsItNeverOverlaps() {
        let a = item(start: 0, duration: 3)
        let elsewhere = item(start: 10, duration: 3)
        let over = item(start: 1, duration: 3)
        var timeline = stack([a, elsewhere, over])
        #expect(Commands.ReorderAnnotation(id: a.id, .forward).apply(to: &timeline))
        #expect(timeline.annotations.map(\.id) == [elsewhere.id, over.id, a.id])
    }

    @Test func theFrontOneCannotComeFurtherForward() {
        let a = item(), b = item()
        var timeline = stack([a, b])
        #expect(!Commands.ReorderAnnotation(id: b.id, .toFront).apply(to: &timeline))
        #expect(!Commands.ReorderAnnotation(id: b.id, .forward).apply(to: &timeline))
    }

    // MARK: - Copies

    /// A duplicate is the same annotation somewhere else: turned, faded and animated the
    /// same. Only the lock is left behind.
    @Test func aCopyKeepsEverythingButTheLock() throws {
        var timeline = Timeline(sourceDuration: time(10))
        let original = AnnotationItem(start: time(1), duration: time(2), kind: .text("Look"),
                                      rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1),
                                      rotation: 12, opacity: 0.7,
                                      animation: AnnotationAnimation(entrance: .pop, exit: .slideLeft),
                                      isLocked: true, attachment: .content)
        timeline.annotations = [original]
        let copied = try #require(CopiedRegion(.annotation(original.id), in: timeline))
        guard case .annotation(let pasted) = copied.placed(at: time(5), in: timeline) else {
            Issue.record("a copied annotation should paste as an annotation")
            return
        }
        #expect(pasted.id != original.id)
        #expect(pasted.start == time(5))
        #expect(pasted.rotation == 12 && pasted.opacity == 0.7)
        #expect(pasted.animation == original.animation)
        #expect(pasted.attachment == .content)
        #expect(!pasted.isLocked)
    }
}
