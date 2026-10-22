# 3. Feature list

Every feature found in the research, with where Cue Studio stands and when it is planned.

**Cue Studio column:** Have, Partial, or Missing, as of branch `feat/studio` on 2026-09-30.
**Phase column:** P0 = correctness (now), P1 = parity with Screen Studio, P2 = the market's gaps, P3 = later. "Done" means shipped before this plan. Phases are described in `05-roadmap.md`.
**Competitor columns:** SS = Screen Studio, OSS = best of Recordly / OpenScreen / Cap, Pro = Camtasia / ScreenFlow / FocuSee / Descript / Tella.

## Recording

| Feature | SS | OSS | Pro | Cue Studio | Phase |
|---|---|---|---|---|---|
| Record a display | Yes | Yes | Yes | Have | Done |
| Record a window, including ones on other Spaces | Yes | Yes | Yes | Have | Done |
| Record an area | Yes | Cap only | Yes | Have | Done |
| Warn about windows that would record black | No | No | No | Have | Done |
| Record an iPhone or iPad over USB | Yes | No | ScreenFlow, FocuSee | Have: Device in the bar lists connected devices (CoreMediaIO screen-capture devices through AVFoundation), picture and the device's own sound, opens in an iPhone or iPad frame; not yet run with a real device | Done (unverified on hardware) |
| Create a project from an existing video | Yes | OpenScreen | Yes | Missing | P2 |
| Pointer recorded as data, not burnt in | Yes | Yes | Camtasia | Have | Done |
| Option to burn the pointer in | No | OpenScreen | Yes | Have | Done |
| 30 or 60 fps | 60 only | Yes | Yes | Have | Done |
| HEVC or H.264 | Unknown | OpenScreen | Yes | Have | Done |
| System audio | Yes | Yes | Yes | Have | Done |
| System audio from chosen apps only | Yes | No | ScreenFlow | Have: ticked in the bar's system audio menu | Done |
| Microphone | Yes | Yes | Yes | Have | Done |
| Several microphones, each in its own file | No | No | No | Have | Done |
| Microphone level meter before and during a take | Yes | OpenScreen | Yes | Have (first microphone) | Done |
| Camera | Yes | Yes | Yes | Have | Done |
| Camera preview before recording | Yes | Yes | Yes | Have (round, mirrored, above the bar) | Done |
| Countdown | Yes | Yes | Yes | Have (0, 3, 5, 10 s) | Done |
| Pause and resume | Yes | Yes | Yes | Have | Done |
| Pointer stays in sync after a pause | Unknown | Drifts (Cap) | Unknown | Have, measured | P0, done |
| Restart a take | Yes | OpenScreen | Yes | Have (asks first after 10 s) | Done |
| Discard a take | Yes | Yes | Yes | Have | Done |
| Markers dropped while recording | Yes | No | ScreenFlow | Have (flags on the ruler; jump and split at them) | Done |
| Global shortcuts for start, stop, pause | Yes | Yes | Yes | Have (settable; restart and marker too) | Done |
| Menu bar icon | Yes | Yes | Yes | Have (state, countdown, elapsed time) | Done |
| Speaker notes (teleprompter), hidden from the recording | Yes | OpenScreen, Cap | Tella, FocuSee | Have (never recorded, hidden from sharing) | Done |
| Hide desktop icons while recording | Yes | No | ScreenFlow | Have (in the capture filter; Finder untouched) | Done |
| Resize the window to a preset size before recording | Yes | No | No | Have (window picker › Size: 1280 × 720, 1920 × 1080, 1080 × 1080, 1080 × 1920 in recorded pixels, or fit to display; shrinks to fit keeping the shape; needs Accessibility and says so) | Done |
| Low-disk warning and clean stop | Yes | Cap | Yes | Have | Done |
| Crash-safe recording (file usable after a crash) | Recovery | OpenScreen, Cap | OBS | Have (an unfinished take is recovered) | Done |
| Picture answers a click on the right frame after a still screen | Unknown | Unknown | Unknown | Have, measured | P0, done |

## Pointer

| Feature | SS | OSS | Pro | Cue Studio | Phase |
|---|---|---|---|---|---|
| Show or hide | Yes | Yes | Yes | Have | Done |
| Size after recording | Yes | Yes | Camtasia | Have | Done |
| Smoothing | Presets | Sliders | Camtasia | Have (slider) | Done |
| Pointer lands exactly on its click | Unknown | Bugs | Unknown | Have, measured | P0, done |
| The recording's own pointer image | No | No | No | Have | Done |
| High-resolution drawn pointer | Yes | Yes | Yes | Have | Done |
| Drawn pointer anchored at its real hotspot (I-beam, crosshair) | Yes | Yes | Yes | Have | P0, done |
| Pointer styles (sets) | Yes | Yes | Custom image | Have: as recorded, large arrow, dot, minimal, invisible but clicks | Done |
| Always use the arrow | Yes | No | No | Have | Done |
| Suppress rapid shape changes | Yes | No | No | Have | Done |
| Hide when idle | Yes | OpenScreen, Cap | No | Have (fades, delay adjustable) | Done |
| Hide, hold still or calm over a stretch | Hide only | Hide (Cap) | No | Have | Done |
| Click swell | Yes | Yes | Yes | Have | Done |
| Click ring, with colour and size | Yes | Yes | Yes | Have | Done |
| Other click effects (ripple, spotlight) | Yes | Recordly | Camtasia | Have (ring, ripple, glow) | Done |
| Click sounds | Yes | Extension | ScreenFlow | Have (soft, crisp; volume) | Done |
| Motion blur on the pointer | Yes | Yes | Camtasia | Have | P0, done |
| Loop pointer position for looping videos | Yes | Recordly | No | Have (Pointer › Loop: eased home over the last 0.5–2 s; the zoom and pan come home too unless turned off) | Done |
| Rotate or sway while moving | Yes | Recordly | No | Have (Pointer › Sway: a spring's lean into sideways travel, up to 20°, worked out from the drawn path so scrubbing matches playing; arrows and hands only) | Done |
| Pointer spotlight, highlight, magnify | No | Recordly | Camtasia, FocuSee | Have: spotlight and magnifier, whole video or marked stretches | Done |

## Zoom and camera moves

| Feature | SS | OSS | Pro | Cue Studio | Phase |
|---|---|---|---|---|---|
| Automatic zooms from clicks | Yes | Yes | FocuSee, Camtasia | Have | Done |
| Automatic zooms from typing and text fields | No (rejected) | Screenize | FocuSee | Have (needs keystroke recording on) | Done |
| Automatic zooms respect a crop | Unknown | Unknown | Unknown | Have | P0, done |
| Manual zoom | Yes | Yes | Yes | Have (1–8×) | Done |
| Follow the pointer, or hold a fixed target | Yes | Yes | No | Have | Done |
| Camera moves only when the pointer would leave the shot | No | Recordly (auto mode) | No | Have | Done |
| Frame a zoom by eye on the preview | Target dot | Target | No | Have | Done |
| Easing choice | Two styles | Five | Camtasia | Have (three) | Done |
| Instant zoom (no animation) | Yes | No | No | Have | Done |
| Turn a zoom off without deleting it | Yes | No | No | Have | Done |
| Split and merge zooms | No | No | No | Have | Done |
| Copy, paste, duplicate, multi-select | Yes | Cap | Yes | Have | P0, done |
| Remove all zooms | Yes | No | No | Have | Done |
| Glide between consecutive zooms | No | Recordly | No | Have | Done |
| Keep zoomed in (crop to the aspect and pan) | Yes | No | No | Have: across gaps up to 2, 4 or 8 s, or the whole video (Frame › Zoom, 1.1–4×) with the camera panning after the pointer; zooms inside multiply | Done |
| Motion blur on zoom and pan | Yes | Yes | No | Have (from the camera's speed; scrubbing equals playing) | Done |
| Zoom out below 100% | No (62 votes) | No | No | Have: down to 0.5×, gliding to and from zooms in | Done |
| 3D tilt and perspective | No (107 votes) | OpenScreen, Cap | FocuSee | Have: Frame › Perspective (turn, lean and roll, or Tilt Left, Tilt Right, Lean Back, Isometric); the pointer, clicks, annotations and a device frame turn with the picture, and the canvas handles follow (`FramePerspective`, `SceneRenderer+Perspective`) | Done |

## Camera bubble

| Feature | SS | OSS | Pro | Cue Studio | Phase |
|---|---|---|---|---|---|
| Position, size, roundness, mirror, shadow | Yes | Yes | Yes | Have | Done |
| Drag anywhere on the preview | No | Yes | Yes | Have | Done |
| React to zoom | Shrinks | Yes | No | Have (grows slightly) | Done |
| Layouts over time: full-screen camera, hidden, split | Yes | OpenScreen, Cap | Tella | Have (Camera lane: bubble, camera only, side by side, hidden) | Done |
| Background blur or removal | Beta | OpenScreen, Cap | FocuSee, Descript | Have (Vision person segmentation; not yet checked on a real face) | Done (check by eye) |
| Crop the camera image | Beta | Yes | Yes | Have (zoom 1–3× and offset) | Done |
| Border ring | No | Cap | Yes | Have (width and colour) | Done |

## Audio

| Feature | SS | OSS | Pro | Cue Studio | Phase |
|---|---|---|---|---|---|
| Level, mute and solo per source | Mute only | Gain | Yes | Have | Done |
| Waveforms | Yes | Yes | Yes | Have | Done |
| Detach sound from picture | No | Recordly | Yes | Have | Done |
| Import music or sounds | Yes | Yes | Yes | Have | Done |
| Trimming the start of an imported sound | Yes | Yes | Yes | Have | P0, done |
| Voice-over recorded against the edit | No (337 votes) | OpenScreen | Yes | Have | Done |
| Voice clean-up: noise reduction and levelling | One toggle | Cap | Yes | Have: clean up voice, even out volume to −16 LUFS (no de-essing) | Done |
| Fades in and out | No | No | Yes | Have (on added sounds) | Done |
| Music lowers under speech (ducking) | No | No | Camtasia | Have (from captions or the voice's levels) | Done |
| Built-in music library | Yes | Cap | Yes | Missing | P3 |

## Captions

| Feature | SS | OSS | Pro | Cue Studio | Phase |
|---|---|---|---|---|---|
| On-device transcription | Yes | Yes | No (cloud) | Have | Done |
| Choose the language | Yes | Yes | Yes | Have | Done |
| Edit the text | Yes | Yes | Yes | Have | Done |
| Captions lane; retime, split, merge | No | Recordly, Cap | Yes | Have | Done |
| Position, size, colour, backdrop | Size only | Yes | Yes | Have | Done |
| Font choice and animations | No | Yes | Yes | Have (four typefaces) | Done |
| Word-by-word highlight | Always on | Cap | Tella | Have | Done |
| Export SRT and VTT | Transcript file | Recordly, Cap | Yes | Have | Done |
| Captions without a voice (typed by hand) | No (102 votes) | Recordly | Yes | Have | Done |
| Edit the video by editing the transcript | In progress | OpenScreen, Cap | Descript, Tella | Have: a whole line, or picked words, cut from the video (recorded word timings only) | Done |
| Remove silences and filler words | In progress | OpenScreen (AI key) | Descript, Tella | Have (filler words; pauses over a set length, kept where there is a click) | Done |
| Translation | No | OpenScreen | Tella, Camtasia | Have: on the Mac, into any language it offers (macOS 15+); not yet run end to end | Done (check by hand) |

## Timeline editing

| Feature | SS | OSS | Pro | Cue Studio | Phase |
|---|---|---|---|---|---|
| Trim, split, delete with the gap closed | Yes | Yes | Yes | Have | Done |
| Speed per clip | Presets | Yes | Yes | Have (0.25–8×) | Done |
| Undo and redo, by name | Yes | Yes | Yes | Have | Done |
| Snapping | Yes | Yes | Yes | Have | Done |
| Cut, copy, paste between projects | No | No | No | Have | Done |
| Copies keep every annotation setting | — | — | — | Have | P0, done |
| Lanes stay in time order after a drag | — | — | — | Have | P0, done |
| Step by one frame at the recording's frame rate | Yes | Yes | Yes | Have | P0, done |
| Reorder clips | No | Yes | Yes | Have (drag, menu, inspector; regions travel with the clip) | Done |
| Several recordings or imported clips in one project | No (525 votes) | OpenScreen, Cap | Yes | Have: File › Add Video… and Add Recording… copy the movie into the project and add it as a clip (at the start, the playhead or the end); its sound plays under it, crossfades with its neighbours, and it is fitted into the recording's place (`Commands.AddMedia`, `AudioMixdown+Imported`) | Done |
| Transitions | No (124 votes) | Cap | Yes | Have (crossfade, dip to black or background; sound follows) | Done |
| Freeze frame | No (58 votes) | No | Yes | Have | Done |
| Title and text slides | No (479 votes) | Cap | Yes | Have (three layouts, two backdrops, entrances) | Done |
| Suggest speeding up typing and idle stretches | Yes | No | No | Have (reviewed stretch by stretch, one undo) | Done |
| Autosave | Yes | Yes | Yes | Have | Done |
| Filmstrip thumbnails on the clip lane | Yes | Yes | Yes | Have | Done |
| Command menu | Yes | No | No | Have: every menu command by name, with its shortcut (⇧⌘P) | Done |
| Copy the current frame as an image | Yes | No | Yes | Have (Copy Frame; Save Frame As…) | Done |
| J, K, L playback keys | Yes | No | Yes | Have | Done |

## Annotations, masks and overlays

| Feature | SS | OSS | Pro | Cue Studio | Phase |
|---|---|---|---|---|---|
| Text | No | Yes | Yes | Have | Done |
| Arrow | No | Yes | Yes | Have (draggable ends, Shift snaps to 15°) | Done |
| Box | No | No | Yes | Have | Done |
| Enter and exit animation | No | Yes | Yes | Have | Done |
| Rotate, lock, hide, stacking order | — | No | Yes | Have | Done |
| Ellipse, line, highlight marker | No | No | Yes | Have | Done |
| Spotlight (dim everything else) | One, static | Cap | Camtasia, FocuSee | Have (Mask kind "Spotlight", timed like any mask) | Done |
| Numbered steps, callouts, freehand | No | No | Camtasia, FocuSee | Have, except freehand | P2 (freehand) |
| Text styling: font, weight, backdrop, outline | — | Yes | Yes | Have (any installed family; the system font where one is missing) | Done |
| Image overlay and logo watermark | No (88 votes) | Yes | Yes | Have (Picture…, Logo…) | Done |
| Blur region | One | Yes | Yes | Have, several at once | Done |
| Pixelate | No | Yes | Yes | Have | Done |
| Solid cover (cannot be reversed) | No | Recordly | Camtasia | Have | Done |
| Blur lands in the right place when cropped | — | — | — | Have | P0, done |
| Blur that follows content | No (568 votes) | No | No | Have (Follow Content: tracks from the playhead both ways) | Done |
| Find and hide sensitive information | — | — | — | Have (Mask › Find Sensitive Information…: emails, phones, cards, IBANs, keys, IP addresses, password fields; reviewed in a sheet) | Done |
| Keyboard shortcut overlay | Yes | Cap | Yes | Have (needs keystroke recording on) | Done |

## Backgrounds and frame

| Feature | SS | OSS | Pro | Cue Studio | Phase |
|---|---|---|---|---|---|
| Wallpapers, gradients, colours, own image | Yes | Yes | Yes | Have | Done |
| Background blur | Yes | Yes | No | Have | Done |
| Padding, rounded corners, shadow | Yes | Yes | No | Have | Done |
| Border or inset | Yes | Cap | No | Have | Done |
| Aspect: source, 16:9, 1:1, 9:16, 4:3 | Yes | Yes | Yes | Have | Done |
| Aspect: 4:5, 3:4, 16:10, custom | Yes | Yes | Yes | Have | Done |
| Crop | Yes | Yes | Yes | Have | Done |
| Custom gradient colours and angle | No | OpenScreen | No | Have (2–3 colours, linear or radial) | Done |
| Device frames (iPhone, iPad, Mac, browser) | iPhone, iPad | OpenScreen, Cap | Rotato | Have: macOS window, browser, iPhone and iPad, drawn (no bitmaps), portrait and landscape | Done |
| Animated or video backgrounds | No | Recordly, Cap | No | Have: moving backgrounds (drift, aurora, grain; drawn fresh each frame) and a looping background video, silent (Frame › Background Video…; `Style.Background.animated`, `.video`) | Done |
| Saved style presets, shareable as files | Yes | Yes | Yes | Have (`.cuestyle` files, six built in) | Done |

## Export and sharing

| Feature | SS | OSS | Pro | Cue Studio | Phase |
|---|---|---|---|---|---|
| MP4 and GIF | Yes | Yes | Yes | Have | Done |
| MOV | No | No | Yes | Have | Done |
| 720p to 4K | No 1440p | Varies | Yes | Have, including 1440p | Done |
| 15 to 60 fps | Yes | Yes | Yes | Have | Done |
| Quality presets | Yes | Yes | Yes | Have | Done |
| Size estimate before export | No | Cap | No | Have | Done |
| Preview matches export | Mostly | Bugs | Mostly | Have (one renderer) | Done |
| Export continues after the window closes | No | No | No | Have | Done |
| Encoder check uses the right capability | — | — | — | Have | P0, done |
| Copy to clipboard, reveal, share sheet | Yes | No | Yes | Have | Done |
| Export a range only | No (12 votes) | No | Yes | Have (Export Selection…; I and O mark it) | Done |
| ProRes | No | Cap (pointer only) | Yes | Have (422 and 4444, 24-bit sound) | Done |
| Transparent background | No (148 votes) | Cap | Rotato | Have (ProRes 4444 or HEVC with transparency) | Done |
| Shareable link | Yes | Cap | Tella, Loom | Missing | P3 |

## Projects, library and settings

| Feature | SS | OSS | Pro | Cue Studio | Phase |
|---|---|---|---|---|---|
| Project is one package that can be moved | Yes | Yes | Yes | Have | Done |
| Library: thumbnails, search, sort, rename, duplicate, trash | Basic | Basic | Yes | Have | Done |
| Defaults for new projects | Yes | Yes | Yes | Have | Done |
| One editor window, replaced on open | — | — | — | Have | Done |
| Rebindable shortcuts | Yes | Recordly | Yes | Have: every editor menu command and the recorder's global keys | Done |
| Light and dark appearance | Dark only | Both | Both | Have | Done |
| Translations | No | 11–15 languages | Yes | Missing | P3 |

## Count

| Features listed | Have | Partial or wrong | Missing |
|---|---|---|---|
| 165 | 77 | 14 | 74 |

- Of the 14 partial or wrong items, 10 are correctness bugs (P0) and 4 are features that exist in the model with no way to reach them.
- Of the 74 missing, 37 are P1, 23 are P2 and 14 are P3.
- This count is of the plan as written on 2026-09-29. `05-roadmap.md` tracks what has been done since.
