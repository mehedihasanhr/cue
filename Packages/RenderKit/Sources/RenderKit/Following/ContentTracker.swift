import CoreGraphics
import Foundation
import Vision

/// Follows one patch of the picture from frame to frame.
///
/// # Why this way
///
/// Measured on synthetic screen content — a textured patch moving in a line, jumping,
/// leaving the frame, a page of text scrolling, a list of look-alike rows scrolling, a
/// window being dragged — Vision's three trackers came out like this (mean error of the
/// patch's centre, 1280 × 720):
///
/// - `VNTrackObjectRequest`: 13 px on a straight line, 26–76 px on the scrolls, 224 px
///   after a jump, and its box grew or shrank by up to 159 px. It is made for objects in
///   camera footage and treats text as clutter.
/// - `VNTrackRectangleRequest`: 6–12 px out on every frame it kept, and lost the scrolling
///   page and the dragged window within a few frames. It wants a rectangle with visible
///   corners, which a line of text is not.
/// - `VNTranslationalImageRegistrationRequest` between the patch in one frame and the same
///   place in the next: exactly 0 px on the line, both scrolls and the exit — screen
///   content moves by whole pixels and registration finds them — but it cannot see a jump
///   bigger than the patch, and on a few frames of the dragged window it answered with
///   nonsense (20–60 px off).
///
/// So registration proposes the move, and the pixels decide. Each frame, three places are
/// tried — where registration says, where the last frame's motion would carry it, and
/// where it was — each with a couple of pixels either side, and the one whose pixels
/// match the patch best wins. That keeps registration's exactness and throws away its bad
/// frames. When none of them matches — a jump — the whole frame is searched, coarse then
/// fine. When that fails too, or too little of the patch is left in the picture, it is
/// lost, and says so rather than guessing.
///
/// Measured the same way (`MaskFollowingTests`, H.264 footage): 0 px on the line, the
/// jump, both scrolls and the exit, and within 1 px on the dragged window.
struct ContentTracker {
    enum Step: Equatable {
        case found(PixelRect)
        case lost
    }

    /// Where the patch is: may hang off the edge of the plane while it leaves the picture.
    private(set) var rect: PixelRect
    /// What is being followed: the patch where it was last wholly in the picture.
    private var template: LumaPatch
    private var previous: LumaPlane
    private var velocity = (x: 0, y: 0)
    /// How different the pixels may be and still be the same thing. Scaled by how much is
    /// in the patch, because a busy patch differs more from itself after compression than
    /// a quiet one does.
    private let tolerance: Float
    private let rowStep: Int

    /// How much of the patch has to be in the picture for a match to count.
    static let minimumVisible = 0.35
    /// Below this there is nothing to recognise: an empty field, a flat colour.
    static let minimumTexture: Float = 3

    init?(plane: LumaPlane, rect: PixelRect) {
        guard rect.width >= 4, rect.height >= 4, rect.isInside(plane.bounds) else { return nil }
        let template = plane.patch(rect)
        let texture = template.texture
        guard texture >= Self.minimumTexture else { return nil }
        self.rect = rect
        self.template = template
        previous = plane
        tolerance = max(5, 0.35 * texture)
        rowStep = max(1, rect.height / 48)
    }

    /// Where the patch is in the next frame.
    mutating func step(to plane: LumaPlane) -> Step {
        let old = rect
        var proposals: [(Int, Int)] = [(velocity.x, velocity.y), (0, 0)]
        if let move = registration(to: plane) { proposals.insert(move, at: 0) }

        var best: (rect: PixelRect, difference: Float)?
        var seen = Set<[Int]>()
        for (dx, dy) in proposals {
            for ry in -2...2 {
                for rx in -2...2 {
                    let candidate = old.offset(dx + rx, dy + ry)
                    guard seen.insert([candidate.x, candidate.y]).inserted,
                          let difference = plane.difference(template, at: (candidate.x, candidate.y),
                                                            rowStep: rowStep, minimumVisible: Self.minimumVisible)
                    else { continue }
                    // Strictly better, with a hair of slack, so noise alone never moves a
                    // patch off where the earlier proposals put it.
                    if best == nil || difference < best!.difference - 0.05 { best = (candidate, difference) }
                }
            }
        }

        if let best, best.difference <= tolerance {
            accept(best.rect, in: plane)
            return .found(best.rect)
        }
        // A jump: only worth looking for while the patch is wholly in the picture. One that
        // is sliding off the edge is not somewhere else, it is going.
        if old.isInside(plane.bounds), let found = search(plane), found.difference <= tolerance {
            accept(found.rect, in: plane)
            velocity = (0, 0)
            return .found(found.rect)
        }
        return .lost
    }

    private mutating func accept(_ found: PixelRect, in plane: LumaPlane) {
        velocity = (found.x - rect.x, found.y - rect.y)
        rect = found
        // The template follows gradual change — a caret blinking, a line being typed — but
        // only from a frame where all of it is in view.
        if found.isInside(plane.bounds) { template = plane.patch(found) }
        previous = plane
    }

    /// Vision's idea of how far the patch moved, in whole pixels.
    private func registration(to plane: LumaPlane) -> (Int, Int)? {
        guard let area = rect.clipped(to: previous.bounds),
              let before = previous.image(area), let after = plane.image(area) else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: after)
        let handler = VNImageRequestHandler(cgImage: before)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }
        let t = observation.alignmentTransform
        guard t.tx.isFinite, t.ty.isFinite else { return nil }
        // Measured rather than reasoned: content that moved right and down comes back as a
        // negative x and a positive y.
        return (Int((-t.tx).rounded()), Int(t.ty.rounded()))
    }

    /// The whole frame, searched for the patch: coarse first, then the best few places
    /// again at full size.
    private func search(_ plane: LumaPlane) -> (rect: PixelRect, difference: Float)? {
        // Coarse enough that the whole frame is a few hundred thousand places to try at
        // most, and no coarser than leaves the patch a few pixels to recognise it by: a
        // mask too small for both is not searched for, only lost.
        let wanted = max(1, min(4, min(template.width, template.height) / 6))
        let needed = Int((Double(plane.width * plane.height) / 160_000).squareRoot().rounded(.up))
        let factor = max(wanted, needed)
        let small = plane.reduced(by: factor)
        let patch = template.reduced(by: factor)
        guard patch.width >= 3, patch.height >= 3, small.width >= patch.width, small.height >= patch.height else { return nil }
        let rowStep = max(1, patch.height / 8)

        var ranked: [(x: Int, y: Int, difference: Float)] = []
        for y in 0...(small.height - patch.height) {
            for x in 0...(small.width - patch.width) {
                guard let difference = small.difference(patch, at: (x, y), rowStep: rowStep) else { continue }
                if ranked.count < 5 || difference < ranked[ranked.count - 1].difference {
                    ranked.append((x, y, difference))
                    ranked.sort { $0.difference < $1.difference }
                    if ranked.count > 5 { ranked.removeLast() }
                }
            }
        }

        var best: (rect: PixelRect, difference: Float)?
        for place in ranked {
            for ry in -factor...factor {
                for rx in -factor...factor {
                    let candidate = PixelRect(x: place.x * factor + rx, y: place.y * factor + ry,
                                              width: rect.width, height: rect.height)
                    guard candidate.isInside(plane.bounds),
                          let difference = plane.difference(template, at: (candidate.x, candidate.y), rowStep: self.rowStep)
                    else { continue }
                    if best == nil || difference < best!.difference { best = (candidate, difference) }
                }
            }
        }
        return best
    }
}
