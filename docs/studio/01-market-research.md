# 1. Market research

Researched 2026-09-29. The full reports, with every source link, are in `docs/research/`:

| Report | File |
|---|---|
| Screen Studio (the product to beat) | `docs/research/competitor-screen-studio.md` |
| Open-source tools: Recordly, OpenScreen ("Open Studio"), Cap, OBS and others | `docs/research/competitors-open-source.md` |
| Commercial tools: After Effects, Camtasia, ScreenFlow, Descript, Tella, Loom, FocuSee, Rotato, CleanShot X and newcomers | `docs/research/competitors-commercial.md` |
| What Klik Studio already has | `docs/research/klik-studio-inventory.md` |

This page is the summary. Feature-by-feature comparison is in `03-feature-list.md`.

## The products

| Product | What it is | Platform | Price | Built with |
|---|---|---|---|---|
| **Screen Studio** | Recorder plus light editor. Sets the look everyone copies: auto zoom, smooth pointer, backgrounds | macOS | $29/month, or $108/year. Subscription only since late 2025 | Electron |
| **Recordly** | Open-source Screen Studio alternative, forked from OpenScreen. Most tunable motion, most open bugs | macOS, Windows, Linux | Free (AGPL) | Electron |
| **OpenScreen** ("Open Studio") | Open-source alternative. Multi-clip timeline, 3D camera, transcript editing | macOS, Windows, Linux | Free (MIT) | Electron plus a native Rust compositor |
| **Cap** | Open-source Loom alternative with a Studio mode. Most complete open-source feature set | macOS, Windows, Linux | Free for personal use; $58 lifetime or $12/user/month for commercial use | Tauri (web view) |
| **OBS Studio** | Recorder and live mixer. No editor at all | All | Free | Native |
| **After Effects** | Motion graphics. No recorder; every zoom is keyframed by hand | macOS, Windows | $22.99/month | Native |
| **Camtasia** | Classic recorder and multitrack editor for training videos | macOS, Windows | $180–$600/year | Native |
| **ScreenFlow** | Classic Mac recorder and multitrack editor | macOS | $199 once | Native |
| **Descript** | Edit video by editing its transcript. Cloud AI | macOS, Windows, web | $16–$65/month plus credits | Electron |
| **Tella** | Recorder, editor and hosting in one. Needs a connection | macOS, Windows, web | $13–$19/user/month | Web |
| **FocuSee** | Closest feature match to Screen Studio, on both platforms | macOS, Windows | $50–$80/year or $200 lifetime | Native |
| **CleanShot X 5** | Screenshot tool that added a Studio Mode in September 2026 | macOS | $35 once | Native |
| **Rotato** | 3D device mockup animator. Not a recorder | macOS | $79–$199 once | Native |

## What each one is known for

**Screen Studio**
- The cursor is recorded as data and drawn afterwards. That is what makes smoothing, resizing and click effects possible.
- Automatic zooms from clicks, with a dedicated zoom timeline.
- iPhone and iPad recording over USB, with device frames.
- Keyboard shortcut overlay, speaker notes, typing speed-up suggestions, click sounds.
- Camera layouts over time (full-screen camera, camera plus screen, hidden).
- On-device captions with karaoke-style word highlight.
- Shareable links with comments (30-minute cap).
- Presets as shareable files.
- **Does not have:** annotations or text, more than one mask, multiple clips, voice-over, transitions, freeze frame, caption styling, ProRes or transparent export, a one-time price.

**Recordly**
- Twelve cursor styles, four click effects, sway and loop.
- "Connect zooms" glides between consecutive zooms; tunable zoom timing and easing.
- Editable caption timeline with SRT/VTT export.
- Video wallpapers, extension marketplace.
- **Does not have:** region recording, webcam background removal, HEVC. Many open data-loss and sync bugs.

**OpenScreen**
- Multi-clip timeline with import.
- 3D camera (tilt, depth of field) and 3D device frames.
- Edit by transcript; webcam background removal; teleprompter.
- Crash-safe recording (one-second fragments).
- Headless command-line tool; AI chat editing with your own key.
- **Does not have:** region recording, SRT export, sharing. Its own audit of v1.13 passed 2 of 10 quality rules.

**Cap**
- Instant mode (upload while recording) and Studio mode.
- Eleven timeline track types, including keyboard, mask, text, image, 3D and style tracks.
- Highlight mask (darken everything else), keystroke overlay, clip transitions.
- Studio Sound noise isolation.
- Hosted links with analytics, self-hosting, S3.
- **Does not have:** HEVC, arrows in video, stable long recordings (cursor drifts after about 5 minutes).

**After Effects**
- What people actually use it for on screen recordings: keyframed zoom and pan, easing curves, motion blur, a 3D camera, device mockups, text animation presets, masks and tracking.
- Why they stop: about 150 hours to learn, every zoom by hand, slow renders, and screen recordings import badly because of variable frame rates.

**Camtasia and ScreenFlow**
- Rich annotations: callouts, arrows, shapes, sketch motion, keystroke callouts, behaviours (enter, during, exit).
- Cursor effects: highlight, magnify, spotlight, custom pointer image.
- Multitrack editing, transitions, templates, libraries, quizzes (Camtasia).
- Weak on automatic polish; users report crashes and slow editing.

**Descript**
- Edit by transcript, filler-word removal, Studio Sound, eye contact, dubbing.
- No cursor effects at all, no auto zoom. Internet required; AI is metered by credits.

**Tella, FocuSee, CleanShot X**
- Tella: multi-clip, captions in 106 languages, hosting and analytics. Cloud only.
- FocuSee: auto zoom on clicks and typing, 3D tilt, full annotation set, spotlight, magnifier.
- CleanShot X: smart zooms and smoothing for $35, but no captions, video blur or per-segment speed.

## What users complain about

The same complaints repeat across every product.

| Complaint | Where it shows up |
|---|---|
| **Subscription price.** "$29/month is extremely expensive" for something used a few times a quarter | Screen Studio, Camtasia, Descript, Tella |
| **Lost recordings.** Takes truncated, hangs on stop, exports that never finish | Recordly, OpenScreen, Cap, Loom, ScreenFlow |
| **Sync drift.** Audio or cursor drifts out of step on long recordings | Recordly, Cap, FocuSee |
| **Preview does not match export.** Rounded corners, resolution, click timing or settings lost on export | Recordly, OpenScreen, Cap |
| **Pointer runs ahead of the picture.** "The hover state of the buttons all change BEFORE the mouse even gets there" | Screen Studio |
| **Auto zoom is dizzying.** Fires on unimportant clicks, too fast, bouncy | Screen Studio, Recordly, OpenScreen |
| **No annotations.** "Not even a freeze frame" | Screen Studio, CleanShot X |
| **Only one mask, and it does not follow scrolling.** Users take the export to another editor to blur more | Screen Studio |
| **Cannot combine recordings.** Top request on Screen Studio's hub (525 + 462 votes) | Screen Studio |
| **No voice-over or audio import** (337 + 319 votes) | Screen Studio |
| **Heavy apps.** Web-view editors use four times the CPU and eight times the memory of a native preview (Cap's own figures) | Screen Studio, Recordly, OpenScreen, Cap |
| **Credits and cloud lock-in** | Descript, FocuSee, Tella |

## Conclusions

1. **The base look is a commodity.** Auto zoom, a smooth pointer, backgrounds and motion blur now ship in a $35 tool and in free apps.
2. **Reliability is the open gap.** Every competitor has open bugs for lost takes, drift, or preview that does not match export. The one user who went back to Screen Studio did so because cheaper tools were buggy.
3. **Editing power is the second gap.** People export to another editor for annotations, extra masks, transitions or a second clip, and lose the pointer polish on the way.
4. **Native and local are advantages we already have.** Klik Studio is a native Swift app that works offline, records each sound to its own file, and uses one renderer for preview and export.
