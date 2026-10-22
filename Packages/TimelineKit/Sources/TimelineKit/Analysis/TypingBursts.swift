import Foundation
import RecordKit

/// A stretch of continuous typing: when it began, when it stopped, how many keys.
public struct TypingBurst: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var presses: Int

    public init(start: Double, end: Double, presses: Int) {
        self.start = start
        self.end = end
        self.presses = presses
    }
}

/// Finds the typing in a recording's presses.
///
/// Reads the identity-less presses — the ones the recorder wrote as "a key went down"
/// and nothing more — which is all that typing ever is in a `.cuerec`. A shortcut is
/// somebody operating the app, and is left out; the pure function here needs no other
/// filter, because the privacy rule already sorted the two on the way in.
public enum Typing {
    /// Keys that edit what is being typed. Pressed on their own they keep a burst going
    /// — deleting a word and retyping it is one stretch of typing — but they never start
    /// one and never count towards it being long enough: a run of arrow presses through
    /// a list is not typing.
    static let editingKeys: Set<NamedKey> = [.delete, .forwardDelete, .return, .enter,
                                             .left, .right, .up, .down, .home, .end]

    /// The bursts, oldest first, none touching.
    ///
    /// - Parameters:
    ///   - gap: presses further apart than this are two bursts.
    ///   - minimumPresses: fewer than this is not typing — a shortcut somebody used the
    ///     other hand for, a single character.
    ///   - boundaries: moments a burst may not cross. Focus changes go here: what was
    ///     typed after tabbing into the next field is typed into *that* field, and a
    ///     camera on the first one would be looking at the wrong thing.
    public static func bursts(in input: [InputSample],
                              gap: Double = 1.5,
                              minimumPresses: Int = 4,
                              splitAt boundaries: [Double] = []) -> [TypingBurst] {
        let events = input.compactMap { sample -> (t: Double, counts: Bool)? in
            switch sample {
            case .key where sample.isTyping:
                return (sample.t, true)
            case .shortcut(let t, let modifiers, let key):
                guard modifiers.isDisjoint(with: .operating),
                      let named = NamedKey(name: key), editingKeys.contains(named) else { return nil }
                return (t, false)
            default:
                return nil
            }
        }.sorted { $0.t < $1.t }
        let walls = boundaries.sorted()

        var bursts: [TypingBurst] = []
        var current: TypingBurst?

        func flush() {
            if let burst = current, burst.presses >= minimumPresses { bursts.append(burst) }
            current = nil
        }

        for event in events {
            if let burst = current {
                let crossed = walls.contains { $0 > burst.end && $0 <= event.t }
                if event.t - burst.end > gap || crossed { flush() }
            }
            if current == nil {
                // An editing key never starts a burst: Delete on its own is not typing.
                guard event.counts else { continue }
                current = TypingBurst(start: event.t, end: event.t, presses: 1)
            } else {
                current!.end = event.t
                if event.counts { current!.presses += 1 }
            }
        }
        flush()
        return bursts
    }
}
