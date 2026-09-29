import CoreMedia
import Foundation
import Observation
import TimelineKit

/// A drag in progress, held apart from the document.
///
/// Dragging used to apply a command on every mouse-move, and that is what made it feel
/// heavy. A command mutates `Timeline`, and `Timeline` is what the *whole* editor watches:
/// one move of the pointer re-validated the selection, re-reconciled the waveform stores,
/// rebuilt the scene descriptor, queued a decode of the frame under the playhead, and
/// recomputed the audio signature to find out it had not changed. Sixty times a second,
/// for a gesture whose only real output is one number.
///
/// So a drag lives here instead. The rows draw from it, the document hears about it once,
/// when the mouse comes up — which is also the only moment that belongs on the undo stack.
/// Because nothing else reads this object, moving the pointer invalidates the chips being
/// dragged and nothing else: not the preview, not the inspector, not the player.
///
/// It holds the *whole* gesture rather than one item, because a drag with three things
/// selected is still one gesture. Every item moves by the same offset, so a group cannot
/// drift apart under its own rounding.
@MainActor
@Observable
final class TimelineDrag {
    /// What the pointer took hold of. The arithmetic behind it lives in `DragGeometry`,
    /// where it can be checked without a pointer.
    typealias Grip = DragGeometry.Grip

    /// One thing being dragged, as it was when the drag began.
    ///
    /// Measured once at the start and never re-read, so a slow drag accumulates no drift:
    /// every frame is the original geometry plus the current offset, rather than the last
    /// frame's answer plus a little more.
    struct Item: Equatable, Identifiable {
        let id: UUID
        let start: CMTime
        let duration: CMTime
        /// Runs of the recording's own sound clamp differently and mean something different
        /// by a head trim, so they cannot share the regions' path into the model.
        let isSoundRun: Bool

        var end: CMTime { start + duration }
    }

    private(set) var grip: Grip?
    /// Not observed, on purpose. Every chip on every lane asks whether it is part of the
    /// drag, and if that question tracked an observable property then every chip on every
    /// lane would be redrawn on every frame of a gesture that moves three of them. `grip`
    /// is the observed part, and it changes twice — once at each end of the drag — which
    /// is exactly how often a chip that is not being dragged needs to hear anything.
    @ObservationIgnored private var members: Set<UUID> = []
    private(set) var items: [Item] = []
    /// How far the pointer has travelled, in edit time, after snapping.
    private(set) var offset: CMTime = .zero
    /// The edit as it was when the gesture began. Every frame is built from this rather
    /// than from the frame before it, so a slow drag accumulates no drift.
    private var base: Timeline?
    /// The edit as it would be if the mouse came up now.
    ///
    /// Built by running the *real* command on a copy, which is what makes the preview
    /// trustworthy: the chip is drawn wherever the command says it would put it, so there
    /// is no second set of limits to disagree with the first and nothing jumps on release.
    /// The copy is cheap — `Timeline`'s arrays are copy-on-write, so one move touches one
    /// array — and it is the whole cost of a frame of dragging now that the document is
    /// left alone.
    private(set) var preview: Timeline?

    var isActive: Bool { grip != nil }

    /// Whether this drag is carrying more than one thing, which is what the lanes ask to
    /// decide whether to draw a group as a group.
    var isGroup: Bool { items.count > 1 }

    // MARK: - The gesture

    func begin(_ items: [Item], grip: Grip, in timeline: Timeline) {
        guard !items.isEmpty else { return }
        self.items = items
        members = Set(items.map(\.id))
        self.grip = grip
        base = timeline
        preview = timeline
        offset = .zero
    }

    /// Moves the whole gesture. One number for every item in it.
    func update(offset: CMTime) {
        guard isActive, offset != self.offset, var draft = base else { return }
        self.offset = offset
        _ = Commands.MoveMany(moves(for: offset), name: "Drag").apply(to: &draft)
        preview = draft
    }

    /// Where an item is *right now*, or `nil` when it is not part of this drag — which is
    /// what tells a row to draw the item from the document instead.
    func geometry(of id: UUID) -> (start: CMTime, duration: CMTime)? {
        // `grip` first, and observed: this is the read that tells a chip a drag has started
        // or finished. `members` second, and not observed: it is what stops a chip that is
        // not in the drag from going on to read `preview` and being redrawn with it.
        guard grip != nil, members.contains(id), let range = preview?.range(ofRegion: id)
        else { return nil }
        return (range.start, range.duration)
    }

    /// Ends the gesture and hands back where everything landed.
    ///
    /// Empty when nothing actually moved, so a click that happened to wobble a pixel costs
    /// no undo entry.
    func end() -> [Commands.MoveMany.Move] {
        defer { cancel() }
        guard offset != .zero else { return [] }
        return moves(for: offset)
    }

    func cancel() {
        items = []
        members = []
        grip = nil
        offset = .zero
        base = nil
        preview = nil
    }

    /// What the gesture is asking for, item by item.
    private func moves(for offset: CMTime) -> [Commands.MoveMany.Move] {
        guard let grip else { return [] }
        return items.map { item in
            let wanted = DragGeometry.proposal(start: item.start, duration: item.duration,
                                               grip: grip, offset: offset)
            return Commands.MoveMany.Move(
                id: item.id,
                start: wanted.start,
                // A move keeps its length, and saying so with `nil` rather than passing the
                // same number back is what lets the command name itself correctly and lets
                // a move skip the length clamp entirely.
                duration: grip == .body ? nil : wanted.duration,
                isSoundRun: item.isSoundRun,
                // A head drag on a sound run trims it: the recording stays put underneath
                // and the run shows less of it. A body drag slides the whole thing and must
                // not re-cut it.
                trimsHead: item.isSoundRun && grip == .head)
        }
    }

}
