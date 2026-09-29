# 4. Architecture

How Klik Studio is built today, the rules that keep it correct, and how each planned feature fits in. The earlier design document, `docs/research/klik-studio-swift-architecture.md`, has the original reasoning; this page is the current state plus what comes next.

## Principles

1. **One clock.** Every file and every sample in a recording is stamped against `RecordingClock`. It starts at the first frame's own timestamp and owns every pause.
2. **One renderer.** The preview and the export both call `SceneBuilder` then `SceneRenderer`. Nothing is drawn twice in two ways.
3. **Pure description, then drawing.** `SceneBuilder` turns (edit, moment) into a `SceneDescriptor` value. It holds no state, so scrubbing to a frame gives the same picture as playing to it.
4. **The edit is one value.** `Timeline` is a Codable struct. Commands change it; undo keeps whole copies.
5. **Measured, not judged by eye.** Timing and placement are checked by `Tools/studio-lab` against a real recording, and every fixed bug gets a test.
6. **Local and private.** Nothing leaves the Mac. Keystrokes are timed, never recorded.
7. **Native.** Swift, SwiftUI for views, AppKit for windows, Core Image on Metal for drawing.

## Packages

```
Klik (host app) ──AddOnKit──▶ Klik Studio (app)
                                   │
        ┌──────────────┬───────────┼────────────────┐
        ▼              ▼           ▼                ▼
    RecordKit ──▶ TimelineKit ──▶ RenderKit    BackgroundKit
    capture       the edit        drawing      wallpapers,
    telemetry     commands        export       gradients
    the package   analysis        mixdown
```

| Package | Owns | Depends on |
|---|---|---|
| `AddOnKit` | The request Klik sends and the `klik-studio://` link | — |
| `RecordKit` | ScreenCaptureKit capture, microphones, camera, the clock, writers, telemetry, the `.klikrec` package, the library | AddOnKit |
| `TimelineKit` | `Timeline` and its regions, commands, undo, snapping, clipboard payloads, zoom suggestion, pointer track, caption shaping, waveforms | RecordKit |
| `RenderKit` | `SceneBuilder`, `SceneDescriptor`, `SceneRenderer`, `FrameSource`, exporters, audio mixdown | TimelineKit |
| `BackgroundKit` | Wallpaper catalogue, gradients, imported backgrounds | — |
| `KlikStudio` (app) | Recorder bar, target overlay, editor windows, inspector, timeline views, export queue, settings, captions | all of the above |
| `Tools/studio-lab` | Measuring: scripted pointer recordings, ScreenCaptureKit timing probe, driving the app through Accessibility | RecordKit, TimelineKit, RenderKit |

## Recording

```
ScreenCaptureKit ──frames──▶ ScreenRecorder ──▶ SessionWriter ──▶ media/screen.mov
        │                        │  idle frames keep the file in step
        └─system audio──────────▶ AudioTrackWriter ──▶ media/system-audio.m4a
AVCaptureSession (mic N) ───────▶ AudioTrackWriter ──▶ media/microphone-N.m4a
AVCaptureSession (camera) ──────▶ SessionWriter ──────▶ media/webcam.mov
CGEvent location, 120 Hz ───────▶ CursorTracker ──────▶ telemetry/cursor.jsonl
NSEvent global monitor ─────────▶ CursorTracker ──────▶ telemetry/input.jsonl
NSWorkspace, Accessibility ─────▶ FocusTracker ───────▶ telemetry/focus.jsonl
                     all stamped by RecordingClock
```

### Timing rules

These are the rules the pointer-sync fixes established. Each has a test.

| Rule | Why |
|---|---|
| The clock starts at the first frame's timestamp, not when the frame arrives | A frame reaches the writer a few milliseconds either side of its timestamp, differently each take |
| A pause is taken out by the clock, for every file and every sample | Writers used to keep their own totals and telemetry kept none, so the pointer ran late by the length of the pause |
| A still screen is kept in step one frame at a time, from ScreenCaptureKit's idle frames | Filling a long stillness in one burst made the encoder refuse the frame that ended it |
| The frame that ends a stillness is never dropped | It is the one that shows the click being answered |
| A click is stamped with the event's own time and place | The callback runs later, after the pointer has moved on |
| Pointer times are moved by one display refresh | The screen shows the pointer one refresh after the system knows where it is |
| A click is a sample of the pointer's path | So the pointer passes through the place it clicked, exactly |

### The `.klikrec` package

```
Recording.klikrec/
  manifest.json          what was recorded: tracks, sizes, clock, telemetry paths
  project.json           the edit (a Timeline), written on save
  media/                 screen.mov, webcam.mov, system-audio.m4a, microphone-N.m4a
  telemetry/             cursor.jsonl, input.jsonl, focus.jsonl, cursors/ (pointer images)
  derived/               regenerable: waveform peaks, poster.jpg
  Audio/, Backgrounds/   files the edit brought in
```

## The edit

`Timeline` holds: clips, zooms, blurs, annotations, captions, added sounds, the detached sound lane, pointer stretches, and the styles (frame, pointer, camera, sound, webcam, captions).

- **Clips** are contiguous by construction. A clip stores where it starts in the recording, its length there, and its speed.
- **Regions** (`TimelineRegion`) all have an id, a start and a duration, so moving, resizing, snapping and deleting are written once.
- **Coordinates.** Three spaces are in use, and mixing them up is the commonest bug:

| Space | Used by | Means |
|---|---|---|
| The recording | Blur rectangles | A fraction of the whole recorded picture, before any crop |
| The picture | Zoom centres, pointer positions in a scene | A fraction of the cropped picture |
| The finished frame | Annotations, the camera bubble, captions | A fraction of the exported frame, padding included |

`PictureMapping` converts between them for views. `Commands.SetCrop` re-aims zooms when the crop changes.

## Drawing

```
Timeline + time + CursorTrack ──SceneBuilder──▶ SceneDescriptor ──SceneRenderer──▶ CIImage
                                                                       │
                                  FrameSource (preview) ───────────────┤ source frame
                                  ExportFrameReader (export) ──────────┘
```

Layer order, bottom to top: background, shadow, the recording (blurs applied, cropped, zoomed, corners rounded), camera bubble, annotations, caption, click rings, pointer.

`FrameSource` files its cached frames under the recording's own frame index, so a moment always gets the frame that belongs to it.

## Export

`VideoExporter` (MP4, MOV) and `GIFExporter` read frames in order through `ExportFrameReader`, build each scene with the same builder, and write through `AVAssetWriter` or ImageIO. `AudioMixdown` builds the sound. `ExportJobs` is a queue owned by the app, so an export outlives the editor window that started it.

## How the planned features fit

Each is an addition to one of the layers above. None needs a second renderer or a second clock.

| Feature | Model (TimelineKit) | Recording (RecordKit) | Drawing (RenderKit) | App |
|---|---|---|---|---|
| **Blur that follows content** | `BlurRegion.path`: keyframes of (source time, rectangle) | — | `SceneBuilder` interpolates the rectangle at the source time | "Follow content" button runs `RegionTracker` (Vision) over the stretch |
| **Spotlight and solid cover** | New `BlurRegion.Style` cases | — | Spotlight dims outside the rectangle; cover fills it | Style picker in the blur inspector |
| **Keyboard shortcut overlay** | `KeyCue` regions on a Keys lane, generated from telemetry | `InputSample.shortcut`: key recorded only with ⌘, ⌃ or ⌥ held, or for named keys | `KeycapArtwork` draws keycaps | Keys lane, inspector, setting with the Accessibility prompt |
| **Pointer idle hide, styles, click sounds** | `CursorStyle` fields | — | Idle fade computed from the track; artwork sets; clicks mixed into the sound | Pointer inspector |
| **More annotations** | New `AnnotationItem.Kind` cases: ellipse, line, highlight, step, image | — | `AnnotationArtwork` | Annotate tool menu |
| **Captions lane, styling, SRT/VTT** | Words with timings on `CaptionCue`; style fields; `CaptionExport` | — | `CaptionArtwork` word highlight | Captions lane; export options |
| **Camera layouts over time** | `LayoutRegion` lane: camera full, hidden, split | — | `webcamLayer` and `videoFrame` read the layout in force | Layout lane |
| **Camera background removal** | `WebcamSettings.background` | — | Vision person segmentation as a mask | Webcam inspector |
| **Voice clean-up, fades** | `SoundStyle` fields per source | — | `AudioMixdown` adds volume ramps and an isolation pass | Audio inspector |
| **Style presets** | `StylePreset`: the style parts of a `Timeline` | — | — | Preset menu; `.klikpreset` files |
| **More aspect ratios, border** | `AspectPreset` cases; `FrameStyle.border` | — | Border drawn with the corners | Frame inspector |
| **Freeze frame, transitions, title slides** | `Clip.Kind`: footage, still, title; `Transition` on a cut | — | `SceneBuilder` blends two scenes across a transition | Timeline |
| **Several recordings in one project** | `Timeline.sources`; `Clip.sourceID` | Importing copies media and telemetry into the package | One `FrameSource` and one pointer track per source | Import and append commands |
| **Typing and idle speed-up** | `PaceSuggester` proposes clip speeds | Keystroke timing switched on | — | "Suggest pacing" command |
| **Transcript editing, silence removal** | Words map to source time; deleting words cuts clips | — | — | Transcript panel |
| **ProRes, transparent export, range export** | `ExportSettings` fields | — | Writer settings; alpha background | Export sheet |
| **Crash-safe recording** | — | Fragmented movie writing; rebuild a manifest from what is on disk | — | Offer to recover at launch |
| **Markers, restart, global shortcuts, menu bar icon** | `Timeline.markers` | `telemetry/markers.jsonl` | — | Bar, status item, hot keys |
| **Speaker notes** | — | Window left out of the capture | — | Notes panel |
| **iPhone and iPad recording** | Device frame in `FrameStyle` | `AVCaptureDevice` for a connected device | Frame artwork | Device mode in the bar |

## As built (2026-09-29)

Where the build differs from the plan above, the build is the truth:

| Area | As built |
|---|---|
| Crash-safe recording | Every file is written with `movieFragmentInterval` = 1 s, so an unfinished file plays up to its last fragment; `finishWriting` turns it back into an ordinary movie. An `in-progress.json` marker in the package (the planned manifest and the writing process) says a take did not finish. `TakeRecovery` rewrites the files, checks the first and last frames decode, completes the manifest with a `recovery` note, then swaps and removes the marker; if anything fails, the package is left byte for byte. Sidecars reach the disk every 0.5 s, and the take's files are synced to the disk every 2 s. `RecordKitCrashProbe` is a test-only executable that is killed mid-take by the tests |
| Keyboard | `InputSample.shortcut` with the key only when ⌘ or ⌃ is held or for a named key (never ⌥ alone, which types characters on most keyboards); everything else is `InputSample.key` with no identity. `telemetry.keys` in the manifest says whether keys were recorded or not permitted. `KeyCue` regions on the Keys lane, `KeyStyle` on the timeline, `KeyLayer` drawn by `KeycapArtwork`, kept clear of captions and the camera bubble |
| Looks | `Look` (`.klikstyle` JSON with a version; every field optional) captures the frame, pointer, captions, camera and bubble styles but not whether the bubble is on. `LookStore` keeps them in Application Support; six are built in. `LookFidelityTests` fail if a style setting is added and not carried |
| Masks | `BlurRegion.Style`: blur, pixelate, cover, spotlight; spotlights are unioned into one dimmed picture |
| Sensitive text | `SensitiveScanner` (RenderKit) reads two samples a second with Vision's accurate recogniser, skipping samples whose picture has not changed; `SensitiveText` (TimelineKit, pure) says what counts; `SensitiveGrouping` makes consecutive readings one stretch; edges are pinned to the frame by halving, with two frames of margin; moving text is followed with `MaskFollower`, checked against the readings. `SensitiveFinding` is on the recording's clock and cached in `derived/sensitive-text.json`; `masks(in:…)` maps it through the edit (cuts, speeds, freeze frames) and `Commands.AddMasks` adds the lot as one undo step |
| Zoom motion | `ZoomRegion.isInstant`; `CameraStyle.glidesBetweenZooms` (off for projects saved before it existed); the glide rule is in `ZoomGlide` |
| Editing | `ClipSequence` moves regions through one time mapping for a speed change; a deletion is ripple-cut through captions word by word (`CaptionCue.cut`) and through detached sound runs (`SoundRun.split`). `Commands.FromSnapshot` replays a drag's edit on the timeline as the drag found it. `Commands.DeleteRanges` cuts several stretches as one edit |
| Transcript editing | `TranscriptEditing`: filler words and long pauses from the recogniser's word timings only (never guessed ones); pauses containing a click are kept. Words picked in the transcript (`TranscriptWordSelection`, apart from the timeline's selection) are cut by `TranscriptEditing.wordCutRanges`: 30 ms either side, runs of neighbouring words as one cut, never into a word that stays; one `DeleteRanges` edit. A pick is kept with the word's range, so a word that has moved since is not cut |
| Fonts | A family by name (`fontFamily`, empty for the system's type) on `AnnotationStyle`, `CaptionStyle` (carried by `Look`) and `TitleCard`. `FontFamilies` resolves it through Core Text for measuring (`AnnotationFit`) and drawing alike; a family this Mac lacks draws the system's type (captions and titles: their `typeface`) and the inspector says so |
| Safe zones | `SafeZonePlatform` (TimelineKit) holds the covered areas for Shorts, TikTok and Reels as fractions of a 9 : 16 frame; `SafeZoneOverlay` draws them in SwiftUI over the preview, so the renderer never sees them |
| Sound | Click sounds are synthesised (`ClickSound`) and laid on their own tracks in `AudioMixdown`; added sounds have fades as volume ramps. Both are in `AudioSignature`, so the preview rebuilds when they change |
| Pictures | Picture annotations are copied into the package's `Images` folder as PNG, named relative to it, and drawn to fit their box |
| Export | `VideoExporter` finishes the sound as soon as it runs out; `GIFExporter` spreads frame delays so a GIF lasts as long as the edit; `FrameStill` renders one frame for Copy Frame; `Timeline.cut(to:)` makes a selection into its own timeline for Export Selection |
| Picture looks | `FrameStyle.perspective` (`FramePerspective`: turn, lean, rotation, depth shadow, straighten while zoomed) becomes `SceneDescriptor.perspective`; `PerspectiveProjection` is the one map of the flat frame onto the turned one, and the picture, pointer, clicks, annotations, spotlight and lens all go through it (`SceneRenderer.tilted`) while captions, keys and the camera stay upright. `FrameStyle.grade` (`ColorGrade`, with an optional `.cube` in the package's `LUTs/`) is `SceneDescriptor.grade`, applied inside `videoLayer` before the corners, border and window. `Background.animated` (drift, aurora, grain) is drawn from the finished video's time stamped into `BackgroundLayer`; `Background.video` loops a movie in `Backgrounds/` through `ExportFrameReader`, one reader per renderer (`BackgroundMovies`). A look carries the perspective and the grade's sliders, never the `.cube` or the movie |
| Several sources | Not `Timeline.sources`/`Clip.sourceID`: `Clip.source` is a package-relative path (`nil` = the recording) and `Timeline.media` records each imported `MediaFile` (path, length, pixel size, has sound) measured once on arrival. Files are copied into `Movies/`; Add Recording copies another take's screen with its sound files as tracks of one movie (`MediaImport.combine`), leaving its pointer, clicks, keys and edit behind. `Timeline.sourceTime(at:)` is `nil` over an imported clip and every walk from the recording's clock (`timelineTime(atSource:)`, clicks, markers, words, ducking, detached runs) passes it by; `mediaTime(at:)` says which file for pictures. `SceneDescriptor.sourceMedia` names the file; `SceneBuilder` fits the picture into the recording's frame (aspect-fit, background round it, no crop, no pointer, no camera); `SourceFrames` reads it for the export, crossfade and still, `ImportedMedia` for the preview and filmstrip. An imported clip's sound is laid from its own file under its clip in `AudioMixdown+Imported`, at the master level, attached to its clip even when the recording's lane is detached |
| Subtitles and chapters | `SubtitleImport` reads SRT and VTT forgivingly (BOM, CR/CRLF, missing numbers, VTT header/NOTE/STYLE/REGION, cue settings, tags, entities); overlapping cues are cut where any begins or ends and shown stacked; `Commands.ImportSubtitles` replaces the captions in one step. `Chapters` builds chapters from markers and title slides and checks YouTube's rules (0:00 first, three or more, ten seconds each) |
| Export | Smaller File is HEVC at a low bitrate (`ExportSettings.videoCodec`); a target size lowers a movie's bitrate to fit (`videoBitrate(forPixels:frameRate:duration:)`, with a one-second peak limit) and aims a GIF by shrinking it, then dropping frames (`aimedAtTarget`). `VideoExporter` finishes the sound as soon as it runs out; `GIFExporter` spreads frame delays so a GIF lasts as long as the edit; `FrameStill` renders one frame for Copy Frame; `Timeline.cut(to:)` makes a selection into its own timeline for Export Selection |
| Autosave | `AutosaveTiming` (pure) decides when; `EditorDocument.saveInBackground()` writes atomically; the editor never writes when nothing changed |

## Testing

| Level | Tool | What it proves |
|---|---|---|
| Unit | `swift test` in each package (about 1,300 tests) | Arithmetic, commands, scene description, drawing, export |
| Measured recording | `studiolab pointer --target display\|area\|window` | The written pointer matches the real one in time and place, including after a pause |
| Capture behaviour | `studiolab stream` | What ScreenCaptureKit's timestamps mean on this Mac |
| App, without taking the screen | `studiolab press`, `key`, `shot` | Menu commands work; what the editor looks like |
| Export, on a real recording | `studiolab export` | The app's exporter writes a file of the right length, with click sounds where the clicks are |
| Build | `xcodebuild` for `KlikStudio` and `Klik` | Compiles with no warnings |

The measuring tool moves the real pointer and covers the screen for about 25 seconds, so it is run deliberately, not on every change.
