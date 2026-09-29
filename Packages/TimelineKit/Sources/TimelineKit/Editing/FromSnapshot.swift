extension Commands {
    /// A command applied to the timeline as it was when a gesture began, rather than to
    /// what the gesture's previous step left.
    ///
    /// For a drag that applies its edit on every mouse movement. Applied step on step, an
    /// edit that takes something away can never give it back: drag a trim in past a zoom
    /// and out again, and the zoom stayed deleted, because each step only ever saw the
    /// timeline the last one had already cut. Replayed from the start, the drag is always
    /// one edit of the original, however far it has wandered.
    public struct FromSnapshot<Base: TimelineCommand>: TimelineCommand {
        public let snapshot: Timeline
        public let base: Base
        public var name: String { base.name }

        public init(_ base: Base, on snapshot: Timeline) {
            self.base = base
            self.snapshot = snapshot
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            var replayed = snapshot
            base.apply(to: &replayed)
            // Back where it started counts too: that is the drag returning to the origin.
            guard replayed != timeline else { return false }
            timeline = replayed
            return true
        }
    }
}
