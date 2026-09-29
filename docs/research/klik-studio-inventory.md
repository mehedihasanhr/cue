<!-- Research gathered 2026-09-29 by a research agent; sources are listed at the end. -->

# Klik Studio: inventory of what is implemented

I've finished reading all the relevant code. Here's the inventory.

# Klik Studio: what's already implemented

**Scope.** Branch `feat/studio` at `4dd7c30`, 2026-09-29. I read the code statically and ran nothing, so the bug findings are from reading and haven't been reproduced. **Status labels:** Complete / Partial / Model-only (data exists, no UI) / Stub / Missing.

One more thing before the sections. An untracked, unfinished tool appeared while I was working: `/Users/stackrover/Workspaces/offices/stackrover/klik/Tools/studio-lab/` (`MouseScript.swift`, `FrameScan.swift`, `PointerAnalysis.swift`, all changed within minutes). Something else is building it right now. It is a harness that measures whether the pointer data lines up with the picture: pointer jumps, sweeps, a click then a fast move, a click while moving, and the same after a pause. Those are the same risks I list in §5.3.

---

## 1. Recording

Most of this lives under `/Users/stackrover/Workspaces/offices/stackrover/klik/Packages/RecordKit/Sources/RecordKit/`. The rest is the recorder UI in `/Users/stackrover/Workspaces/offices/stackrover/klik/KlikStudio/App/`.

**Capture sources**
- **Display — Complete.** `CaptureTarget.display`, `ShareableContentStore.filter(for:in:)` in `.../RecordKit/Discovery/CaptureTarget.swift`. The capture leaves out Klik's and Studio's own windows (`excludedBundleIDs`).
- **Window — Complete.** Uses `SCContentFilter(desktopIndependentWindow:)`.
  - Windows on other Spaces and full-screen apps are listed (`onScreenWindowsOnly: false`).
  - Windows that would record as black are flagged (`WindowSharing.refusing()`).
  - Pickers:
    - `TargetOverlay.swift`: a full-screen window picker with search and thumbnails from `WindowThumbnail` (`SCScreenshotManager`).
    - `RecorderModel.refreshSources()`: builds the list, filters out system windows, removes duplicates.
- **Area — Complete.** `/Users/stackrover/Workspaces/offices/stackrover/klik/KlikStudio/App/AreaSelection.swift` (`AreaSelectionController`) puts a drag overlay on each screen and passes the rect as `SCStreamConfiguration.sourceRect`.
- **Device (iPhone/iPad) — Stub.** Shown but disabled: `RecorderModel.Mode.device.isAvailable == false` (`RecorderModel.swift:68-70`, tooltip "isn't built yet" at `RecorderBar.swift:642`).

**Video**
- **Resolution — Complete, not user-selectable.** Native pixels: content points × `pointPixelScale`, rounded down to even, `scalesToFit = true` (`RecordingConfiguration.streamConfiguration(for:)`, `.../Session/RecordingConfiguration.swift:137-166`).
- **Frame rate — Complete.** Settings offer 30 or 60. `FramePacer` repeats the last frame when the screen is still (up to 2 s per gap) and pads the tail (`.../Timing/FramePacer.swift`).
- **Codec — Complete, with a likely bug.** Options are automatic / HEVC / H.264. `VideoCodec.resolved` claims to check for a hardware *encoder* but actually calls `VTIsHardwareDecodeSupported` (`RecordingConfiguration.swift:21-23`).
- **Quality — Complete.** Good / better / best = 0.08 / 0.13 / 0.2 bits per pixel × 60 / 8, clamped to 2–120 Mbps (`:34-42`). Keyframe at least every 2 s, BGRA input, sRGB, queue depth 8 (`.../Writing/SessionWriter.swift`).
- **Crash safety — Partial.** Telemetry is streamed as JSONL. The video writer isn't segmented or fragmented (no `SegmentPolicy`). My inference: an unfinished `screen.mov` after a crash is usually unplayable.

**Audio**
- **System audio — Complete.** The ScreenCaptureKit audio output goes to its own file, `media/system-audio.m4a` (`ScreenRecorder`, `AudioTrackWriter`).
- **Microphone — Complete.**
  - Supports several microphones at once. Each has its own `AVCaptureSession` and its own `media/microphone-N.m4a` (`.../Capture/MicrophoneRecorder.swift`, `RecordingSession.prepare`).
  - The device name and ID are saved in the manifest.
  - Silence is inserted at the start and for gaps (`AudioGapFiller`), so all tracks line up.
  - A file that never received audio is deleted.
- **Camera — Complete.**
  - Writes `media/webcam.mov`: same codec as the screen, frame rate capped at `min(fps, 30)`, size taken from the camera's current format (`.../Capture/WebcamRecorder.swift`, `RecordingSession.prepareWebcam`).
  - There is no live preview, by design.
  - If the camera can't be set up, the whole take fails. If only the camera file fails to finish, the screen recording is kept.

**Take flow**
- **Countdown — Complete.** 0/3/5/10 s, chosen in Settings or the bar menu. Esc cancels it (`RecorderBar.swift:~469`). All setup work happens during the countdown (`RecordingSession.start`).
- **Pause/resume — Complete for media, but pointer timing breaks after a pause.**
  - The writers remove the paused time from all later video and audio timestamps.
  - The telemetry clock doesn't (see §5.3).
  - Relevant code: `RecordingSession.pause/resume` (`:447-478`), `SessionWriter.setPaused` (`:216-230`).
- **Stop / discard / interruption — Complete.**
  - Stream errors are mapped: -3801/-3802 = permission denied, -3808/-3812 = target disappeared.
  - An interrupted take is finished and saved, then reported as a failure.
- **Disk space — Complete.** Checked before starting and every 5 s after that. Warns below 1 GB, stops below 250 MB (`DiskSpaceMonitor`, `RecordingSession.watchDisk`).

**Pointer and input data (telemetry)**
- **Pointer position — Complete.** Sampled at 120 Hz, with the pointer shape polled at 20 Hz (`.../Telemetry/CursorTracker.swift`).
- **Pointer image — Complete.** The real pointer image is saved once per shape as a PNG with its hotspot (`CursorArtworkWriter`).
- **Clicks and scrolls — Complete.** Left, right and other buttons, down and up, plus scroll deltas.
- **Keystroke timing — Implemented but never switched on.** It records only the time and modifier keys, never the key itself. The app never sets `capturesKeystrokes` (no match anywhere in `KlikStudio/`, `Klik/` or AddOnKit).
- **Focus — Partial.**
  - App activation and front-window moves are recorded (window polled at 2 Hz).
  - Text-field focus depends on `tracksFields: configuration.capturesKeystrokes` (`RecordingSession.swift:435`), so it is also never recorded. The Settings footer says it will be (`StudioSettingsView.swift:115-122`).
- **Window-bounds track — Missing.** `Telemetry.windowBounds` and `WindowBoundsSample` exist but nothing writes them.
- **Burn the pointer into the video — Complete.** A setting (`capturesCursorInVideo`).

**What a `.klikrec` package contains**

`RecordingPackage` and `RecordingManifest` are in `.../Project/RecordingPackage.swift`.

- `manifest.json`: format version 1, pretty-printed, ISO-8601 dates. Holds name, creation date, duration, `displayScale`, `sourceRect`, the track list (kind, path, pixel size, frame rate, codec, name, device ID) and the telemetry paths.
- `project.json`: the edit (the `Timeline` value). Only written when you save in the editor.
- `media/`:
  - `screen.mov`: video only.
  - `system-audio.m4a`, `microphone-N.m4a`: AAC, 48 kHz, stereo, 192 kbps.
  - `webcam.mov`.
- `telemetry/`:
  - `cursor.jsonl`: one `{t, x, y, shape}` per line.
  - `input.jsonl`: `mouseDown/mouseUp {t, button, x, y}`, `scroll {t, dx, dy}`, `key {t, modifiers}`, using Swift's default enum encoding.
  - `focus.jsonl`: `{t, kind, x, y, width, height, app}`.
  - `cursors/<shape>.png` and `cursors.json`: pointer images with normalised hotspot and size.
- `derived/`: waveform caches (`peaks.bin`, `peaks-<hash>.bin`) and the library thumbnail `poster.jpg`. Safe to delete.
- `Backgrounds/`: imported background images.
- `Audio/`: imported sounds and voiceovers.
- Older recordings with audio inside `screen.mov` still open.

**Permissions**
- **Screen Recording:** detected from the error codes, and the UI offers "Open Settings".
- **Microphone:**
  - Asked for only when a request needs it (`StudioService.start`, `:121-127`).
  - If refused, the take silently records without a microphone.
  - The `.microphoneDenied` error is only raised by the voiceover recorder.
- **Camera:** asked when you switch it on (`RecorderModel.setCamera`) and again during setup.
- **Accessibility:** only checked (`AXIsProcessTrusted`), never requested.
- **Speech recognition:** only used by the older caption engine.
- **Entitlements:** `/Users/stackrover/Workspaces/offices/stackrover/klik/Config/KlikStudio.entitlements` has sandbox, audio input, camera, user-selected files, movies folder and network client. There is no App Group entitlement.

**Recorder UI.** `RecorderBar.swift` / `RecorderBarPanel.swift` is a floating panel.
- **Before a take:** close, the Display/Window/Area/Device modes, camera chip, microphone chip (several can be picked), and a menu with Recordings…, Settings… and countdown.
- **While starting:** countdown with cancel.
- **During a take:** timer, pause/resume, stop, discard, a camera-on indicator and the low-disk warning.
- **On failure:** the message, plus "Open Settings" when it's a permission problem.
- New recordings are named `Recording yyyy-MM-dd at HH.mm.ss` and saved by default to `~/Movies/Klik Studio`.

## 2. Editor UI structure

**Windows**
- Recorder bar.
- Target overlay and area overlay.
- Recordings library (⌘L).
- **Editor — one window only.** Opening another recording replaces it, with a save prompt (`EditorWindows.swift`). Size 1280×860, minimum 960×680.
- Settings (4 tabs).
- Export sheet.

**Editor layout** (`EditorView.swift`)
- **Toolbar** (`EditorToolbar`): file name, Show in Finder, Undo, Redo, Save/Saved, export progress pill, Export.
- **Tool rail** (`ToolRail`): 8 tools in 4 groups — Frame | Crop, Blur | Annotate, Pointer | Webcam, Captions | Audio.
- **Inspector** (`InspectorPanel`): resizable from 260 to 460 pt, width remembered.
- **Preview** (`PreviewPane`) with its overlays.
- **Transport bar**: previous frame, play, next frame, split, a zoom menu, preview volume, timeline zoom slider and "fit".
- **Timeline strip** (`TimelineStrip`).

**What the inspector shows**
- **Frame tool:**
  - With nothing selected: Background, Shape, and crop numbers.
  - With something selected: that item's inspector.
- **Blur / Annotate tools:** a hint, or the selected item.
- **Crop, Pointer, Webcam, Captions, Audio:** that tool's panel.
- **Selection inspectors exist for:** clip, zoom, blur, annotation, pointer stretch, recorded sound or one sound source, a detached sound run, an added sound, and a range.

**Preview overlays**
- `CropOverlay`.
- `RegionCanvas`: blurs and annotations.
- `WebcamBubbleOverlay`.
- `ZoomFramingOverlay` with `ZoomPreviewSwitch` (Framing / Result).

**Timeline lanes** (`TimelineStrip.Lane`, `:63-163`)
- Video.
- Audio: the recorded sound as one lane (attached or detached), or one lane per source.
- Zoom: always shown.
- Pointer, Sound (added audio), Blur, Notes (annotations): shown only when they have content.
- **There is no captions lane and no webcam lane.**
- The clip lane has no thumbnails, only tick marks.

**Keyboard shortcuts and menu commands**

Most are in `EditorCommands.swift`; the others are in `StudioApp.swift`, `EditorToolbar.swift` and `ToolRail`.

| Shortcut | Command |
|---|---|
| ⌘E | Export… |
| ⌘Z / ⇧⌘Z | Undo / Redo (menu shows the step's name) |
| ⌘S | Save |
| ⌘X / ⌘C / ⌘V / ⌘D | Cut Selection / Copy Selection / Paste at Playhead / Duplicate |
| ⌫ (Delete) | Delete |
| ⌘A | Select All (selects the whole timeline as a range) |
| ⌘B | Split at Playhead |
| ⌥⌘B | Split Zoom at Playhead |
| ⌘K | Add Zoom at Playhead |
| ⇧⌘E | Turn Zoom On/Off |
| ⇧⌘R | Preview Zoom Result |
| ⇧⌘A | Add Sound… |
| ⇧⌘V | Record / Stop Voiceover |
| Space | Play / Pause |
| ← / → | Previous / next frame (fixed 1/30 s steps) |
| ⇧← / ⇧→ | Back / forward one second |
| ⌥← / ⌥→ | Previous / next cut |
| Home / End | Go to start / end |
| ⌘= / ⌘- / ⌘0 | Zoom timeline in / out / fit |
| ⌘1–⌘8 | Choose a tool |
| ⇧⌘0 | Show the recorder bar |
| ⌘L | Recordings |

- **Menu items with no shortcut:** Auto-Zoom from Clicks and Focus, Merge Zoom with Next, Lock/Unlock Zoom, Frame Zoom on the Picture, Reset Zoom, Hide Pointer over Selection, Mute/Unmute the Recording, Detach/Re-attach Audio.
- **Other keys:**
  - Zoom framing: arrow keys nudge (⇧ for bigger steps), + and - resize.
  - Esc leaves the crop, canvas and webcam tools, and exits framing.
  - Target overlay: ↩ records, Esc cancels. The area picker also takes Esc.
- **Mouse:**
  - ⌘-click adds to the selection. Dragging with several items selected moves them as one undo step.
  - Holding ⌃ while dragging turns snapping off.
  - Holding ⌥ while trimming a clip lets it overlap the neighbouring clip's footage.
  - Pinch or ⌘-scroll zooms the timeline; plain scroll pans it.
  - Drag on the ruler or the playhead to scrub.
  - ⇧ keeps an annotation's shape while resizing and snaps rotation to 15°.
- **Right-click menus exist on:** clips, region chips, sound lanes, sound runs, annotations and blurs on the picture, and library rows.

## 3. Timeline model and editing

The model is in `/Users/stackrover/Workspaces/offices/stackrover/klik/Packages/TimelineKit/Sources/TimelineKit/`.

**Model — Complete** (`Model/Timeline.swift`, `Model/Regions.swift`, `Model/Style.swift`, `Model/SoundTrack.swift`)
- **The whole edit is one value:** clips, zooms, blurs, annotations, captions, added sounds, the detached sound (if any), pointer stretches, frame style, pointer style, camera style, master sound, per-source sound, webcam bubble and caption style.
- **Clips:**
  - A clip stores where it starts in the recording, how long it is there, and its speed (0.25–8×).
  - Its place on the timeline is always computed from the clips before it, so the video never has gaps.
- **File reading is forgiving:** each field decodes on its own, so one bad field doesn't break the project.

**Commands and where the UI exposes them** (`Editing/Commands.swift`, `Editing/ClipSequence.swift`)
- **Cutting footage**
  - Split: ⌘B.
  - Delete a range, with everything after it closing the gap: deleting a clip, cutting footage, or ⌘A then Delete.
  - Insert footage (paste or duplicate): ⌘V / ⌘D. Everything after it moves along; audio, pointer stretches and so on travel with the footage.
- **Clips**
  - Trim: drag a clip's edge; ±1-frame buttons in the inspector; "put back" bubbles for trimmed-off footage at either end.
  - Speed: per-clip menu of presets, and "Set Speed" on a ⌘A range. Changing speed moves or rescales the zooms, blurs and so on after it.
  - **Reordering clips (`MoveClip`) — Model-only, no UI.**
- **Regions (zooms, blurs, annotations, pointer stretches, sounds)**
  - Add: zoom, blur, annotation, sound, pointer stretch.
  - Move and resize one or many at once (`MoveRegion` / `MoveMany`).
  - Delete.
  - Cut, copy, paste and duplicate through the system clipboard (`RegionPasteboard`, `CopiedRegion`, `CopiedFootage`).
  - Lock a zoom or an annotation.
  - Change stacking order of annotations.
- **Sound:** detach and re-attach the recorded sound (with a warning if re-attaching loses edits), move and trim detached runs, mute, level, solo, unmute all, rename a source.
- **Crop and styles:** `SetCrop` and a general `Restyle` command.
- **Zoom-specific:** `SplitZoom`, `MergeZooms`, `SuggestZooms`, `RestyleZoom`.
- **Missing:**
  - Ripple delete of a region's time range.
  - Freeze frames, a speed ramp inside one clip, and "remove silences".
  - Any captions lane, so captions can't be moved or retimed.
  - A way to select a range other than ⌘A (the `.headTrim`, `.tailTrim` and `.caption` selections are never produced by the UI).

**Undo, saving and snapping**
- **Undo — Complete.** Undo stores whole snapshots of the edit, up to 200 steps. A drag counts as one step.
- **Saving — Complete.** ⌘S writes atomically, and you're asked about unsaved edits on close. There is no autosave.
- **Snapping — Complete.** 8 pt tolerance, capped at 0.5 s, to every cut and region edge (`Editing/Snapping.swift`).

**Problems I found**
- **Lanes can end up out of order.** `MoveRegion` / `MoveMany` don't re-sort zooms, pointer stretches or captions (`Commands.swift:718-761`). Other code assumes they're sorted, e.g. "Merge with Next" uses array order (`EditorModel.swift:1156-1161`).
- **Trimming the start of an added sound slides it instead of trimming it.** A head drag on an `AudioRegion` (imported sound or voiceover) goes through `MoveRegion`, which never moves `sourceStart`. Only detached sound runs get the proper trim (`TimelineDrag.swift:137-142`).
- **Copying footage loses annotation settings.** `CopiedFootage.freshened()` rebuilds annotations from only 6 fields, dropping rotation, opacity, animation, hidden and attachment (`CopiedFootage.swift:278-281`). This contradicts `docs/annotations.md` Phase 1.
- **Copied zooms turn back on.** Both copy paths drop `isEnabled` and `isEdited`, so a switched-off zoom comes back on when duplicated or pasted.

## 4. Zoom and camera moves

**A zoom region — Complete** (`ZoomRegion`, `Regions.swift:60-297`)
- Scale 1–8×.
- Centre, stored relative to the picture.
- Easing: linear, spring or ease-in-out.
- Ramp in/out time, which can differ at each end after a split.
- Follow pointer, source (why it exists), lock, on/off, and "framed by hand".
- The motion is calculated from the time, not simulated, so scrubbing and playing give the same frame.

**Manual zooms — Complete**
- ⌘K adds one: 1.5–4 s long, 2×, centred.
- **Inspector:**
  - On/off, Scale, Duration, Smoothness (ramp), Follow, Frame on Picture, Reset Framing.
  - Advanced: easing, start nudges, Start Here / End Here, where it came from, lock, split, merge, reset.
  - Camera motion for the whole project: steadiness, follow strength, stray (safe area), and "zoom the whole picture" (`ZoomInspector.swift`, `CameraControls.swift`).

**Framing overlay — Complete** (`ZoomFramingOverlay.swift`, `Editing/ZoomFraming.swift`)
- A rectangle on the preview with 8 handles, a move gesture and keyboard nudges.
- The outside is dimmed and the scale is shown on the box.
- A Framing / Result switch; while framing, the preview is drawn with zooms removed.

**Auto-zoom — Partial** (`Analysis/ZoomSuggester.swift`, `EditorModel.suggestZooms`)
- **Clicks:**
  - Groups clicks by time (2.5 s) and distance (900 pt).
  - Starts 0.7 s before, holds 1.2 s after, lasts 1.5–12 s.
  - Scale from Settings (default 1.8), kept away from the picture's edges.
  - Ignores clicks outside the recorded area.
- **Focus:**
  - Text-field and typing zooms exist in code, but their data is never recorded (§1).
  - Window and app zooms are opt-in and off by default.
- **In practice, auto-zoom is click-only.**
- **Re-running:**
  - A re-run replaces only the previous run's suggestions.
  - Hand-placed, locked, switched-off and hand-framed zooms are kept.
  - It runs when a project opens if Settings allow and there are no zooms yet.
- **Bug: it ignores crop.** Suggested centres are relative to the uncropped recording, but the renderer reads them relative to the cropped picture (`ZoomSuggester.swift:192-193` vs `SceneBuilder.swift:156`).

**Camera behaviour — Complete** (`SceneBuilder.camera`)
- The strongest active zoom wins; zooms don't multiply.
- Following is a "dead zone": the camera only moves when the pointer would leave the shot, judged on an averaged pointer position.
- A visible pointer is always kept in shot.
- Hidden pointer stretches fade out the camera's interest in the pointer.
- "Zoom the whole picture" is on by default; off, only the contents zoom inside the padded frame.

**Missing:** keyframed camera paths, zooming out below 1×, rotate or 3D moves, motion blur on camera moves, and zooms triggered by scrolling.

## 5. Pointer rendering

### 5.1 Features
- **Pointer basics**
  - Show/hide — Complete.
  - Size 0.5–3×, where 1× is 3.5% of the shorter side of the output — Complete.
  - Smoothing 0–1 — Complete.
  - Keep size while zoomed — Complete.
  - Motion blur — Complete, but see finding 5.
- **What it looks like**
  - The recording's own pointer image vs. Klik's drawing — Complete.
  - Klik's drawing: arrow, I-beam, crosshair and the resize arrows. The hand shapes are drawn as an arrow (`CursorArtwork.swift:82-92`).
- **Clicks**
  - The pointer "swells" on a click — Complete (`clickScale`).
  - A ring at the clicked spot with size and colour settings; right-clicks get a second inner ring — Complete (`clickLayers`, `SceneRenderer.clickImage`).
- **Pointer stretches (per time range)**
  - Hide, hold still, or calm, each with a ramp (`CursorRegion`, `CursorRegionInspector.swift`).
  - Menu command "Hide Pointer over Selection".
- **Missing:** pointer themes, a highlight halo or spotlight, auto-hide when idle, loop smoothing, sway, click sounds.

### 5.2 How a pointer position gets from the mouse to the output frame

**At recording time (RecordKit)**
1. **The clock.** `RecordingClock` uses the host clock. `SessionWriter.append(video:)` calls `clock.start()` when the first complete screen frame is added. That stamps the *time the frame is processed*. The video file itself starts at the *frame's own timestamp* (`startSession(atSourceTime: time)`) (`SessionWriter.swift:161-167`). Camera and audio files start at the clock's start (`.sharedClock`; `AudioTrackWriter.swift:88-103`).
2. **Position samples.** A 120 Hz timer on the capture queue (2 ms leeway) runs `CursorTracker.sample()` (`:266-273`). Each sample:
   - reads `CGEvent(source:nil).location` (global points, y pointing down),
   - maps it with `CursorMapper.map`,
   - stamps `t = clock.elapsed()`,
   - adds the most recently polled shape.
3. **Converting to the recording's own coordinates.** `(p − origin) × scale + offset` (`CursorTracker.swift:65-69`). The origin depends on the target (`CaptureTarget.swift:29-39, 124-132`):
   - **Display:** `CGDisplayBounds(id).origin`.
   - **Area:** display origin + the area's offset.
   - **Window:** `SCWindow.frame.origin`. Until the first frame arrives, it's refreshed at 20 Hz from the window server. After that, every frame's `SCStreamFrameInfo` (screen rect, content rect, content scale, scale factor) sets scale and offset (`ScreenRecorder.swift:84-86`, `CursorMapper.placement` `:135-155`).
   - The result is in points inside the recording, where 1 point = `displayScale` pixels in the file.
4. **Shape.** A 20 Hz main-thread timer reads `NSCursor.currentSystem`, recognises it (by identity or by a small image fingerprint) and saves the pointer image the first time each shape appears.
5. **Clicks.** A global `NSEvent` monitor fires on the main thread. `record(_:)` stamps `clock.elapsed()` *at that moment* and *re-reads* the current pointer location, rather than using the event's own time and position. It writes `InputSample.mouseDown(t, button, x, y)` (`CursorTracker.swift:345-367`).
6. **Storage.** JSONL (`JSONLWriter`). The manifest stores `displayScale` and the screen's pixel size.

**In the editor and export (TimelineKit, RenderKit)**

7. **Loading.** `EditorDocument.cursorTrack` reads both JSONL files once and builds a `CursorTrack`: samples sorted by `t`, clicks = mouse-downs, button 1 = right-click (`EditorDocument.swift:249-260`, `CursorTrack.swift:38-44`).
8. **Smoothing.** `CursorTrack.smoothed(amount)` runs an exponential filter forward then backward, one step per sample (α = 1 − amount^0.35 × 0.92). It then pulls the path back to the raw samples within ±0.14 s of each click (`:89-141`). The preview caches this; the exporters redo it with the same function.
9. **Time mapping.** `sourceTime = timeline.sourceTime(at: T)`, which accounts for clip cuts and speed. The pointer is looked up at `sourceTime.seconds`. **This assumes telemetry `t` equals time in the video file.**
10. **Position.** `CursorTrack.position(at:)` interpolates linearly between samples (`:53-71`). `pointerPoint` then applies pointer-stretch effects (`SceneBuilder.swift:446-478`).
11. **Normalising.** `normalised(point, crop)` (`SceneBuilder.swift:304-310`):
    - pixels = point × `displayScale`;
    - u = (px / videoWidth − crop.minX) / crop.width, and the same for v;
    - if the point is outside the crop, the pointer isn't drawn.
    - `videoSize` is the real size of the video file.
12. **Click rings** use the *recorded click position*, not the smoothed pointer (`:491-506`), shown for 0.45 s.
13. **Rendering.** `SceneRenderer.cursorImage` (`:420-468`):
    - `video = transformedVideoFrame` (`SceneDescriptor.swift:127-133`);
    - point = (minX + u·width, maxY − v·height);
    - recorded pointer images are placed by their hotspot; drawn pointers are placed by their top-left corner;
    - the result is clipped to the visible video area.
14. **Which video frame is shown.** The preview uses the same builder and renderer, with frames from `FrameSource` (`AVAssetImageGenerator`, cached in 20 ms buckets; `FrameSource.swift:89`). Export uses `ExportFrameReader`, which reads forward and returns the frame whose timestamp ≤ t < next (`ExportFrameReader.swift:70-79`).

### 5.3 Where the drawn pointer or click can end up in the wrong place

1. **After a pause (high confidence).**
   - `RecordingClock.elapsed()` doesn't subtract paused time. The video and audio writers do.
   - So every pointer sample, click and focus event after a pause is stamped too late by the total pause length. The editor then shows the pointer from that many seconds earlier than the picture.
   - Code: `RecordingClock.swift:29-32`, `CursorTracker.swift:269,348`, `FocusTracker.swift:112` vs `SessionWriter.swift:213-237`.
   - No test covers this, and the manifest doesn't record when pauses happened.
2. **Clock starts at the wrong moment (medium; size unknown).**
   - Pointer time zero is when the first frame is *processed*; video time zero is the frame's *capture timestamp*.
   - Result: a fixed offset equal to how long that first frame took to arrive. The pointer is drawn as it was that much *later* than the frame shows.
   - Camera and audio files start at the processing time too, so they're offset from the screen by the same amount.
   - A likely fix is `clock.start(at: time)`.
3. **Clicks are read late (medium).** The click's time and position are captured when the main thread gets to the event, not from the event itself. The ring, the swell and the smoothing anchor can land late, at wherever the pointer has moved to (fast click-and-move, drags) (`CursorTracker.swift:345-367`).
4. **Drawn pointer anchored at the wrong point (certain for affected shapes).**
   - Every drawn shape is placed by its top-left corner (`SceneRenderer.swift:459-464`), but the I-beam, crosshair and resize shapes are drawn centred (`CursorArtwork.swift:94-125`). They end up about 0.5 × size right and 0.7 × size down.
   - Even the arrow's tip sits at (6%, 4%) inside its image.
   - This only happens when the recorded pointer image isn't used. Commit `121a98c` fixed hotspot placement for recorded images only.
5. **Motion blur moves the pointer (certain when motion blur is on and the pointer moves faster than 600 pt/s).**
   - `motionBlurred` makes the image `r` pixels bigger on every side, and the placement code doesn't allow for that.
   - Recorded pointer images shift up and right by `r`; drawn pointers shift down by `2r`; `r` can be up to 0.4 × pointer size.
   - Code: `SceneRenderer.swift:443-453, 460-464, 549-562`.
6. **Preview only: frame cache (low).** The 20 ms cache buckets can serve a neighbouring frame (up to 1 frame away at 60 fps) for the time the pointer was computed at. Export isn't affected.
7. **Wrong shape, right position.** A shape with no saved image falls back to the saved *arrow* image. All unrecognised custom pointers share the first "other" image captured (`TimelineKit/Analysis/CursorArtwork.swift:46-48`).

## 6. Camera bubble

Files: `WebcamInspector.swift`, `WebcamBubbleOverlay.swift`, `SceneBuilder.webcamLayer`, `SceneRenderer.webcamImage`.

- **Complete:**
  - Show/hide. It's switched on automatically when a take that recorded a camera is first opened.
  - Position: 4 corners, or anywhere by dragging on the preview.
  - Size 0.08–0.5 of the shorter side.
  - Roundness from square to circle.
  - Shadow, mirror, "grow while zoomed".
  - The camera image fills the square and is cropped to the middle.
  - Drawn above the video and below annotations and captions.
  - Included in preview, MP4/MOV and GIF.
  - Uses the same timeline as the screen, so cuts and speed changes apply to it too.
- **Missing:**
  - Shapes other than rounded square/circle, and border rings.
  - Changing layout over time (camera-only or full-screen camera scenes).
  - Choosing which part of the camera image to show.
  - Face tracking and background removal.
  - Hiding the bubble for a stretch of time.

## 7. Audio

- **Per-source sound — Complete.**
  - One lane per source (system audio, each microphone), with level 0–2, mute, solo, rename, and "unmute all".
  - A master mute and level on top (`SoundTrack`, `AudioInspector`, `TimelineSoundRow`).
- **Detaching the recorded sound — Complete.** Detach and re-attach (with a warning if edits would be lost), then move and trim detached runs; overlapping runs are mixed (`ClipSequence.detachSound`, `AudioMixdown.appendDetached`).
- **Added sounds — Complete, with the head-trim bug from §3.** Import a file (copied into `Audio/`), trimmed to fit the video; level 0–2.
- **Voiceover — Complete.**
  - Records against the edit starting at the playhead, with a count-in; the preview is silenced while recording.
  - Retakes are added as new regions (`VoiceoverRecorder.swift`, `Timeline.voiceoverPlacement`).
- **Waveforms — Complete.** Several zoom levels, cached in `derived/` (`WaveformBuilder`, `WaveformPeaks`, `WaveformStore`, `RegionWaveformStore`).
- **Preview audio — Complete.** Plays the same mix the export writes, and the sound drives the playhead. Preview volume and mute are local preferences, not saved in the project (`PreviewAudio.swift`).
- **Missing:** fades, ducking, noise reduction or EQ, loudness normalisation, level meters while recording, and "remove silences".

## 8. Captions

- **Speech recognition — Complete.**
  - Uses `SpeechAnalyzer` on macOS 26 with word timings and on-demand model download; otherwise `SFSpeechRecognizer`.
  - Runs on the Mac only (`KlikStudio/Editor/Captions/*.swift`).
  - Uses the Mac's current language only; there's no language picker.
  - Transcribes the microphone file when there is one.
- **Line shaping — Complete.** Breaks lines at pauses, sentence ends and word/length limits, then maps them onto the edit, dropping lines from cut footage (`Analysis/CaptionShaping.swift`).
- **Styling — Complete, limited.** One style for all captions: on/off, top or bottom, size, backdrop opacity, margin, colour. The font is fixed to the system semibold; the text fades at each end (`CaptionStyle`, `CaptionArtwork.swift`).
- **Editing — Partial.** You can edit each line's text in the inspector (clicking its timestamp jumps there), regenerate, or clear. You can't change timing, split or merge lines, or see captions on the timeline.
- **Missing:** SRT/VTT export (no match in the code), word-by-word highlighting, speaker labels, translation.

## 9. Annotations (and blur regions)

- **Kinds:**
  - Text, arrow and box — Complete.
  - `image(path:)` — Model-only: the renderer can draw it (`NSImage(contentsOfFile:)`), but nothing in the UI creates one.
- **Placement and shape — Complete.**
  - Rect stored relative to the finished frame; rotation; 8 resize handles and a rotate handle.
  - ⇧ keeps the shape; rotation snaps to 15°.
  - At least 5% must stay in the frame.
  - Lock and hide; stacking order (4 commands); right-click menu on both the picture and the timeline chip (`AnnotationGeometry.swift`, `RegionCanvas.swift`, `AnnotationMenu.swift`).
- **Look — Partial.**
  - Colour with opacity, overall opacity, text size.
  - Font, stroke width and arrowhead are fixed.
  - The arrow always runs corner to corner of its box; there are no endpoint handles.
- **Animation — Complete.**
  - In: none, fade, scale, pop, slide ×4. Out: none, fade, scale, slide ×4.
  - In/out lengths 0–2 s in the UI (5 s max in the model); linear, spring or ease-in-out (`AnnotationAnimation.swift`).
- **Inspector — Complete.** Content, appearance, in/out, typed start/duration/end, and Advanced (rotation, X/Y/W/H in %, lengths, easing). You can type directly on the picture.
- **Not drawn yet — Model-only:** "stick to content" attachment (`Regions.swift:349-360`: "Only `canvas` is drawn today").
- **Blur regions — Complete, but wrong with a crop.**
  - Gaussian or pixelate, strength 4–80, drawn on the picture with corner handles.
  - The picture canvas maps them against the *cropped* picture (`RegionCanvas.swift:495-499`), but the renderer applies them to the *uncropped* recording (`SceneRenderer.swift:246-252`; `CropTests.swift:218-233` confirms the renderer's side). So blurs drawn while a crop is active land in the wrong place.
- **Not started:** everything in phases 2–7 of `docs/annotations.md` (see §16).

## 10. Backgrounds and frame styling

- **Background — Complete.**
  - **Wallpaper tab:** 20 generated gradients, the Mac's own desktop pictures, and your recent images (`WallpaperGrid.swift`, `BackgroundKit/WallpaperCatalog.swift`, `GradientPreset.swift`, `WallpaperID`).
  - **Gradient tab:** 5 presets, and two of them (Paper, Black) are really solid colours. You can't edit gradient colours or angle.
  - **Color tab:** 18 swatches plus a custom colour picker.
  - **Image tab:** choose, replace or remove. The image is copied into the project, capped at 3840 px (`BackgroundImport`).
  - Background blur.
- **Frame — Complete.**
  - Padding 0–20%, corner radius 0–8%, shadow strength, shadow softness.
  - Aspect: Source, 16:9, 1:1, 9:16, 4:3.
  - Crop with 8 handles; the inspector shows the kept and exported sizes.
- **Missing:** device or window-chrome mockups, borders or insets, saved style presets (`.klikpreset`).

## 11. Export

- **Formats — Complete.** MP4 and MOV (`AVAssetWriter`), and GIF (ImageIO) (`RenderKit/Export/VideoExporter.swift`, `GIFExporter.swift`).
  - Codec: automatic (H.264 in MP4, HEVC in MOV), H.264 or HEVC.
  - The MOV description says "ProRes-friendly" but there's no ProRes option (`ExportSettings.swift:33-35`).
  - No alpha channel and no WebM.
- **Options — Complete.**
  - Size: Project, 4K (3840), 1440p (2560), 1080p (1920), 720p (1280). Never scales up; always even dimensions.
  - Frame rate 15/24/30/60; GIFs capped at 30 fps and 1280 px.
  - Quality: good / better / best bitrate.
  - Include sound; GIF loops forever by default.
  - Aspect ratio comes from the frame style, not the export.
- **Presets — Complete.** Send (1080p60 with sound), Review (1080p30 silent), Chat (720p30, lower quality), GIF (640 px, 15 fps) (`ExportPreset.swift`).
- **Size estimate — Complete** (`ExportEstimate`).
- **Progress, cancel and queue — Complete.**
  - Exports run one at a time in a queue that keeps going after the editor window closes, with a toolbar progress pill.
  - Cancelling deletes the partial file; quitting mid-export asks first.
  - When done: Show in Finder, Copy File, Open, and the system Share sheet.
  - The queue is `ExportJobs` in `/Users/stackrover/Workspaces/offices/stackrover/klik/KlikStudio/Editor/Export/ExportJobs.swift`. It's owned by `EditorWindows.exports` (`EditorWindows.swift:43`), and quitting is guarded in `StudioApp.swift:159-178`.
- **Preview and export match** because they use one renderer. Export-only work: frames are read in order, audio is built with `AudioMixdown`, and the result is scaled to the export size.
- **Export settings are remembered** in UserDefaults (`ExportModel`), including the last folder.
- **Missing:** caption sidecar files, uploading or share links, Display P3.

## 12. Library

Files: `RecorderWindow.swift`, `LibraryCatalog.swift`, `RecordingPoster.swift`, `RecordKit/Project/RecordingLibrary.swift`.

- **Complete:**
  - A list of recordings with a thumbnail (cached `derived/poster.jpg`), name, date, length, size on disk, and an icon if it has audio.
  - Search by name.
  - Sort by date, name or length, in either direction.
  - Open, Rename… (folder and manifest both), Duplicate ("Name N"), Show in Finder, Move to Trash (with confirmation).
  - Destructive actions only work on `.klikrec` packages directly inside the library folder.
  - Links to open the library folder and bring up the recorder bar.
- **Missing:** folders or tags, batch actions, importing other videos.

## 13. Settings

**Studio Settings window** (`StudioSettingsView.swift`, `StudioSettings.swift`)
- **Recording:** countdown (off/3/5/10), frame rate (30/60), quality, encoder, record system audio, record microphone plus one toggle per microphone, record clicks and scrolls, record what has focus, burn the pointer into the video.
- **Afterwards:**
  - Open in editor, suggest zooms.
  - How far a click zooms (1.2–3).
  - Zoom to text fields (currently has no effect — see §1).
  - Zoom when a window comes forward.
  - Voiceover count-in.
  - Recordings folder: choose or reset.
- **Appearance (for new projects):** background preset, padding, corners, shadow, softness, background blur, pointer size, pointer smoothing, click effect.
- **About:** version, contract version, connection status with Klik.

**Other places settings live**
- **Recorder bar:** camera on/off and device, microphone(s), countdown.
- **Remembered locally:** inspector width, preview volume and mute, export settings.
- **Not exposed anywhere:** keystroke capture, pointer sample rate, saving the real pointer image, camera frame rate.

**Host side (Klik › Settings › Add-ons)** (`Klik/AddOns/StudioPreferences.swift`): countdown (0–10), system audio, microphone, open editor when done, recordings folder, and a local Studio build to use.

## 14. Host integration

- **How Klik launches Studio — Partial.**
  1. Klik writes a `RecordingRequest` JSON file into `AddOnDownloads.folder/requests/`.
  2. It opens `klik-studio://record?request=<path>` (`Klik/AddOns/RecordingAddOnClient.swift:61-95`, `AddOnKit/RequestFile.swift`).
  3. Studio reads the file, starts the take and deletes the file (`StudioService.acceptRequest/start`).
- **What the request can do:** it can only switch things off (system audio, microphone, camera), never on. The host never sets `webcam`.
- **Klik's island picker** (`Klik/Island/RecordDetail.swift`) offers Display and Window only — no Area.
- **`.klikrec` files** can be double-clicked to open in Studio.
- **Getting results back — Stub.**
  - `beginRecording` returns `.finished` straight away (`StudioService.swift:80-83`).
  - `RecordingResult` is only kept in-process (`lastResult`) and never sent back.
  - The advertised XPC/Mach service doesn't exist (no `NSXPC*` or `SMAppService` anywhere), and there's no App Group entitlement.
- **Capabilities are out of date:** Studio still reports `canExportGIF: false, canCaption: false` (`:61-78`).
- **Add-on catalog:** `AddOnCatalog.feedURL = nil`, so there is no update feed.

## 15. Tests

Counts are approximate (`grep -c @Test`). There are no tests for the KlikStudio app target itself (editor model, canvas mapping, overlays, recorder UI).

- **AddOnKit (9):** request encoding and launch URL round-trip, capabilities, contract matching.
- **BackgroundKit (13):** wallpaper IDs, gradient presets, bookmarks and recents.
- **RecordKit (≈99):**
  - `CursorMappingTests`: display, area, window and shrunk-window origins; placement from frames.
  - `CursorRecognitionTests`: pointer shape recognition.
  - `LibraryTests`: list, sort, rename, duplicate, trash, safety checks.
  - `PackageTests`: manifest, JSONL, keystrokes never storing text.
  - `SessionStateTests`: pause/stop state logic.
  - `SilenceBufferTests`.
  - `TimingTests`: frame pacer, gap filler, disk thresholds, clock. **No test covers pause vs. pointer timing.**
  - `WebcamTrackTests`.
- **TimelineKit (≈445):** timeline, clip editing, reflow, ripple and footage clipboard, detached sound, sound sources, audio signature, copied regions, move-many, drag geometry, snapping and canvas mapping, annotation foundation and placement, zoom framing, evaluator, customisation, offscreen, suggester coverage, analysis, caption shaping, voiceover, waveform, pointer smoothing, webcam settings, document and undo.
- **RenderKit (≈213):**
  - Scene building; camera follow; zoom scope and framing agreement; crop.
  - Click marks and recorded pointer images. **No tests for motion-blur placement or drawn-shape anchoring.**
  - Webcam, backgrounds, annotation rendering.
  - Audio mixdown and per-source mixdown.
  - Export: sizes, presets, estimates, cancel, an end-to-end file.
  - Preview/export fidelity.
  - Benchmarks.
- **Host (`/Users/stackrover/Workspaces/offices/stackrover/klik/KlikTests/AddOnTests.swift`, ≈22 XCTest):** versions, update feed, availability, signature, downloads, request building.

## 16. Gaps and TODOs

The codebase uses almost no `TODO`/`FIXME` tags, so most of this comes from prose comments and reading the code.

**Marked in the code**
- `RecorderModel.swift:68` and `RecorderBar.swift:642,667`: device capture "not built yet".
- `StudioService.swift:19` and `AddOnKit/StudioBridge.swift:15-21`: the Mach service is "once the helper exists".
- `RecordingAddOnClient.swift:84-88`: the App Group folder is "the moment the add-on target exists".
- `Regions.swift:351`: only canvas attachment is drawn.
- `AddOnCatalog.swift:78`: `feedURL = nil`.
- The README roadmap (line 482) still says "export next", which is out of date.

**Built but not connected, or inconsistent**
- Keystroke and text-field focus capture are never enabled, while the Settings text says field zooms work.
- The window-bounds track is never written.
- Clip reordering (`MoveClip`) has no UI.
- Image annotations can't be created.
- The captions, head-trim and tail-trim selections are unused; there's no captions lane.
- Frame stepping is fixed at 1/30 s, although recordings default to 60 fps.
- The "encoder" check actually tests for a decoder.
- Studio reports GIF and captions as unsupported even though both work.
- Results are never sent back to Klik.
- Plus the bugs listed in §3, §4, §5.3 and §9.

**Planned in `docs/` but not implemented**
- **From `docs/annotations.md` phases 2–7:**
  - text styling (font, weight, backdrop, outline, shadow);
  - arrow endpoint handles; ellipse; highlight;
  - snapping and guides; keyboard nudge; multi-select and marquee selection on the picture;
  - fill, stroke and shadow; presets; recent colours;
  - typewriter and draw-on animations;
  - spotlight, freehand pen, numbered steps, callouts;
  - keyframes, groups, annotations that follow zooms, templates.
- **From `docs/research/klik-studio-swift-architecture.md`:**
  - segmented/crash-safe writing and a backpressure buffer;
  - iPhone/iPad capture and handling devices that change mid-recording;
  - a keystroke overlay;
  - level meters while recording; removing silences; noise reduction;
  - pointer sway and loop mode;
  - `.klikpreset` style presets;
  - SRT/VTT export;
  - share links via ShareUploader; the XPC/SMAppService helper;
  - face detection; tracked (moving) blurs;
  - String Catalog translations; Display P3 output; HEVC-with-alpha;
  - hiding desktop icons.
