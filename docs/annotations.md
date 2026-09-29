# Annotations

Where the annotation system stands, what it is built on, and what comes next. Written
before Phase 1 of the annotation work and updated as phases land.

## Audit (before Phase 1)

### What already existed and is reused

| Piece | Where | Verdict |
|---|---|---|
| Model: one `AnnotationItem` per annotation, its own start and duration on the timeline | `TimelineKit/Model/Regions.swift` | Kept and extended. Already a first-class `TimelineRegion`, so dragging, trimming, snapping, copy/paste and delete on the timeline came for free. |
| Coordinates: `rect` normalised 0…1 to the **finished frame**, top-left origin; font size a fraction of the output height | model + `PictureMapping` | Kept. This is already the "one authoritative coordinate system" the spec asks for. Window resizes, export sizes and reopening cannot move an annotation. |
| Preview ↔ canvas mapping | `CanvasGeometry` / `PictureMapping` (`RegionCanvas.swift`, TimelineKit) | Kept. One affine mapping each way, already tested. |
| Rendering | `SceneBuilder.annotationLayers` → `SceneRenderer.annotationImage` → `AnnotationArtwork` | Kept. **Preview and export are the same code path**: the preview is the export renderer at a smaller size. Artwork is drawn at output resolution, so text stays sharp. |
| Undo | `TimelineCommand`s (`AddAnnotation`, `SetRegionRect`, `RestyleAnnotation`) grouped by `document.beginInteraction` / `finishInteraction` | Kept. A drag or a slider is already one undo step. |
| Timeline lane | `TimelineRegionRow` (the Notes lane) | Kept; each annotation is its own chip. |
| Blur / pixelate | `BlurRegion`, the Blur tool | Already a real blur of the underlying video in preview and export. The spec's privacy blur exists; it is not an annotation kind and does not need to become one. |

### What was unsafe

1. **Decoding was all-or-nothing.** `AnnotationItem` used the synthesised decoder, and the
   timeline decodes the lane as one array: one unreadable field in one annotation emptied
   the whole annotation lane on open. Any new field would have broken every older project.
2. **No guard against undrawable numbers.** NaN, infinite or negative sizes could reach
   the project file from a drag against a stage that had not laid out.
3. **Copy, duplicate and paste rebuilt an annotation from four fields**, so anything added
   later would silently be dropped from copies.
4. **Switching to Arrow in the inspector wrote the arrow's ends in the wrong space** — frame
   coordinates into a field that is normalised to the annotation's own rect.
5. **Stacking order was implicit.** It was the lane's array order, but nothing said so and
   nothing could change it.
6. **Content-attached annotations are not possible yet.** Annotations are pinned to the
   finished frame, so an arrow at a button does not follow the button into a zoom. Blurs are
   the opposite (pinned to the recording). Both mappings already exist in `CanvasGeometry`.

## Phase 1 — done

Model (`AnnotationItem`) gains the fields every kind shares:

- `rotation` (degrees, clockwise on the picture, about the centre)
- `opacity`
- `animation` (`AnnotationAnimation`: entrance, exit, their lengths, easing)
- `isLocked` — draws normally, cannot be moved on the picture or the timeline (enforced in
  `SetRegionRect` and `MoveRegion`, not in views)
- `isHidden` — left out of the preview **and** the export, so what you see is what exports;
  shown faded on the timeline and as a dashed outline on the picture
- `attachment` (`canvas` / `content`) — stored; only `canvas` is drawn today

Plus:

- Field-by-field decoding with defaults, so every older project opens unchanged, and one bad
  field loses one value, not the lane.
- `sanitise()` on every construction, decode and restyle: nothing non-finite or negative is
  stored.
- `AnnotationGeometry` (TimelineKit): pure resize (8 handles, rotation-aware, opposite side
  held, optional aspect lock), rotate (with 15° snapping), handle positions. Works in any
  square space; takes an aspect ratio for normalised coordinates.
- `AnnotationAnimation.pose(atOffset:of:)`: entrance none/fade/scale/pop/slide×4, exit
  none/fade/scale/slide×4, evaluated rather than simulated, so scrubbing and playing agree.
  The default is the quarter-second linear fade annotations always had.
- Renderer applies rotation, scale and slide about the annotation's centre; hidden ones are
  skipped in `SceneBuilder`, the one place preview and export both read.
- `Commands.ReorderAnnotation` (forward, backward, to front, to back). Forward and backward
  step past the next annotation that is on screen at the same time, not merely the next in
  the list.
- Copies keep rotation, opacity, animation, hidden and attachment, and arrive unlocked.
- Canvas: rotated outlines and hit-testing, 8 resize handles and a rotate handle, Shift to
  keep proportions or snap the angle, no handles on a locked annotation, right-click menu.
- Inspector: Content, Appearance (colour, opacity), Animation (in/out), Timing (typed start,
  duration, end), Advanced (rotation, X/Y/W/H, end lengths, easing); hide and lock toggles
  in the heading.
- Timeline chips show each annotation's kind, lock and hidden state, with the same
  right-click menu as the picture.

Tests: `AnnotationFoundationTests` (TimelineKit) and `AnnotationRenderTests` (RenderKit).

## Next phases

2. **Core kinds**: text styling (font, weight, background plate, outline, shadow), arrow
   styles with **endpoint handles** instead of a box, ellipse, highlight.
3. **Direct manipulation**: snapping and guides, keyboard nudge, multi-select on the picture,
   marquee selection.
4. **Styling**: fill/stroke/shadow, presets, recent colours.
5. **Animation**: typewriter, arrow draw-on, freehand draw-on.
6. **Tools**: spotlight, freehand pen, numbered steps, callouts.
7. **Advanced**: keyframes, groups, content attachment through zooms, templates.
