import CoreMedia
import Foundation

/// The edits the camera lane makes. Moving, resizing, deleting, copying and pasting a
/// layout region go through the commands every lane shares; these are the ones only this
/// lane has.
public extension Commands {
    /// A stretch with its own camera layout.
    ///
    /// Switches the camera on in the same edit when it was off, so the stretch shows what
    /// it says: "Camera Only" over a switched-off camera would be a chip that changes no
    /// pixel, and an undo that took the stretch away but left the camera on would be two
    /// edits pretending to be one. Refuses a region off the end of the edit or too short to
    /// grab, as `AddCursorRegion` does.
    struct AddCameraLayout: TimelineCommand {
        public let region: CameraLayoutRegion
        public var name: String { Self.name(for: region.layout) }

        public init(_ region: CameraLayoutRegion) { self.region = region }

        /// What the undo stack calls adding one of these — the menu item's own words.
        public static func name(for layout: CameraLayout) -> String {
            switch layout {
            case .bubble: "Camera Bubble"
            case .cameraOnly: "Camera Only"
            case .sideBySide: "Side by Side"
            case .hidden: "Hide Camera"
            }
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard region.duration >= Clip.minimumDuration, region.start < timeline.duration else { return false }
            var region = region
            region.start = max(.zero, region.start)
            region.duration = min(region.duration, timeline.duration - region.start)
            guard region.duration >= Clip.minimumDuration else { return false }
            timeline.cameraLayouts.append(region)
            // Sorted for the reason `AddCursorRegion` sorts: an inspector open on one
            // region must not find itself pointing at another after an insertion.
            timeline.cameraLayouts.sort { $0.start < $1.start }
            if region.layout != .hidden { timeline.webcam.isEnabled = true }
            return true
        }
    }

    /// Changing what one layout region does. By id, for the reason `RestyleCursorRegion`
    /// is: the lane is kept in start order, so an index can change under an open inspector.
    struct SetCameraLayout: TimelineCommand {
        public let id: UUID
        public let layout: CameraLayout
        public var name: String { "Camera Layout" }

        public init(id: UUID, layout: CameraLayout) {
            self.id = id
            self.layout = layout
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.cameraLayouts.firstIndex(where: { $0.id == id }),
                  timeline.cameraLayouts[index].layout != layout else { return false }
            timeline.cameraLayouts[index].layout = layout
            if layout != .hidden { timeline.webcam.isEnabled = true }
            return true
        }
    }

    /// Takes every layout region off the lane: the bubble everywhere again.
    struct RemoveCameraLayouts: TimelineCommand {
        public var name: String { "Remove Camera Layouts" }
        public init() {}

        public func apply(to timeline: inout Timeline) -> Bool {
            guard !timeline.cameraLayouts.isEmpty else { return false }
            timeline.cameraLayouts = []
            return true
        }
    }
}
