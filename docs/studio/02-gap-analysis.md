# 2. Gap analysis

Two questions are answered here:

1. **Where is the market's real gap?** What do users keep asking for that nobody delivers well?
2. **Where is Cue Studio's gap?** What do competitors have that we do not?

Demand figures are vote counts from Screen Studio's public feature hub (296 requests), plus issue trackers and forum threads. Sources are in `docs/research/`.

## Part A: the market's gaps, ranked

Score = user demand (1–5) × how poorly competitors serve it (1–5).

| Rank | Gap | Evidence of demand | How competitors serve it today | Score | Cue Studio today |
|---|---|---|---|---|---|
| 1 | **Blur that follows content.** A mask that stays on the email address while the page scrolls | 568 + 147 votes; users re-edit exports elsewhere to blur more | Static masks everywhere. Screen Studio allows one mask, and it fades in, briefly exposing the data | 25 | Several blurs at once, already. They do not follow content yet. The model has a "stick to content" flag that nothing draws |
| 2 | **Reliability.** No lost takes, no drift, no export surprises | Open data-loss bugs in every open-source tool; crash complaints for every paid one | Nobody is praised for it | 20 | Strong base: one clock, one renderer, separate audio files. Pointer sync is now measured (see `06-quality-log.md`). Recording is not crash-safe yet |
| 3 | **Annotations and callouts** | 246 + 222 + 312 votes; "paused" on Screen Studio's roadmap for 3 years | Strong only in Camtasia, ScreenFlow and FocuSee | 20 | Text, arrow and box with animation. No ellipse, highlight, spotlight, numbered steps or freehand |
| 4 | **Several clips in one project, with the polish kept** | 525 + 462 + 479 votes (the top three requests) | Tella, OpenScreen and Cap have it. Camtasia loses its styling when unpacked | 15 | One recording per project. Footage can be cut, copied and pasted inside it |
| 5 | **Pointer that matches the picture** | "Hover states change BEFORE the mouse gets there"; click sync bugs in Recordly and Cap | Nobody addresses it | 12 | Fixed and measured: 0 to 5 ms (see `06-quality-log.md`) |
| 6 | **Editing by transcript, silence and filler removal, on the Mac** | 175 + 154 votes | Descript and Tella do it in the cloud, metered by credits | 12 | Captions exist. No transcript editing |
| 7 | **Interactive demo or guide from the same recording** | Embed 50 votes | Demo tools export weak video; polish tools export no demo | 12.5 | Not planned yet |
| 8 | **Working with pro editors.** Transparent video, pointer-only export, separate tracks | 148 votes (rejected by Screen Studio) | Cap, Rotato, ScreenFlow in part | 10.5 | Separate audio files already. No ProRes or transparency |
| 9 | **Voice-over and audio import** | 337 + 319 votes | Classic editors and Descript | 10 | Have both |
| 10 | **Transitions, title slides, enter and exit animations, freeze frame** | 312 + 124 + 479 votes | FocuSee, Tella, Cap | 10 | Annotation animations only |
| 11 | **Pricing for occasional users** | The loudest complaint of all | One-time prices are now common | 10 | A pricing decision, not a build task |
| 12 | **Calm, controllable auto zoom** | "Distracting and almost dizzying" | Only Cursorful's "two clicks before zooming" rule | 9 | Click grouping, dead-zone camera and steadiness controls. Typing and scrolling are not used |
| 13 | **Local and private** | "Running locally is a must" | Mac-native tools are local; Tella, Descript and Loom are not | 8 | Fully local |
| 14 | **Captions: styling, languages, subtitles without a voice** | 102 votes | Tella and FocuSee are strong | 7.5 | One style, system language only |
| 15 | **Brand kits and presets** | 88 votes for a logo watermark | Presets exist; brand kits cost extra | 7.5 | Defaults in Settings. No saved presets, no logo |

### What this means for Cue Studio

Three themes cover most of the list:

- **Trust.** Ranks 2 and 5. A recording that is always complete, in sync, and exported exactly as previewed. This is the product's edge, and it has to be proven by measurement, not claimed.
- **Enough editing that nobody has to leave.** Ranks 1, 3, 4, 10. Blur that tracks, real annotations, several clips, transitions.
- **Local intelligence.** Ranks 6, 12, 14. Transcript editing, silence removal and calmer zoom, all on the Mac with no credits.

## Part B: Cue Studio's gaps against competitors

Features that at least one main competitor ships and Cue Studio does not. Grouped by how much they matter.

### Must have for parity with Screen Studio

| Feature | Who has it |
|---|---|
| Keyboard shortcut overlay | Screen Studio, Cap, FocuSee, Camtasia, ScreenFlow |
| Pointer hides when idle | Screen Studio, OpenScreen, Cap |
| Click sounds | Screen Studio, ScreenFlow |
| Pointer styles (sets) | Screen Studio, Recordly, Cap |
| Camera layouts over time (full-screen camera, hidden) | Screen Studio, OpenScreen, Cap |
| Camera background blur or removal | OpenScreen, Cap, Screen Studio beta |
| Voice clean-up (noise reduction, levelling) | Screen Studio, Cap, Camtasia, Descript |
| Captions lane with timing edits; SRT and VTT export | Recordly, Cap, ScreenFlow |
| Caption styling and word highlight | Screen Studio, Recordly, Cap, OpenScreen |
| Saved style presets | Screen Studio, Recordly, OpenScreen, Cap |
| Typing speed-up suggestions | Screen Studio |
| Highlight mask (dim everything else) | Screen Studio, Cap |
| Instant zoom, "keep zoomed in", glide between zooms | Screen Studio, Recordly |
| More aspect ratios (4:5, 3:4, 16:10, custom) | Screen Studio, Recordly, OpenScreen |
| Import a video as a project | Screen Studio, OpenScreen, FocuSee |
| iPhone and iPad recording with device frames | Screen Studio |
| Speaker notes (teleprompter) | Screen Studio, OpenScreen, Cap |
| Recording markers | Screen Studio |
| Hide desktop icons while recording | Screen Studio |
| Shareable links | Screen Studio, Cap, Tella, Loom |

### Should have

| Feature | Who has it |
|---|---|
| Motion blur on zoom and pan | Screen Studio, Recordly, OpenScreen, Cap |
| Transitions between clips | Cap, Camtasia, ScreenFlow |
| Freeze frame | Requested everywhere; nobody in the Screen Studio class ships it |
| Image overlays and logo watermark | Recordly, OpenScreen, Cap |
| Device and browser frames | OpenScreen, Cap |
| ProRes export; transparent export | Cap, Rotato, ScreenFlow |
| Autosave | Screen Studio |
| Microphone level meter while recording | Screen Studio, OpenScreen |
| Command menu | Screen Studio |
| Crash-safe recording | OpenScreen, Cap, OBS |

### Later

| Feature | Who has it |
|---|---|
| 3D camera (tilt, perspective, depth of field) | OpenScreen, Cap, FocuSee |
| Animated and video backgrounds | Recordly, Cap |
| Caption translation | OpenScreen, Tella, Camtasia |
| AI chat editing, command-line tool | OpenScreen, Cap |
| Hosted sharing with analytics | Cap, Tella, Loom |

## Part C: where Cue Studio is already ahead

Worth protecting while the gaps are closed.

| Strength | Why it matters |
|---|---|
| Native Swift app | Web-view editors use several times the CPU and memory |
| One renderer for preview and export | "Preview does not match export" is a standing bug class elsewhere |
| Each sound in its own file, with level, mute and solo per source | Screen Studio has two tracks and a mute |
| Voice-over recorded against the edit | Top-five request on Screen Studio's hub |
| Several blur regions at once | Screen Studio allows one |
| Text, arrow and box annotations with animation | Absent from Screen Studio |
| Exports keep running after the editor closes | Screen Studio users ask for an export queue |
| Pointer can be hidden, held still or calmed per stretch | Only "hide" exists elsewhere |
| Zoom framed by eye on the preview | Others use a target dot |
| Cut, copy and paste through the system clipboard, between projects | Not found elsewhere |
| 1440p export and a size estimate before exporting | Screen Studio has neither |
| Keystrokes are timed but never recorded | A privacy position no competitor states |
