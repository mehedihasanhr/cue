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

    /// Sends the bubble somewhere new, arriving at a moment.
    ///
    /// The glide happens just before `time`, so the frame somebody is looking at while they
    /// drag is the frame that shows the bubble where they put it. It stays there until the
    /// next move, or until the end of the stretch it was made inside. Made so close to the
    /// start of a move that there is no room for another, it changes that move instead.
    struct PlaceCamera: TimelineCommand {
        public let id: UUID
        public let time: CMTime
        public let placement: CameraPlacement
        public var name: String { "Move Camera" }

        public init(id: UUID = UUID(), at time: CMTime, placement: CameraPlacement) {
            self.id = id
            self.time = time
            self.placement = placement
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            let length = timeline.duration
            guard length > .zero else { return false }
            let time = min(max(time, .zero), length)
            let glide = CMTime(seconds: Timeline.cameraMoveTransition, preferredTimescale: 600)
            let start = max(.zero, time - glide)
            let placed = timeline.cameraLayouts.filter { $0.placement != nil }
            var end = placed.filter { $0.start > time }.map(\.start).min() ?? length

            if let current = CameraLayoutSegment.winner(in: placed, at: time.seconds),
               let index = timeline.cameraLayouts.firstIndex(where: { $0.id == current.id }) {
                // Still gliding there: cutting it short would stop it part way.
                if start - current.start < glide {
                    timeline.cameraLayouts[index].placement = placement
                    timeline.webcam.isEnabled = true
                    return true
                }
                end = min(end, current.end)
                timeline.cameraLayouts[index].duration = start - current.start
            }
            guard end - start >= Clip.minimumDuration else { return false }
            timeline.cameraLayouts.append(CameraLayoutRegion(id: id, start: start, duration: end - start,
                                                             layout: .bubble, placement: placement))
            timeline.cameraLayouts.sort { $0.start < $1.start }
            timeline.webcam.isEnabled = true
            return true
        }
    }

    /// Changes where one stretch puts the bubble; `nil` hands it back to the Webcam panel.
    struct SetCameraPlacement: TimelineCommand {
        public let id: UUID
        public let placement: CameraPlacement?
        public var name: String { "Move Camera" }

        public init(id: UUID, placement: CameraPlacement?) {
            self.id = id
            self.placement = placement
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.cameraLayouts.firstIndex(where: { $0.id == id }),
                  timeline.cameraLayouts[index].placement != placement else { return false }
            timeline.cameraLayouts[index].placement = placement
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
