import Foundation

public extension Commands {
    /// Dressing the project in a look, as one step.
    ///
    /// One command rather than a `Restyle` per field, because that is what the user did:
    /// they chose a look, and ⌘Z has to take the whole of it back rather than one slider
    /// at a time. A look that changes nothing — the project is already wearing it — is
    /// refused, so it costs no undo entry.
    struct ApplyLook: TimelineCommand {
        public let look: Look
        public var name: String { "Apply Look" }

        public init(_ look: Look) { self.look = look }

        public func apply(to timeline: inout Timeline) -> Bool {
            let before = timeline
            look.apply(to: &timeline)
            return timeline != before
        }
    }
}
