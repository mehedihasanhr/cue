import Foundation
import os

/// A few recently drawn things, kept.
///
/// The overlays are drawn through Core Graphics — a bitmap context, a font, a layout pass
/// — and they are drawn *per frame*, which is the shape of cost `CursorArtwork` already
/// decided was worth keeping. A caption plate is the expensive one: measured at 1080p it
/// is 288 µs of the 358 µs it takes to build a whole frame's Core Image graph, and at 4K
/// it is 1.07 ms of 1.17 ms. None of it varies while a line is being spoken, so almost all
/// of it is the same plate drawn again thirty times a second.
///
/// Bounded, and small. An unbounded cache in a per-frame path is not a cache, it is a leak
/// with a slow fuse: a caption changes every couple of seconds and an annotation's
/// rectangle changes while it is being dragged, so without a ceiling a long session would
/// keep every plate anybody ever saw.
///
/// The correctness rule this lives under: **the key must name everything the drawing
/// depends on.** A cache that is missing a field silently draws yesterday's picture, which
/// is the one failure mode here that reaches a finished video — so the callers key on the
/// bitmap's inputs only, and apply placement and opacity outside, where they are an affine
/// transform and a colour matrix rather than a redraw.
final class ArtworkCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Storage {
        /// Insertion order, oldest first. An array rather than a linked list because the
        /// capacity is a handful: a linear scan of eight entries is faster than the
        /// book-keeping a smarter structure would need.
        var entries: [(key: Key, value: Value)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: Storage())
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// The cached value, or `make()`'s, remembered.
    ///
    /// `make` runs outside the lock: drawing a plate takes hundreds of microseconds, and
    /// holding an unfair lock across it would serialise the preview's render thread behind
    /// the exporter's. Two threads missing on the same key both draw, and the second
    /// simply replaces the first — the values are equal by construction, so the only cost
    /// is one wasted drawing, and that is cheaper than the contention.
    func value(for key: Key, make: () -> Value?) -> Value? {
        let hit = state.withLock { storage -> Value? in
            guard let index = storage.entries.firstIndex(where: { $0.key == key }) else { return nil }
            // Moved to the back, so "oldest" means least recently used rather than least
            // recently made: a caption held on screen for a minute must not age out
            // behind the annotations that came and went over it.
            let entry = storage.entries.remove(at: index)
            storage.entries.append(entry)
            return entry.value
        }
        if let hit { return hit }

        guard let made = make() else { return nil }
        state.withLock { storage in
            storage.entries.removeAll { $0.key == key }
            storage.entries.append((key, made))
            while storage.entries.count > self.capacity { storage.entries.removeFirst() }
        }
        return made
    }

    /// Empties it, so a test can ask what a cold draw looks like.
    ///
    /// The fidelity tests need this: a cache shared between renderer instances means a
    /// "fresh" `SceneRenderer` is not actually drawing anything cold, and a test comparing
    /// the two would pass however wrong the key was.
    func removeAll() {
        state.withLock { $0.entries.removeAll() }
    }
}
