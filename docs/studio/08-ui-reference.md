# 8. UI reference: Screen Studio 4.0.1

What Screen Studio's screens look like and how they behave, written down so Cue Studio can match the layout and the flow. Captured 2026-10-28 from Screen Studio 4.0.1-4897.

**Sources**
- Screenshots of the recorder bar, the recent projects strip and the editor (Background tab). The screenshots stay outside the repo.
- Everything else comes from the UI strings and analytics event names in the app bundle, plus [`../research/competitor-screen-studio.md`](../research/competitor-screen-studio.md).

**Rules**
- Match regions, order and flows.
- Do not copy Screen Studio's wallpapers, cursors, device art, music, icons or brand colour. Cue keeps its own.

## Recorder bar

One dark rounded bar, 919 × 64 pt, centred near the bottom of the screen. From left to right:

1. **Close** (×), in a filled circle. A thin divider follows.
2. **Source buttons:** Display, Window, Area, Device. Each is an icon over a small label, about 60 pt wide. Picking one starts that picker.
   - Display: click a screen.
   - Window: click a window; right-click for a list.
   - Area: drag, with guides.
   - Device: a USB iPhone or iPad.
3. A divider.
4. **Input menus:** camera, microphone, system audio. Each is an icon plus the current choice ("No camera", "No microphone", "No system audio"). A crossed-out icon means off. Each opens a menu of devices.
   - System audio offers "all apps" or "selected apps".
   - The microphone menu shows a live level.
5. A divider.
6. **Projects** (folder icon) on a slightly lighter tile. It opens the recent projects strip.
7. **Settings** (gear with a chevron). It opens a menu with recording options: countdown, hide desktop icons, highlight the recorded area, and the camera preview.

**Recording widget (`recording-manager-widget`).** A small floating pill with:
- timer
- stop
- pause/resume
- restart
- delete
- marker

It is hideable and excluded from the recording. After a take, an optional **quick share widget** offers Edit, Save, Copy and Share, using the last export settings.

## Recent projects

A full-width strip, 280 pt high, along the bottom of the screen, above the recorder bar. It does not open as a window in the middle.
- **Top row:** close (×) at left. At right: "Show previous projects", "Open project…" and a search field.
- **Below:** a horizontal row of large thumbnails, about 16:9 and 255 pt wide, each with the project name (truncated) and its date.
- **Right-click:** Rename, Duplicate, Show in Finder, Remove from Recents, Copy and zip, Apply preset.

## Editor window

One dark window. There are four regions.

### Title bar (≈52 pt)

- **Left:** traffic lights, Open project (folder), Delete project (trash).
- **Centre:** project file name, with the extension dimmed.
- **Right:**
  - command menu (⌘ icon)
  - undo and redo, with a divider after them
  - **Presets ▾**
  - **Export**: the one filled, brand-coloured button in the window
  - update notice

### Preview area

- **Top-left:** a layout menu ("Auto ▾", the output aspect ratio) and **Crop**.
- **Top-right:** "Preview quality Full ▾", zoom out and zoom in.
- **Left edge:** a floating vertical tool palette in a rounded capsule. Its buttons are Add zoom, Zoom in place, Add mask, and Add sensitive-data mask, each a quick action on the timeline.
- **Centre:** the preview, letterboxed on a near-black canvas.

### Right sidebar (≈300 pt panel + ≈50 pt tab column)

Its tab icons run down a column **to the left of the panel**, inside the right side of the window. The active tab is highlighted with a dot. The tabs, top to bottom:

1. **Background:**
   - Type segments: Wallpaper, Gradient, Color, Image, Unsplash. The segments scroll sideways.
   - Wallpaper categories: favourites ★, macOS, and themed packs.
   - "Pick random wallpaper", then a thumbnail grid of 8 per row.
   - Sliders: Background blur, Padding, Screen rounded corners, Inset, Shadow. "Advanced shadow settings" holds angle, blur and directional shadow.
   - Each slider has a **Reset** button on its right, dimmed when the value is already the default.
2. **Cursor:**
   - Cursor size; style set grid with a hover preview.
   - Toggles: hide when idle, loop position, always use pointer, rotation while moving, remove shakes.
   - Smoothing presets, click effect, click sound, motion blur.
3. **Camera layout:** Default, Fullscreen, Hidden, Split, Cutout, plus "Add … layout" actions.
4. **Camera style:**
   - Size, size during zoom, position, aspect ratio, corners.
   - Mirror, crop, sharpen.
   - LUT, edge falloff and edge inset for the cutout.
   - Hide during silence.
5. **Captions / transcript:** Generate transcript (method picker). The text list supports cut, hide words, remove fillers and tighten pauses. Below it are caption size and position.
6. **Zoom:** Create zooms automatically, Zoom animations (Focused/Smooth), Instant animation, start early, default level.
7. **Audio:** volumes for mic, system and background; mute toggles; noise reduction; background audio library and file; AI voiceover.
8. **Keyboard shortcuts:** show pressed shortcuts, single-key shortcuts, label size, speed up typing.
9. **Device frame:** use device mockup, frame picker.

### Bottom: transport and timeline

**Transport row** (≈44 pt, same background as the canvas):
- **Left:** cut tool (scissors).
- **Centre:** current time, previous, play, next, total time.
- **Right:** audio scrubber toggle, playback speed (1×), timeline zoom slider.

**Ruler**: time labels every 5 s with dots in between. The playhead is a small brand-coloured circle with a line.

**Tracks** have no name gutter. Each kind has its own colour, and each block carries its own label:
- **Clip track**: a tall amber bar, with "Clip" and its duration and speed in the middle (for example 52s · 1×). Cut it into slices.
- **Zoom track**: brand-coloured rounded blocks labelled "Zoom", showing the level and mode (for example 2× · Auto). Click empty space to add one; drag the edges to change its length.
- **Layout, mask and voiceover tracks** appear under the zoom track once they have content.

**Right-click** on a block gives Split at current time, Copy, Duplicate, Remove, Apply to all, and the block's own settings.

## Export

Export opens a picker with three destinations: **Export to file**, **Copy to clipboard** and **Create shareable link**.
- Settings: format (MP4 or GIF), resolution (720p, 1080p, 4K), frame rate (up to 60 fps), and quality (web, social media, studio).
- A note: "Quality setting does not impact export speed."
- Exports run in the background. Recent clipboard and link exports can be reopened.

## What this means for Cue Studio

| Area | Screen Studio | Cue Studio today | Change |
|---|---|---|---|
| Recorder bar | Close · sources · inputs · projects · settings | `RecorderBar` | Reorder to match; inputs show their current choice as text |
| Projects | Bottom strip above the bar | `LibraryWindow`, a centred window | Offer the strip from the bar; keep the window for managing projects |
| Tool tabs | Icon column inside the right sidebar | `EditorRail` on the far left | Move into the sidebar |
| Quick actions | Floating palette on the preview's left | `CanvasToolBar` | Keep; align its actions |
| Export | One filled button in the title bar | Toolbar pill plus a button in the inspector | One button, title bar |
| Slider reset | Reset button on every slider | Varies | Add to `InspectorSlider` |
| Timeline | Labelled blocks, colour per kind | Lanes come and go | Fixed order; labels on blocks |
