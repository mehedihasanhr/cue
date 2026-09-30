# 5. Roadmap and tasks

Four phases. Each task is small enough to build, test and check on screen in one sitting.

**A task is done when:** it has tests, the packages and the app build with no warnings, and it has been checked in the running app.

Status: `[x]` done, `[~]` in progress, `[ ]` not started.

## Phase 0: correctness

Fix what is wrong before adding anything. Details and measurements are in `06-quality-log.md`.

### Recording
- [x] Pointer stays in sync after a pause
- [x] The frame that ends a still screen is never dropped
- [x] The recording runs to its real end
- [x] Clock starts at the first frame's timestamp
- [x] Clicks stamped with the event's own time and place
- [x] Pointer times moved by one display refresh to meet the picture
- [x] Clicks added to the pointer's path
- [x] "Automatic" encoder checks for a hardware encoder
- [x] Crash-safe recording, and recovery of an unfinished take

### Drawing and preview
- [x] Drawn pointers placed by their hotspot
- [x] Motion blur does not move the pointer
- [x] Preview shows the frame that belongs to the moment
- [x] Frame stepping uses the recording's frame rate

### Editing
- [x] Blur outlines follow the crop
- [x] Auto zoom respects the crop
- [x] Changing the crop re-aims existing zooms
- [x] Copies keep every field
- [x] Trimming the start of an imported sound trims it
- [x] Lanes stay in time order after a drag

### App
- [x] One editor window
- [x] Window picker redesigned; opens over full-screen apps
- [x] Recorder bar stays centred when it changes shape
- [x] Clean build: no warnings
- [x] Capabilities reported to Klik are correct
- [x] Menu bar: one set of commands, every tool, Save, a Captions menu
- [x] The settings panel follows the last thing chosen, tool or selection

### Measuring
- [x] `studiolab pointer` for display, area and window recordings
- [x] `studiolab stream` for ScreenCaptureKit's timing
- [x] `studiolab press`, `key`, `shot` to drive and photograph the app without taking the screen
- [x] `studiolab export`: the app's exporter on a real recording, then the file read back (lengths, click sounds against clicks)

## Phase 1: parity with Screen Studio

### Pointer
- [x] Hide when idle, with a fade
- [x] Always use the arrow; suppress rapid shape changes
- [x] Hand pointers drawn as hands
- [x] Pointer styles: as recorded, large arrow, dot, minimal, invisible but clicks
- [x] More click effects: ring, ripple, glow
- [x] Click sounds (soft, crisp; volume), heard in preview and export

### Zoom
- [x] Instant zoom toggle
- [x] Remove all zooms
- [x] Glide between consecutive zooms
- [x] Typing and text-field zooms (from recorded keys)

### Keyboard
- [x] Record shortcuts: the key only when ⌘ or ⌃ is held, or for named keys
- [x] Keys lane on the timeline
- [x] Keycap overlay in preview and export
- [x] Setting, with the Accessibility prompt

### Captions
- [x] Captions lane: retime, split, merge
- [x] Captions typed by hand
- [x] Language choice
- [x] Font, animation and word highlight
- [x] Export SRT and VTT

### Camera
- [x] Layouts over time: bubble, camera only, side by side, hidden
- [x] Camera preview before recording

### Audio
- [x] Fades on added sounds, drawn on the chip
- [x] Voice clean-up: noise reduction and levelling (de-essing still open)
- [x] Microphone level meter

### Frame
- [x] Aspect ratios 4:5, 3:4, 16:10, custom
- [x] Border
- [x] Saved looks, as `.klikstyle` files, six built in

### Masks
- [x] Spotlight (dim everything else)
- [x] Solid cover

### Timeline
- [x] Autosave
- [x] Filmstrip thumbnails on the clip lane
- [x] J, K, L playback
- [x] Copy the current frame as an image; Save Frame As…
- [x] Suggest speeding up typing and idle stretches (Edit › Speed Up Waiting…)
- [x] Image overlay and logo watermark (Picture…, Logo…)

### Recorder
- [x] Restart a take
- [x] Markers while recording
- [x] Global shortcuts
- [x] Menu bar icon
- [x] Speaker notes
- [x] Hide desktop icons

### Export
- [x] Export a range (Export Selection…; I and O mark it)

## Phase 2: the market's gaps

- [x] Blur that follows content
- [x] Find sensitive information on screen and hide it (Mask › Find Sensitive Information…)
- [x] More annotations: ellipse, line, highlight, numbered steps, callouts (freehand still open)
- [x] Text styling: font family, weight, alignment, backdrop, outline, shadow
- [ ] Several recordings in one project; import a video
- [x] Reorder clips
- [x] Freeze frame
- [x] Transitions
- [x] Title slides
- [x] Edit by transcript: remove a line, or pick single words and cut them (recorded timings only)
- [x] Remove filler words; shorten pauses (not during clicks)
- [x] Keep zoomed in across gaps between zooms (Camera Motion › Stay zoomed in), or for the whole video with the camera panning after the pointer (Frame › Zoom)
- [x] Motion blur on zoom and pan
- [x] Camera background blur and removal; camera crop; border (removal still to check on a real face)
- [x] Music ducking
- [x] Device and browser frames: macOS window, browser, iPhone and iPad (Frame › Window; black, silver or natural rim; portrait, landscape or held the way the recording is shaped; camera pill or dot optional)
- [x] Custom gradients
- [x] ProRes export; transparent export
- [x] Smaller File export (HEVC) and a target size for MP4, MOV and GIF
- [x] Safe zones for Shorts, TikTok and Reels over a 9 : 16 preview (View › Show Safe Zones; never exported)
- [x] Pointer spotlight and magnify
- [x] Loop the pointer position for looping videos, camera included (Pointer › Loop)
- [x] Pointer sway while moving (Pointer › Sway)
- [x] Resize a window to a preset size before recording it (window picker › Size; Accessibility)

## Phase 3: later

- [~] iPhone and iPad recording (Device in the bar; a connected, unlocked, trusting device is recorded through CoreMediaIO's screen-capture devices, its sound into its own lane, no pointer; opens in the matching device frame. Built and tested up to the capture itself, which needs a device on a cable — see the quality log)
- [x] System audio from chosen apps (the bar's system audio menu; a second, audio-only stream whose filter includes only those apps — see `SystemAudioRoute`)
- [ ] 3D tilt and perspective
- [x] Zoom out below 100% (down to 0.5×: the framed recording shrinks with its corners, shadow and border, and the background shows round it)
- [ ] Animated backgrounds
- [~] Caption translation (Captions › Translate Captions…; built and compiles, not yet run end to end because a first translation can open the system download sheet)
- [ ] Music library
- [ ] Shareable links
- [x] Rebindable shortcuts; command menu (Settings › Shortcuts: every editor menu command and the recorder's global keys, with conflict checks both ways and reset per row or all; the command menu shows whatever is set)
- [ ] Translations of the app

## Order of work inside a phase

1. What users complain about most (see `02-gap-analysis.md`).
2. What is small and unlocks something else. Keystroke timing unlocks the keyboard overlay, typing zooms and pacing suggestions.
3. What can be tested without a person at the screen.
