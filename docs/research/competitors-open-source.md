<!-- Research gathered 2026-09-29 by a research agent; sources are listed at the end. -->

## Key findings

- "Open Studio" is almost certainly **OpenScreen**. The original repo was archived after v1.5.0 (June 2026); development continues at `getopenscreen/openscreen`, latest release v1.13.0 (2026-09-24).
- **Cap** is the most feature-complete open-source tool, but its official builds need a paid licence for commercial use.
- **Recordly** has the most stars among active projects, the most tunable motion system, and the most open bugs.
- **OBS** has no editor at all.
- The main gap across all of them is reliability and sync, not features.

Feature claims come from each project's README, docs, release notes, UI strings and source. Anything I could not confirm is marked *unverified*.

---

## Recordly

- **What it is:** Desktop screen recorder and editor. Started as an OpenScreen fork; README says "Over 80% of code has diverged since".
- **Repo / site:** `github.com/webadderallorg/Recordly` (`webadderall/Recordly` redirects), recordly.dev.
- **Platforms:** macOS 14+, Windows 10 build 19041+, Linux.
- **License / price:** AGPL-3.0 with attribution and branding conditions. Free, no paid tiers, Ko-fi donations.
- **Tech stack:** Electron 43, React 19, TypeScript, PixiJS 8. Native Swift ScreenCaptureKit helper (macOS), native WGC + WASAPI helpers (Windows), Electron capture on Linux. ffmpeg-static, mediabunny, Whisper, optional NVIDIA CUDA compositor.
- **Maturity:** 31,781 stars, 2,525 forks. Created 2026-03-12. Latest stable v1.4.0 (2026-09-08). 245 open / 230 closed issues. Release notes describe a solo maintainer working in free time.

### Feature inventory

**Recording**
- Entire display or single window (Windows window capture arrived in v1.4.0). No region capture.
- Microphone and system audio; webcam with floating live preview.
- Countdown delay, pause/resume/cancel, option to hide the HUD from the recording.
- Custom recordings folder; open an existing video or project.

**Cursor**
- Rendered overlay with show/hide, size, smoothing, and spring stiffness/damping/mass.
- Motion blur, click bounce with bounce speed, sway, loop cursor.
- Styles: macOS, Tahoe (default), Tahoe Inverted, Windows 11, Windows 10, Dot, Minimal, Lavender, Parched, Chooper, Among Us, Turtle.
- Click effects: Off / Ripple / Spotlight / Echo, with colour, size, opacity and duration.
- Linux cannot hide the real cursor, so exports can show two cursors.

**Zoom**
- Six manual depths: 1.25×, 1.5×, 1.8× (default), 2.2×, 3.5×, 5×.
- Auto suggestions from cursor telemetry; optional auto-apply on fresh recordings.
- Per-zoom mode: Manual (fixed focus) or Auto (recentres when the cursor nears the edge).
- "Connect Zooms" glides between consecutive regions.
- Tunable zoom-in/out duration, overlap and easing (Recordly, Glide, Smooth, Snappy, Linear).
- Motion presets "Focused" and "Smooth"; zoom motion blur.

**Camera**
- Bubble overlay with size, width/height, crop, mirror, roundness, shadow, margin.
- Nine preset positions plus custom X/Y; optional zoom-reactive scaling.
- Upload, replace or remove webcam footage.
- No webcam background blur or removal. The "Remove background" toggle only strips the styled backdrop.

**Audio**
- Separate system and mic source tracks; mute clip; separate clip from audio.
- Volume and Normalize; imported audio regions; waveforms on clips.

**Captions**
- On-device Whisper with downloadable model and language selection.
- Styling: font, size, rows, animation (Off/Fade/Rise/Pop), bottom offset, max width, box radius, background opacity, text colour.
- Editable caption timeline (text, start, end, split, merge, delete).
- SRT/VTT sidecar export (added in the 1.3.4/1.3.5 betas).

**Timeline editing**
- Drag-and-drop regions, trims, clip split, clip reorder, crop, undo/redo.
- Speed options 0.25×, 0.5×, 0.75×, 1.25×, 1.5×, 1.75×, 2×.
- Snapping within 8 px; mouse scrubbing.

**Annotations / text**
- Text with 8 font styles, bold/italic/underline, alignment, colour, background.
- Image (JPG/PNG/GIF/WebP); arrow in 8 directions with stroke width and colour.
- Blur with strength, plus a solid-colour censorship mode.

**Backgrounds and styling**
- Built-in wallpapers, custom upload, solid colour, gradient, video wallpapers.
- Background blur, per-side padding, rounded corners, shadow.
- Aspect ratios: native, 16:9, 9:16, 1:1, 4:3, 4:5, 16:10, 10:16, custom.

**Export**
- MP4 at 24/30/60 fps with quality tiers and encoding modes.
- GIF at 15/20/25/30 fps, three size presets, loop toggle.
- "Lightning" pipeline claimed "up to 15x faster" than the legacy one.
- No HEVC or ProRes found in the code (*unverified*).

**Sharing**
- Not shipped. On `main`: Supabase sign-in plus a "Recordly Share" worker with 1080p links, timestamped comments, passwords, expiry.
- Its own docs state: "Production service integration is planned but is not selected by any build."

**Presets / projects**
- `.recordly` project files; save/load presets (v1.3.0); project library.

**Other**
- Extension system and marketplace (render hooks, cursor effects, frames, wallpapers, sounds).
- Custom shortcuts, 11 UI locales, experimental update channel, light/dark theme.

### Known bugs, limitations, requests

| Area | Issue |
|---|---|
| Export fails ("Failed to fetch", Windows) | https://github.com/webadderallorg/Recordly/issues/328 |
| Export never finishes | https://github.com/webadderallorg/Recordly/issues/653 |
| Only about half the recording reaches the editor | https://github.com/webadderallorg/Recordly/issues/375 |
| Hangs after 80+ minutes, recording lost | https://github.com/webadderallorg/Recordly/issues/673 |
| No mic audio on macOS 15, helper crashes | https://github.com/webadderallorg/Recordly/issues/253 |
| Echoed audio | https://github.com/webadderallorg/Recordly/issues/662 |
| Exported video has no sound (v1.4.0) | https://github.com/webadderallorg/Recordly/issues/982 |
| System audio out of sync past 1–2 minutes | https://github.com/webadderallorg/Recordly/issues/997 |
| Audio drift on long demos (closed) | https://github.com/webadderallorg/Recordly/issues/252 |
| Clicks out of sync in export only | https://github.com/webadderallorg/Recordly/issues/234 |
| Rounded corners ignored in export | https://github.com/webadderallorg/Recordly/issues/508 |
| 4K source exports at 1080p | https://github.com/webadderallorg/Recordly/issues/639 |
| Speckle artifacts at 1440p | https://github.com/webadderallorg/Recordly/issues/350 |
| Cuts reappear when clips are moved | https://github.com/webadderallorg/Recordly/issues/922 |
| Delete does not really delete | https://github.com/webadderallorg/Recordly/issues/526 |
| Speed changes scramble the timeline | https://github.com/webadderallorg/Recordly/issues/680 |
| Cursor offset in window recordings | https://github.com/webadderallorg/Recordly/issues/503 |
| Both real and rendered cursor visible on Windows | https://github.com/webadderallorg/Recordly/issues/634 |
| Linux cursor following broken (13 reactions) | https://github.com/webadderallorg/Recordly/issues/34 |
| Hyprland unsupported (11 reactions) | https://github.com/webadderallorg/Recordly/issues/638 |
| Too many auto zooms, "bouncing" | https://github.com/webadderallorg/Recordly/issues/548 |
| Caption generation fails | https://github.com/webadderallorg/Recordly/issues/220 |

- **macOS signing:** the v1.3.5-beta.2 notes say macOS installers were omitted because "Apple notarization credentials are currently unavailable". Manual installs require re-granting permissions.
- **Most requested:**
  - Homebrew: https://github.com/webadderallorg/Recordly/issues/171
  - Webcam background blur: https://github.com/webadderallorg/Recordly/issues/186
  - Region recording: https://github.com/webadderallorg/Recordly/issues/126
  - Teleprompter: https://github.com/webadderallorg/Recordly/issues/218
  - Second video track: https://github.com/webadderallorg/Recordly/issues/323
  - Keystroke overlay: https://github.com/webadderallorg/Recordly/issues/969
  - Freeze frame: https://github.com/webadderallorg/Recordly/issues/920
  - Click and typing sounds: https://github.com/webadderallorg/Recordly/issues/443
  - Pixelate: https://github.com/webadderallorg/Recordly/issues/701
- **Unverified third-party claim:** a competitor blog (ScreenKite) alleges governance and funding problems. I found no primary source for this.

---

## OpenScreen ("Open Studio")

- **What it is:** Two repos.
  - Original `siddharthvaddem/openscreen`: archived, 39,961 stars, final release v1.5.0 (2026-06-06).
  - Continuation `getopenscreen/openscreen`: 3,330 stars, 30 open / 184 closed issues, releases every one to two weeks.
- **Platforms:** macOS 13+ (Apple Silicon and Intel), Windows 10 1903+ x64, Linux x64.
- **License / price:** MIT. Free including commercial use, no account.
- **Tech stack:** Electron + React/TypeScript UI. Since v1.8.0, a native Rust GPU compositor shared by preview and export (Direct3D 11, Metal, wgpu). whisper.cpp for speech, ONNX Runtime for webcam segmentation.
- **Release status:** the "v2" integration branch merged into `main` on 2026-09-27 but is unreleased. Docs on `main` partly describe v2.

### Feature inventory (v1.13.0 unless noted)

**Recording**
- Whole screen or a window; no region capture ("crop afterwards").
- macOS 15.2+ uses Apple's system picker; Linux uses the portal dialog on every take.
- System audio, mic with live level meter, webcam as a separate track.
- 3-2-1 countdown, pause/resume, restart, cancel.
- Cursor mode: editable overlay (default) or system cursor.
- Fragmented MP4 in one-second fragments for crash safety (Windows, macOS).
- Notes window with teleprompter mode, excluded from capture (not on Linux).

**Cursor**
- Show/hide, auto-hide when idle, hide during zoom.
- Size, smoothing, motion blur, click bounce, "click impact".
- Cursor themes and a modelled 3D cursor.
- Clicks need Accessibility on macOS and the `input` group on Linux.

**Zoom**
- Auto zoom runs after every take; deterministic rule over recorded clicks, no AI.
  - Clicks under 3 s apart share a zoom.
  - Auto depth is 1.25×, 1.5× or 1.8×.
  - First 2.5 s and last 1 s stay wide.
- Manual depths: 1.25×, 1.5×, 1.8×, 2.2×, 3.5×, 5×.
- Focus manual or follow-cursor; global auto-focus toggle.
- 3D camera: tilt left/right, follow-cursor camera, depth of field.

**Camera**
- Layouts: picture-in-picture, vertical stack, dual frame, none.
- Rectangle or square shape, roundness, size, eight snap positions, mirror, shrink on zoom.
- Webcam crop and gain.
- On-device background removal, blur, or replacement (v1.11.0).
- "Full Camera" timeline segments.

**Audio**
- Output level; imported music lanes; voice-over recorded on the timeline.
- No noise removal (planned).

**Captions**
- On-device whisper.cpp, about 264 MB model, 100 languages.
- Captions are a live view of the transcript.
- Styling: font, size, bold, colour, background, position, words per line.
- Translation to 15 languages through your own LLM key.
- Burned in only; no SRT/VTT.
- Transcript editing: delete words to cut video; silences are marked.

**Timeline editing**
- Multi-clip timeline; import webm, mp4, mov, avi, mkv, m4v, wmv, flv, ts.
- Per-clip crop and in/out points; trims; snapping; undo/redo.
- Speed regions. Its comparison pages say 0.1×–100×; docs on `main` say 0.25×–16×.

**Annotations**
- Text with sizes, background and animations (Fade, Rise, Pop, Slide Left, Typewriter, Pulse).
- Image; arrow in 8 directions with stroke 1–20.
- Blur mask: smooth or mosaic, rectangle or oval.

**Backgrounds and styling**
- Wallpapers, colour, gradient with custom editor, own image.
- Background blur, shadow, padding, roundness.
- Formats: Auto, Original, 16:9, 9:16, 1:1, 4:3, 4:5, 16:10, 10:16.
- 3D device frames: laptop, phone, browser, monitor.
- Animated backgrounds (Drift, Aurora, Waves) appear in docs on `main`; release status *unverified*.

**Export**
- MP4 at 720p, 1080p or Source; 24/30/60 fps; H.264 or H.265.
- GIF at 15/20/25/30 fps.
- Hardware encoders with CPU fallback; Linux H.265 is always software.
- Project claims about 126 fps vs about 8 fps export after the v1.8.0 rewrite.

**Sharing**
- None.

**Presets / projects**
- `.openscreen` project files; style presets as shareable files (v1.12.0).

**Other**
- AI chat editing with your own key (Claude, OpenAI, Gemini, Mistral, OpenRouter, MiniMax, OpenAI-compatible); off by default.
- Headless CLI: `record`, `sources`, `export`, `captions`, `pack`, `info`.
- 15 UI languages; auto-updates.
- Notarized macOS builds since 1.9.0; Microsoft Store build; the standalone `.exe` is unsigned.

### Known bugs, limitations, requests

| Area | Issue |
|---|---|
| Windows recorder hangs on stop, 0-byte file | https://github.com/getopenscreen/openscreen/issues/252 |
| macOS: 23-minute take produced a 74-second file while the timer kept running | https://github.com/getopenscreen/openscreen/issues/621 |
| Linux niri/Wayland records nothing | https://github.com/getopenscreen/openscreen/issues/324 |
| AppImage PipeWire failure | https://github.com/getopenscreen/openscreen/issues/646 |
| Invalid H.264 on GNOME/AMD | https://github.com/getopenscreen/openscreen/issues/615 |
| Game recordings stutter | https://github.com/getopenscreen/openscreen/issues/510 |
| Unwanted zooms when dragging sliders | https://github.com/getopenscreen/openscreen/issues/725 |
| "Zoom movement too fast" | https://github.com/getopenscreen/openscreen/issues/683 |
| Cannot disable auto-enhance | https://github.com/getopenscreen/openscreen/issues/723 |
| Text animation renders inconsistently in preview | https://github.com/getopenscreen/openscreen/issues/742 |
| Poor audio quality, no audio settings, high AI token use | https://github.com/getopenscreen/openscreen/issues/677 |
| iPhone not listed as a source | https://github.com/getopenscreen/openscreen/issues/117 |
| Live annotation while recording | https://github.com/getopenscreen/openscreen/issues/277 |

- **Self-audit of v1.13.0** (maintainer's own v2 blog post): two of ten quality rules passed.
  - Default cursor about four times system size.
  - Default shadow at 9% opacity.
  - Every export ran at 8 Mb/s regardless of settings.
  - All text exported as Segoe UI.
  - Gradients used only their first and last stops.
  - A 16:9 take in 9:16 filled 20% of the frame.
  - The project still calls itself "not production-grade".
- **Original repo history:**
  - Recordings over about 10 minutes silently failed: https://github.com/siddharthvaddem/openscreen/issues/616
  - Slow exports: https://github.com/siddharthvaddem/openscreen/issues/157
  - Blurry exports: https://github.com/siddharthvaddem/openscreen/issues/136
  - Most-reacted request, mouse and keyboard highlighting (13): https://github.com/siddharthvaddem/openscreen/issues/41
- **Hacker News (434 points, 73 comments):** constant zooming called "dizzying"; requests for a zoom slider, click highlighting, callouts, freeze frame.

---

## Cap

- **What it is:** "Open source alternative to Loom" with a Screen Studio-style Studio Mode. Two modes: Instant (upload while recording) and Studio (local edit). cap.so.
- **Platforms:** macOS (13.1+ recommended), Windows (labelled "Beta" on the download page), Linux packages since 0.6.0.
- **License / price:** AGPLv3, with MIT for the camera and capture crates.
  - Official builds are free for personal use only. Commercial use includes "communication between team members".
  - Desktop License $29/year or $58 lifetime; Cap Pro $12/user/month ($8.16 annual).
  - Self-compiled builds are exempt.
  - Quickstart tells users to sign in; whether purely local Studio use requires it is *unverified*.
- **Tech stack:** Rust + Tauri v2 + SolidStart desktop; Next.js web. An experimental fully native GPUI app ships in 0.6.0.
- **Maturity:** 22,921 stars, created 2023-11. Desktop 0.6.0 (GitHub release 2026-09-15; changelog dates it Aug 31). 202 open / 567 closed issues.

### Feature inventory

**Recording**
- Display, window, area (aspect presets, lockable region), camera-only.
- Native resolution up to 4K.
- 30/60/120 fps plus 24/25; capped to 30 fps when the camera overlay is active.
- Countdown 0/3/5/10 s; pause/resume.
- Quality profiles Compatibility / Balanced / Ultra.
- Excluded-windows picker; record a new clip into an open project.
- Built-in teleprompter; warning before recording without a mic.
- Disk-space protection and fragment recovery.

**Cursor**
- Types Auto / Pointer / Circle; macOS, Tahoe, Windows and circle styles.
- Click ripples and click spring.
- Smoothing presets Slow / Smooth / Mellow / Fast / custom.
- Size, tilt, motion blur, hide when idle, per-clip hide.
- Cursor-only transparent ProRes 4444 MOV export.

**Zoom**
- Auto zooms from recorded clicks; manual 1×–4.5×.
- Focus follows the smoothed cursor path; default zoom strength; multi-select.
- 3D tracks: automatic or custom camera shots with perspective, easing, focus blur.

**Camera**
- Circle by default; square or source shapes.
- 9-point positioning, size, mirror, rounding, shadow, scale during zoom.
- Scene modes: Default, Camera Only, Hide Camera, Split Screen, Floating.
- Background blur (0.5.0) and background removal (0.6.0, macOS only).

**Audio**
- Separate mic and system tracks with gain.
- Music tracks and bundled audio library.
- Studio Sound noise isolation (Light / Balanced / Strong).
- Per-clip volume and mute; pitch options for retimed clips.

**Captions**
- On-device Whisper and Parakeet (Parakeet unavailable on Intel Macs), labelled beta.
- Caption track in timeline; word-level transcript editor with ripple delete.
- Styling includes active-word highlight and animations; drag positioning.
- SRT/VTT export.

**Timeline editing**
- Tracks: clips, zoom, scene, mask, text, captions, keyboard, style, image, 3D, audio.
- Split, merge, reorder; clip transitions (crossfade, fade through black).
- Speeds 0.25×–8× per Studio docs (`llms-full.txt` says 0.25×–3×).
- Minimap, snapping, right-click clip menu.

**Annotations / text**
- Animated text layers and full-screen title cards.
- Image tracks for logos.
- Masks: Sensitive (blur or pixelate) and Highlight (darken everything else).
- Keyboard press overlay as an editable track.
- Arrows and shapes exist only in the screenshot editor.

**Backgrounds and styling**
- Desktop snapshot, wallpapers, image, colour with alpha, gradient, animated gradients.
- Background blur, padding, rounded corners, border, shadow, inset.
- Frames: macOS or Windows window, browser chrome with editable URL, MacBook bezel.
- MacBook notch overlay; colour correction.
- Style tracks change look for part of a video.

**Export**
- MP4 at 720p/1080p/4K, 15/30/60 fps, H.264 only.
- Quality presets, custom bits per pixel, measured size and time estimates.
- GIF at 720p/1080p, 10–30 fps.

**Sharing**
- Hosted links, comments, reactions, analytics, passwords, embeds, custom domain.
- Free and Desktop License links limited to 5 minutes.
- Own S3 or Google Drive; full self-hosting.

**Presets / projects**
- `.cap` projects; style presets; organisation branding.

**Other**
- CLI with JSON output, local MCP server, agent skill.
- Desktop automations (webhooks, commands); screenshot editor with OCR.
- Loom importer; Chrome extension.

### Known bugs, limitations, requests

| Area | Issue |
|---|---|
| Flickering and laggy renders (10 reactions) | https://github.com/CapSoftware/Cap/issues/1557 |
| Export flicker and stuck frames on macOS | https://github.com/CapSoftware/Cap/issues/1787 |
| Cursor drifts out of sync past about 5 minutes | https://github.com/CapSoftware/Cap/issues/2144 |
| Recording stops mid-way | https://github.com/CapSoftware/Cap/issues/2055 |
| Window capture records the screen region instead | https://github.com/CapSoftware/Cap/issues/1754 |
| CPU and memory while recording (open since 2024) | https://github.com/CapSoftware/Cap/issues/109 |
| About 15 GB RAM (closed) | https://github.com/CapSoftware/Cap/issues/1589 |
| Captions track longer than edited video | https://github.com/CapSoftware/Cap/issues/1689 |
| Split lands wrong after a speed change | https://github.com/CapSoftware/Cap/issues/1445 |
| Jumpy follow-zoom in 9:16 | https://github.com/CapSoftware/Cap/issues/1401 |
| No HEVC (open since 2024) | https://github.com/CapSoftware/Cap/issues/192 |
| Slow 4K export, no raw export | https://github.com/CapSoftware/Cap/issues/703 |
| Custom cursor assets, per-segment cursor | https://github.com/CapSoftware/Cap/issues/1463 |
| Click sound | https://github.com/CapSoftware/Cap/issues/527 |
| Recording profiles | https://github.com/CapSoftware/Cap/issues/856 |
| Multi-window recording, layered overlays | https://github.com/CapSoftware/Cap/issues/2150 |
| Simplified Chinese | https://github.com/CapSoftware/Cap/issues/1418 |

- Cap's own numbers for the webview app during playback: 76.6% CPU and 3,724 MiB, against 17.5% and 440 MiB in the native preview.

---

## OBS Studio

- **What it is:** Free recorder and live-streaming mixer. obsproject.com.
- **License / stack:** GPL-2.0, C/C++/Qt.
- **Maturity:** 76,750 stars. v32.2.2 (2026-08-14); 33.0.0-beta4 (2026-09-25).
- **Platforms:** Windows 10/11, macOS, Linux. 32.2 dropped macOS 12, though the homepage still lists it.

**What it offers for tutorials**
- Unlimited scenes built from display, window, application, webcam, image, text and browser sources.
- macOS Screen Capture source on ScreenCaptureKit, with audio on macOS 13+ and a "Show cursor" toggle.
- Audio mixer with noise gate, noise suppression, gain, compressor, VST.
- Video filters: crop/pad, colour correction, LUT, chroma key, image mask, scaling, sharpen.
- Codecs H.264, HEVC, AV1, ProRes; crash-recoverable Hybrid MP4/MOV by default.
- Hotkeys, plugins, Lua/Python scripts, WebSocket control.

**What it lacks for polished product videos**
- No editor or timeline: no trim, cut, speed or captions editing.
- Cursor is baked into pixels, so no smoothing, resizing, or click effects afterwards.
- No automatic zoom. The community "Zoom to Mouse" script is hotkey-triggered and live only. It was last updated Nov 2023 and reportedly needs manual fixes on OBS 32+.
- No built-in rounded corners, drop shadow, or framing preset; these need plugins.
- Built-in captions tool is Windows-only.
- Resolution, frame rate and encoder are fixed before recording.

**Known issues**
- Wayland explicit-sync crash (20 reactions): https://github.com/obsproject/obs-studio/issues/11022
- macOS capture freezing after hours: https://github.com/obsproject/obs-studio/issues/9056
- macOS capture freezes randomly: https://github.com/obsproject/obs-studio/issues/11435
- macOS Sonoma capture performance: https://github.com/obsproject/obs-studio/issues/10636
- Preview stutter in recordings (184 comments): https://github.com/obsproject/obs-studio/issues/4191
- Random audio dropouts: https://github.com/obsproject/obs-studio/issues/4600

---

## Other notable tools

| Tool | Stack / license | Status | Notable |
|---|---|---|---|
| Capptivo | Tauri + Rust, MIT | 1,031 stars, v1.0.3 (2026-08-05) | Live drawing while recording, area capture, click-suggested zooms, named presets, MP4/WebM/GIF. Unsigned builds; captions need a system `whisper-cli` |
| Screenize | Swift, Apache-2.0 | 604 stars, paused 2026-05-22 | Per-activity zoom planning (typing, clicking, scrolling, dragging), keystroke overlays, ProRes, up to 4K/240 fps. Not notarized |
| Reframed | Swift, MIT | 163 stars, v0.14.7 (2026-04-16), macOS 15+ | iOS device capture over USB, 120 Hz cursor tracking, RNNoise, 30 click sounds, spotlight, webcam background replacement, HEVC/ProRes |
| Open Recorder | Swift + Rust, Apache-2.0 | 87 stars, v0.2.50 (2026-09-08), macOS only | Adaptive auto zoom, camera layouts, screenshot editor |
| Kap | Electron, MIT | 19,378 stars, last release 2022 | GIF/MP4/WebM/APNG, click highlight, trimming, plugins. No zoom, smoothing or backgrounds |
| QuickRecorder | Swift, AGPL-3.0 | 8,677 stars, v1.6.9 (2025-06) | Recorder only: app and iPhone/iPad capture, driver-free audio loopback, HEVC with alpha |
| Open Screen (openscreen.io) | Swift, MIT per its site | *Unverified*; linked repo returned 404 | Site claims FCPXML/Premiere export and an MCP server |

Smaller projects seen but not evaluated: Beam (48 stars), Focra (33), Focuso, dolly.

---

## Cross-product summary

Y = shipped; P = partial or buggy; N = absent or not documented; ? = unverified.

| Feature | Recordly 1.4.0 | OpenScreen 1.13.0 | Cap 0.6.0 | OBS 32.2 |
|---|---|---|---|---|
| License | AGPL-3.0 | MIT | AGPLv3 | GPL-2.0 |
| Official builds free for commercial use | Y | Y | N | Y |
| UI technology | Electron | Electron + native compositor | Tauri webview | Native Qt |
| Display / window capture | Y | Y | Y | Y |
| Region capture | N | N | Y | Y (crop) |
| iPhone/iPad capture | N | N | ? | ? |
| Pause / resume | Y | Y | Y | ? |
| Cursor editable after recording | Y (not Linux) | Y | Y | N |
| Cursor smoothing | Y | Y | Y | N |
| Click visual effects | Y | Y | Y | N |
| Click sounds | P (extension) | N | N | N |
| Auto-hide idle cursor | ? | Y | Y | N |
| Auto zoom | Y | Y | Y | N |
| Manual zoom range | 1.25–5× | 1.25–5× | 1–4.5× | Script only |
| 3D camera | N | Y | Y | N |
| Webcam overlay | Y | Y | Y | Y |
| Webcam background blur/removal | N | Y | Y (removal macOS only) | ? |
| Full-screen camera / split | N | Y | Y | Y (scenes) |
| Mic noise removal | N | N | Y | Y |
| Music tracks | Y | Y | Y | N |
| On-device captions | Y | Y | Y (beta) | P |
| SRT/VTT export | Y | N | Y | ? |
| Edit by transcript | N | Y | Y | N |
| Multi-clip timeline | P | Y | Y | N |
| Max speed | 2× | 100× | 8× | N |
| Clip transitions | N | N | Y | N |
| Text / image annotations | Y | Y | Y | Live sources |
| Arrows | Y | Y | N | N |
| Blur / pixelate mask | Y (blur) | Y | Y | N |
| Highlight mask | N | N | Y | N |
| Keystroke overlay | N | N | Y | N |
| Animated backgrounds | Y (video) | ? | Y | Manual |
| Device / browser frames | P (extensions) | Y | Y | N |
| Motion blur | Y | Y | Y | N |
| MP4 + GIF export | Y | Y | Y | N |
| HEVC export | N? | Y | N | Y |
| 4K export | P | Y (Source) | Y | Y |
| Hosted share links | N | N | Y | N |
| Style presets | Y | Y | Y | Profiles |
| CLI | N | Y | Y | Y (WebSocket) |
| AI chat editing | N | Y | N | N |
| Plugins | Y | N | N | Y |
| Teleprompter | N | Y | Y | N |

### The gap: what no open-source tool does well

1. **Reliable capture to export.** Every project has open data-loss bugs: truncated takes, hangs on stop, exports that never finish. The details are in each bug table above.
2. **Sync on long recordings.** Audio drift and echo in Recordly, cursor drift in Cap, audio quality complaints in OpenScreen.
3. **Preview equals export.** Recordly loses rounded corners, resolution and click timing on export; Cap shows stuck frames; OpenScreen's audit found settings that never reached the encoder.
4. **Calm auto-zoom.**
   - Every shipped implementation is a click or dwell heuristic.
   - Users call the result bouncy, too fast, or dizzying.
   - None of the three main tools handles typing, scrolling or dragging well in a shipped build.
   - The one project that tried per-activity planning (Screenize) is paused.
5. **Native macOS performance.** The three main tools render UI in a webview. Cap's own figures show a fourfold CPU and eightfold memory difference against its native preview. The native Swift projects are small or paused.
6. **Automatic pacing without an LLM key.** Screen Studio lists "speed up typing". No open-source tool ships automatic idle or typing speed-up; OpenScreen's "Smart cuts" needs your own API key.
7. **Keystroke overlays and click sounds in a permissive, maintained app.** Only Cap ships keystroke overlays. Click sounds exist only in Reframed and as a Recordly extension with open export-parity issues.
8. **Vertical reframing.** OpenScreen shipped a stretched 9:16 export bug and a 20% frame fill; Cap's 9:16 follow-zoom is jumpy.
9. **Editor basics.** Ripple delete and gap handling are broken in Recordly. Freeze frames exist nowhere. Multi-source recording and layered overlays are requests only.
10. **Signed installs with stable permissions.** Recordly lost notarization for a beta, Capptivo and Screenize are unsigned, and OpenScreen's Windows installer is unsigned.
11. **Device capture with frames, and region capture.** iPhone/iPad capture exists only in Reframed and QuickRecorder. Recordly and OpenScreen cannot record a region.
12. **Free sharing.** Only Cap has hosted links, capped at 5 minutes unless you pay. Recordly's is unshipped.

Third-party data point: an export benchmark published by OpenScreen's own maintainer (52 runs, 3 machines) gives cost relative to plain ffmpeg as OpenScreen 1.22×, Cap 3.59×, FocuSee 4.27×, Screen Studio 4.68× (one submission), Recordly 8.03×. It warns of very high variance between machines. Treat it as indicative.

---

## Sources

**Recordly**
- https://github.com/webadderallorg/Recordly (README, `LICENSE.md`, `EXTENSIONS.md`, `package.json`, `docs/cloud-sharing.md`, `docs/authentication.md`, `docs/timeline-sequence.md`, `services/recordly-share/worker/README.md`, `src/i18n/locales/en/*.json`, `src/components/video-editor/types.ts`, `SettingsPanel.tsx`, `src/lib/exporter/types.ts`, `src/utils/aspectRatioUtils.ts`)
- https://github.com/webadderallorg/Recordly/releases
- https://github.com/webadderallorg/Recordly/issues (issues linked above, plus 135, 181, 194, 319, 581, 792, 1010)
- https://www.recordly.dev and https://www.recordly.dev/blog
- https://marketplace.recordly.dev/extensions (HTTP 525, not read)

**OpenScreen**
- https://github.com/siddharthvaddem/openscreen (README, releases, issues 41, 82, 136, 157, 269, 602, 616)
- https://github.com/getopenscreen/openscreen (README, `ROADMAP.md`, releases v1.6.0–v1.13.0, PR 814, issues linked above plus 670, 874)
- Repo files under `website/docs/` (recording, editing-timeline, export, captions, ai-editing, faq, media-library, cli), `website/src/pages/` (alternatives/screen-studio, compare/openscreen-vs-cap, compare/openscreen-vs-obs, features/auto-zoom), and two `website/blog/` posts
- https://getopenscreen.com/ and https://getopenscreen.com/docs/intro/
- https://etiennelescot.github.io/screen-recorder-benchmark/
- https://news.ycombinator.com/item?id=47595695

**Cap**
- https://github.com/CapSoftware/Cap (README, releases 0.4.5–0.6.0, `apps/web/content/blog/cap-v06.mdx`, issues linked above plus 352, 1740, 1961)
- https://cap.so/pricing, https://cap.so/docs, https://cap.so/docs/recording/studio-mode, https://cap.so/docs/recording/camera-and-mic, https://cap.so/docs/quickstart, https://cap.so/docs/commercial-license, https://cap.so/download, https://cap.so/features/studio-mode, https://cap.so/changelog, https://cap.so/llms-full.txt

**OBS**
- https://github.com/obsproject/obs-studio (releases 32.0.0–33.0.0-beta4, issue lists)
- https://obsproject.com/, https://obsproject.com/kb/obs-studio-overview, https://obsproject.com/kb/macos-screen-capture-source, https://obsproject.com/kb/filters-guide, https://obsproject.com/kb/audio-video-formats-guide
- https://obsproject.com/forum/resources/zoom-to-mouse.1823/

**Others**
- https://github.com/syi0808/screenize, https://github.com/SECHAK-AG/capptivo, https://github.com/jkuri/Reframed, https://github.com/imbhargav5/open-recorder, https://github.com/wulkano/Kap, https://github.com/lihaoyun6/QuickRecorder
- https://getkap.co/, https://lihaoyun6.github.io/quickrecorder/, https://openscreen.io/
- https://github.com/topics/screen-studio
- https://screen.studio/llms.txt (baseline for the gap analysis)
- https://note.com/yoidoreo/n/n0a6f92ed5e9a?hl=en, https://deepakness.com/raw/recordly/
