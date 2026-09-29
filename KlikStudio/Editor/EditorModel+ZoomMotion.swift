import CoreMedia
import TimelineKit

/// How a zoom arrives and leaves: instantly or smoothly, and gliding into the next.
extension EditorModel {
    // MARK: - Instant

    /// Makes the active zoom a cut, or a movement again. See `ZoomRegion.isInstant`.
    func toggleZoomInstant() {
        guard let zoom = activeZoom else { return }
        let instant = !zoom.isInstant
        apply(Commands.RestyleZoom(id: zoom.id, name: instant ? "Instant Zoom" : "Smooth Zoom") {
            $0.isInstant = instant
        })
    }

    /// Whether the zoom the inspector is about cuts rather than moves. `false` when
    /// there is none, so a control bound to this does not flicker as the selection changes.
    var isActiveZoomInstant: Bool { activeZoom?.isInstant ?? false }

    // MARK: - Extend to the next zoom

    /// The zoom the active one would be lengthened to meet: the next along the lane.
    var zoomToExtendInto: ZoomRegion? {
        guard let zoom = activeZoom else { return nil }
        return ZoomLane.zoomAfter(zoom.id, in: timeline.zooms)
    }

    /// Why "Extend to Next Zoom" would do nothing, or `nil` when it would do something.
    ///
    /// The reason is written beside the control rather than left to a grey button: a
    /// disabled button with no explanation is the commonest way an editor makes someone
    /// feel they have done something wrong.
    var extendToNextZoomReason: String? {
        guard let zoom = activeZoom else { return "Select a zoom, or put the playhead inside one." }
        guard let next = zoomToExtendInto else { return "There is no zoom after this one." }
        guard next.start > zoom.end else { return "This zoom already reaches the next one." }
        return nil
    }

    var canExtendZoomToNext: Bool { extendToNextZoomReason == nil }

    /// Lengthens the active zoom to end exactly where the next one begins, so the two
    /// glide. Leaves it selected, since that is the one that changed.
    func extendZoomToNext() {
        guard let zoom = activeZoom, canExtendZoomToNext else { return }
        apply(Commands.ExtendZoomToNext(id: zoom.id))
        select(.zoom(zoom.id))
    }

    // MARK: - Gliding, for the whole project

    var glidesBetweenZooms: Bool { timeline.camera.glidesBetweenZooms }

    /// Turns gliding on or off for every zoom in the project. An edit like any other —
    /// it changes the exported film — and undoable like any other.
    func setGlidesBetweenZooms(_ glides: Bool) {
        guard glides != timeline.camera.glidesBetweenZooms else { return }
        apply(Commands.Restyle(glides ? "Glide Between Zooms" : "Stop Gliding Between Zooms") {
            $0.camera.glidesBetweenZooms = glides
        })
    }
}
