# Screen recording tools: features, architecture, and a native add-on design for Cue

Research notes gathered on 2026-09-23 for the question "what would it take to add Screen Studio-style
video recording to Cue, without making Cue heavier for people who only take screenshots?"

Three reference implementations were examined:

| | Recordly | OpenScreen | Screen Studio |
|---|---|---|---|
| Repository | `webadderallorg/Recordly` | `siddharthvaddem/openscreen` | closed source |
| License | AGPL-3.0 (GitHub reports `NOASSERTION`) | MIT | commercial |
| Stars | ~30.9k | ~40.0k | — |
| Status | active (pushed 2026-09-23) | archived (last push 2026-06-17) | shipping, v3.7.5-4595 |
| Stack | Electron + TypeScript + React 19 | Electron + TypeScript + React 18 | Electron + Swift helpers |
| Platforms | macOS 14+, Windows 10 19041+, Linux | macOS, Windows, Linux | macOS 12+ |

Recordly is effectively OpenScreen's continuation — it still ships a helper binary named
`openscreen-window-list` alongside its own `recordly-*` helpers, and the two source trees share
module names, file layout and several test names.

Screen Studio was analysed from the copy installed at `/Applications/Screen Studio.app` at the
bundle level only: `Info.plist`, code-signing entitlements, linked frameworks (`otool -L`),
undefined symbols (`nm -u`) and strings of the shipped Mach-O helpers. Its JavaScript bundle was not
decompiled, nothing was patched, and no proprietary code is reproduced here or proposed for reuse.
Everything below is design reference.

---

## 1. Summary

**Recordly** is a demo-video recorder and editor: record a display or window, then polish it in a
timeline editor with auto-zoom, cursor effects, a webcam bubble, styled backgrounds, annotations and
auto-captions, and export MP4 or GIF. It adds two things the others do not have: a cloud share
service (Cloudflare R2 + D1 worker, Supabase auth, timestamped comments) and a permission-gated
extension API with a marketplace.

**OpenScreen** is the same product one generation earlier and smaller in scope — no cloud, no
extensions, no project dashboard — but with a cleaner internal boundary between Electron and native
code (its `native-bridge` layer) and a few editor features Recordly lacks, such as blur regions and
text animation presets. It is archived; a community fork continues it.

**Screen Studio** is the commercial benchmark and the most interesting architecturally: an Electron
UI on top of a Swift command-line recorder (`polyrecorder`, internal module name `RecordKit`) plus
about a dozen small single-purpose native helpers. The Electron side never touches capture.

All three share one shape, and it is the shape worth copying:

1. The UI is a web app; **capture is a native process**.
2. Recording writes a clean, high-bitrate source plus **metadata sidecars** — cursor path, click
   events, keystrokes, window bounds, orientation changes — rather than a finished video.
3. The editor is **non-destructive**: a timeline of regions over that source.
4. Every effect (zoom, cursor smoothing, background, padding) is applied at **render time**, in the
   preview and again at export.

Point 2 is what makes the product feel magic. Auto-zoom, cursor smoothing, click bounce and
re-framing are only possible because nothing was baked into the recording.

For Cue, the same split applies, with two changes: the native helper *is* the whole feature
(recorder, editor and exporter, all Swift), and it does not ship with Cue. It is a separately
installed add-on, so a user who only takes screenshots never downloads or launches a line of it.

---

## 2. Feature matrix

| Capability | Recordly | OpenScreen | Screen Studio |
|---|---|---|---|
| Full display capture | yes | yes | yes |
| Single window capture | yes | yes | yes |
| Area/region capture | via crop in editor | via crop in editor | yes |
| Microphone | yes | yes | yes (plus noise reduction) |
| System audio | yes (macOS 13+, Windows, Linux/PipeWire) | same | yes |
| Webcam overlay | bubble with presets/custom position, mirror, roundness, shadow, zoom-reactive scale | PiP, drag-to-position, mirror, shapes | yes, plus face detection |
| iPhone / external device capture | no | no | yes (CoreMediaIO + Continuity) |
| Cursor captured as data | yes (native monitor + system cursor assets) | yes (macOS/Windows native; Linux position only) | yes (`CursorRecorder`, shape + timestamps) |
| Keystroke capture | input hooks via `uiohook-napi` | no | yes (`InputRecorder`, `captureKeyStrokes`) |
| Auto-zoom from cursor activity | yes (zoom suggestions) | yes | yes |
| Manual zoom regions | yes | yes, with depth/duration/easing | yes |
| Cursor polish | size, smoothing, motion blur, click bounce, sway, loop mode | size, smoothing, click effects, themes, path smoothing | yes |
| Backgrounds | wallpapers, solid, gradient, custom image, runtime wallpaper discovery | wallpapers, solid, gradient, custom image | yes |
| Frame styling | padding, corner radius, background blur, drop shadow, aspect presets | same | yes |
| Annotations | text, image, figures | text, arrows, images, text animation presets | yes |
| Blur regions | — | yes | yes (plus dynamic mask tracking) |
| Trim / speed / crop | yes, per-region on the timeline | yes | yes |
| Timeline niceties | drag-and-drop, 8 px snapping, filmstrip, waveform, keyframe markers | snapping guides, waveform | yes |
| Auto-captions | yes, bundled whisper.cpp runtime | yes, on-device `@xenova/transformers` | yes (`Speech.framework` helper + whisper) |
| Project file | `.recordly` | project persistence in app data | `.screenstudio` package + `.screenstudiopreset` |
| Export | MP4, GIF (quality, fps, loop, size presets, aspect/dimension control) | MP4, GIF, multiple aspect ratios and resolutions | MP4, GIF (gifsicle) |
| Cloud sharing | yes (links, comments, reactions, password, expiry) | no | yes (service) |
| Extensions | yes, marketplace + permission-gated host API | no | no |
| i18n | yes (14+ locales, zh-CN auto-translate workflow) | yes (13 locales) | yes |

---

## 3. Tooling inventory

### Recordly

Runtime: Electron 43, Vite 5, React 19, TypeScript 5, Tailwind 4 + HeroUI, Biome, Vitest, Playwright.

Media: PixiJS 8 + `pixi-filters` (preview compositing), `mediabunny` (mux/demux), `mp4box`,
`web-demuxer` (WASM), `gif.js`, `ffmpeg-static` + `ffprobe-static`, `@fix-webm-duration/fix`.

Editing: `dnd-timeline` + `@dnd-kit/core` for the timeline, `motion` for UI animation, `react-rnd`,
`react-resizable-panels`.

System: `capturekit` (npm capture wrapper), `uiohook-napi` (global input hooks), `electron-updater`,
`@supabase/supabase-js` (account and share auth).

Native helpers it builds itself:

- macOS Swift: `ScreenCaptureKitRecorder.swift`, `ScreenCaptureKitWindowList.swift`,
  `NativeCursorMonitor.swift`, `SystemCursorAssets.swift`.
- Windows C++: `wgc-capture` (Windows Graphics Capture + Media Foundation encoder + WASAPI
  loopback), `windows-capture` (DXGI fallback), `cursor-monitor`, `gpu-export-probe`,
  `nvidia-cuda-compositor` (CUDA `main.cu`, opt-in GPU export path).
- Cross-platform: a whisper.cpp runtime (`whisper-cli`, `whisper-server`, `whisper-vad-*`) built by
  `scripts/build-whisper-runtime.mjs`.

### OpenScreen

Runtime: Electron 41, React 18, Radix UI primitives, Tailwind 3, Biome, Vitest (plus browser mode),
Playwright, Husky.

Media: PixiJS 8, `@pixi/filter-drop-shadow`, GSAP, `mediabunny`, `mp4box`, `web-demuxer`, `gif.js`,
`@xenova/transformers` (on-device captions), `sonner`.

Native helpers: a Swift Package (`electron/native/screencapturekit/Package.swift`) producing
`OpenScreenScreenCaptureKitHelper` and `OpenScreenMacOSCursorHelper`; a C++ `wgc-capture` helper on
Windows with DirectShow webcam capture and WASAPI loopback. Packaging covers a Nix flake, NixOS and
Home Manager modules, a Homebrew cask and winget.

### Screen Studio

Shell: Electron (Squirrel autoupdate, Mantle and ReactiveObjC frameworks in the bundle), hardened
runtime with `allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`,
`device.audio-input`, `device.camera`. **Not sandboxed.** `LSMinimumSystemVersion` is 12.0. 624 MB
installed; `app.asar` alone is 246 MB.

Native helpers under `Contents/Resources/app.asar.unpacked/bin/`, all universal Mach-O:

| Helper | Links | Purpose |
|---|---|---|
| `polyrecorder` (prod/beta/discovery) | ScreenCaptureKit, AVFoundation, CoreMediaIO, CoreMedia, CoreVideo, CoreImage, Metal, Combine, CryptoKit, AppKit, IOKit, MobileDevice (private) | the recorder |
| `list-windows` | AppKit, CoreGraphics | window enumeration |
| `manage-window` | AppKit, ApplicationServices | move/resize the recorded window |
| `hide-icons` | AppKit, QuartzCore, Metal | hide desktop icons while recording |
| `macos-wallpaper` | — | set and restore wallpaper |
| `face-detector` | Vision, AVFoundation | webcam framing |
| `dynamic-mask-tracker` | AVFoundation, CoreMedia | tracked blur/mask regions |
| `audio-composer` | AVFoundation, CoreMedia | audio mixdown |
| `transcribe-audio` | Speech, AVFoundation (`--locale`) | captions |
| `whisper-darwin-arm64` | — | captions, second engine |
| `deep-filter-arm64` + `noise-reduction-model.rnnn` | — | voice noise suppression |
| `ffmpeg-darwin-arm64`, `gifsicle` | — | transcode and GIF |
| `sf-icon`, `file-icon` | AppKit | icon rendering for the UI |

`polyrecorder` is Swift built with `swift-argument-parser`; its flags cover `-video`, `-audio`,
`-cursor`, `-input`, `-webcam`, `-window`, `-external-device`, `-microphone`, `-system-audio`, plus
`-legacy-*` variants and `--experimental-dump-help`.

---

## 4. Architecture deep-dive

### 4.1 Recordly and OpenScreen: the Electron shape

```
React renderer  ──preload──▶  main-process IPC registry  ──▶  native helper process
  (UI, PixiJS preview,          (electron/ipc/register/*)        (Swift / C++ capture)
   timeline, exporter)                    │
                                          ├──▶ project store (JSON + media on disk)
                                          └──▶ ffmpeg / whisper / thumbnail helpers
```

Decisions worth stealing, with the files that hold them:

- **One versioned bridge, not ad-hoc channels.** OpenScreen's `docs/architecture/native-bridge.md`
  defines four layers — native adapters, main-process services, a single `native-bridge:invoke`
  transport with versioned contracts, and a renderer SDK — under three rules: native state lives in
  the main process, the renderer can query capability before attempting anything, and every response
  uses one result envelope with stable error codes. Recordly kept the older per-domain registry
  (`register/recording.ts`, `register/export.ts`, `register/captions.ts`, and so on).
- **Per-platform capture behind one interface.** `electron/native-bridge/cursor/recording/factory.ts`
  returns `WindowsNativeRecordingSession`, `MacNativeCursorRecordingSession`, or on Linux a
  `TelemetryRecordingSession` that samples only cursor position through Electron's `screen` API — no
  sprites, no clicks. Capability degrades per platform instead of failing.
- **Stream recording chunks straight to disk.** `RecordingStreamRegistry`
  (`electron/ipc/recordingStream.ts`) owns a write stream per recording and appends MediaRecorder
  chunks as they arrive, "so a long recording never buffers the whole video in the renderer". The
  stream resolves on the `open` event, so a bad path fails immediately instead of silently dropping
  chunks later.
- **Cursor telemetry is its own track.** Sampled on an interval during capture, persisted beside the
  video, consumed by the editor for auto-zoom suggestions and the rendered cursor overlay
  (`videoPlayback/cursorRenderer.ts`, `cursorFollowCamera.ts`, `cursorSway.ts`, `cursorScale.ts`).
- **Preview and export are two separate renderers.** Preview draws with PixiJS/canvas; export
  re-renders frame by frame in `src/lib/exporter/modernVideoExporter.ts` through WebCodecs, muxed by
  `muxer.ts`/mediabunny. Recordly's `backendPolicy.ts` chooses between three routes —
  `native-static-layout`, `breeze-stream`, `webcodecs` — and carries a comment disabling the Windows
  auto static-layout probe "while stabilizing v1.3.0" because it could leave the export stuck at
  "Preparing export…". Keeping two renderers in agreement is visibly expensive.
- **Timeline semantics are written down.** Recordly's `docs/timeline-sequence.md` is the most useful
  document in either repo: primary footage is an ordered contiguous sequence; a clip separator has no
  duration; `sourceStartMs` is never re-derived from a new timeline position; `speed` is source ms
  consumed per timeline ms; resizing is bounded by available source footage rather than by collision
  with the next clip; dragging picks an insertion index rather than hunting for a gap; every timeline
  object snaps within 8 screen pixels at any zoom level.
- **IPC path ownership.** `electron/ipc/export/exportStream.ts` keeps an allowlist of paths the
  export pipeline itself created, and every handler that moves or deletes a file asserts membership
  first, "so a compromised renderer can never route arbitrary file paths into the IPC". Worth
  carrying over even in a Swift XPC world.
- **Extensions (Recordly only).** A manifest (`recordly-extension.json`: id, name, version, main,
  `permissions`) plus `activate(api)` / `deactivate()`. Extensions run in the editor renderer against
  a permission-gated host API: render hooks (`api.registerRenderHook("final", …)`), playback and
  export events, cursor effects, settings panels, and packaged assets such as frames, wallpapers and
  cursor styles. They load from `userData/extensions`.
- **Cloud share (Recordly only).** Render MP4 to a temp file, `POST /api/upload` for a share code,
  `PUT` for small files or 25 MB retryable multipart chunks above 50 MB, `POST` metadata, then a
  `/s/:shareCode` page. R2 for storage, D1 for metadata, Supabase for auth; the viewer page has range
  streaming, timestamped comments, reactions, captions, password protection and expiry.

### 4.2 Screen Studio: Electron over a Swift recorder

`polyrecorder`'s Swift source file names, recovered from the binary, lay the design out:

```
App.swift ─▶ Polyrecorder.swift ─▶ Conductor.swift
                                        │
   ┌───────────────┬────────────────┬───┴────────┬─────────────────┬──────────────────┐
DisplayRecorder  WindowRecorder  SystemAudio-  Webcam-        ExternalDevice-   Cursor- / Input-
  (SCStream)       (SCStream)     Recorder     Recorder         Recorder          Recorder
        │                         (SCStream)   (AVCapture)   (CMIO/Continuity)        │
        └───────────────┴────────────┴─────────────┴──────────────┘                   │
                            SessionWriter                                StreamingJSONWriter
              (AVAssetWriter + SegmentedAssetWriterDelegate)              (cursor, keystrokes)
                                    │
                    MetadataWriter, WindowBoundsChangesMetadataWriter,
                    VideoOrientationChangesMetadataWriter
```

Supporting pieces: `CaptureHelper`, `ShareableContent` and `DiscoverySession+Lookup` for source
enumeration; `AudioHALDeviceObserver` for devices changing mid-recording; `DiskSpaceInfo` (the binary
carries explicit "ScreenCaptureKit stopped by system, low disk space" errors); `BackpressureBuffer`;
and a `RecordKit` module holding `FrameRepeater`, `TimedAudioGapFiller` and `AudioStretch` — three
pieces whose entire job is keeping audio and video aligned when frames arrive late or a device
hiccups. `LegacyDisplayRecorder` and `LegacyMicrophoneRecorder` use `AVCaptureScreenInput`, because
ScreenCaptureKit needs macOS 12.3 (13.0 for system audio).

Two things stand out:

- **Sidecars instead of baked frames.** Cursor shape and timestamps, keystrokes, window bounds
  changes and video orientation changes all stream to JSON next to the video. The editor can reframe,
  re-render the cursor and animate zooms afterwards because the recording preserved the data rather
  than the appearance.
- **Small single-purpose helpers.** Face detection, mask tracking, transcription, audio composition,
  icon rendering and wallpaper control are each a separate binary the Electron side spawns. Process
  isolation is the whole extensibility model — no plugin loader, no dynamic code.

The cost of the Electron shell is plain: 624 MB installed, hardened-runtime exceptions
(`allow-unsigned-executable-memory`, `disable-library-validation`), and no App Sandbox at all.

---

## 5. Cue: a native Swift recording add-on

### 5.1 Requirement

Recording must be Swift and native, and it must **not** ship inside the default Cue download. Cue
is 11 MB installed and sandboxed; a video encoder, a Metal renderer, a timeline editor and a caption
model would multiply that for every user, including the ones who only ever press ⌥⇧4. So recording
is an **add-on**: installed separately, on request, and absent until then.

### 5.2 Shape

The add-on is its own notarised application, `Cue Studio.app`, signed with the same Team ID, offered
from inside Cue and installed into `/Applications` only when the user asks for it. Cue core links
none of its code. It runs as its own process, only while recording or editing, and exits afterwards.

```
Cue.app (core, ~11 MB)                        Cue Studio.app (add-on, ~25–40 MB)
├── Cue/AddOns/                               ├── Recording/   (SCStream, AVAssetWriter)
│   ├── AddOnRegistry     installed? version?  ├── Telemetry/   (cursor, keys, window bounds)
│   ├── AddOnInstaller    download + verify    ├── Project/     (.cuerec package)
│   ├── AddOnSettingsView Add-ons pane         ├── Editor/      (timeline + Metal renderer)
│   └── RecordingClient   XPC calls            ├── Export/      (VideoToolbox, ImageIO)
└── links only AddOnKit ◀── shared SPM pkg ──▶ └── Captions/    (SpeechAnalyzer)
                         (manifest, XPC protocol,
                          project types, versioning)
```

**Alternatives rejected.** An in-process loadable `.bundle` needs
`com.apple.security.cs.disable-library-validation`, fights the App Sandbox and notarisation, and
loads downloaded code into the host process — the posture Screen Studio had to adopt and Cue should
not. A compiled-in feature behind a preference flag does nothing for binary size, launch time or
linked frameworks, which is the entire point.

### 5.3 Install flow

The add-on is **an app the user installs**, not a payload Cue unpacks into its own container. Two
sandbox facts decide this, and both were checked rather than assumed:

- A sandboxed process cannot create a non-quarantined executable. Everything Cue downloads carries
  `com.apple.quarantine`, and `LSFileQuarantineEnabled = false` does not exempt a sandboxed app. So
  a downloaded-and-launched-in-place copy would hit Gatekeeper on first open, and Cue cannot strip
  the attribute.
- Writing into Cue's own bundle is off the table anyway: the bundle is code-signed and sealed, and
  writing there invalidates the signature and silently drops the Screen Recording grant — the
  existing `TessdataFiles` comment in `Cue/OCR/LanguagePackStore.swift` already records this.

So the flow is:

1. A catalogue entry per add-on: id, display name, version, minimum host version, download URL,
   exact byte length, SHA-256. Cue fetches the catalogue; it does not hard-code versions.
2. The Add-ons pane shows the add-on with its size and version and a single **Install** button.
   Install downloads the notarised, stapled disk image or signed installer package with a resumable
   `URLSession` task, verifies length and digest, then hands it to `NSWorkspace.open` — the installer
   or the mounted image carries the normal, familiar "drag to Applications" step, and macOS performs
   the Gatekeeper and notarisation checks itself. A signed `.pkg` makes it one click; a `.dmg` keeps
   it conventional. Either way the add-on ends up in `/Applications` like any other app.
3. State machine `missing → downloading → verifying → awaiting-install → ready → failed`, with a
   `.partial` sweep on launch and one shared in-flight task per add-on, exactly as
   `LanguagePackStore` does today for Tesseract models.
4. Discovery after install is LaunchServices, not a path: `NSWorkspace.shared
   .urlForApplication(withBundleIdentifier: "com.stackrover.cue.studio")`, then a
   `SecStaticCodeCheckValidity` requirement pinning the Team ID before the host will talk to it, then
   a version handshake against the minimum the host needs.
5. Update and removal are the add-on's own business: it ships its own updater, and "Remove" simply
   points the user at the installed app. Cue never deletes an app it did not install.

The download/verify half of this is the `LanguagePackStore` pattern with a different payload; the
install half deliberately defers to macOS rather than fighting quarantine.

### 5.4 Host ↔ add-on IPC

Mach ports are blocked by the App Sandbox **except** between processes in the same App Group, and an
embedded XPC service is private to the app that contains it — it cannot be shared with a second app.
So the wiring is:

- both apps join `group.com.stackrover.cue`;
- the add-on registers a login-item helper with `SMAppService`, and that helper vends an
  `NSXPCListener(machServiceName:)` whose name is prefixed with the App Group;
- Cue connects with `NSXPCConnection(machServiceName:options:)` and, after the handshake, can be
  handed an `NSXPCListenerEndpoint` for the recording session itself.

If the login-item helper proves more ceremony than it is worth for a feature the user invokes
explicitly, the fallback is coarser and perfectly serviceable: Cue launches the add-on with
`NSWorkspace.openApplication(at:configuration:)` passing a request through a custom URL scheme or
launch arguments, and the finished project comes back through the shared App Group container. Decide
this when the first recording works end to end, not before.

Whichever transport wins, the contracts live in `AddOnKit` and follow OpenScreen's rules, which are
worth taking wholesale:

- state lives on one side — the add-on owns recording state, the host never guesses;
- **capability-first** — the host asks what the installed version supports before offering UI, so an
  older add-on simply exposes fewer menu items;
- versioned request and response types;
- one result envelope with stable error codes.

Recorded media is written into the shared group container, so a finished project reaches
`CaptureLibrary` without security-scoped bookmarks. When the add-on is missing or too old, the record
commands read "Install recording add-on…" instead of failing. The path-ownership guard from
Recordly's `exportStream.ts` carries over directly: the add-on accepts file operations only on paths
it created itself.

### 5.5 Recording engine (inside the add-on)

Screen Studio's split, in Swift 6 with the concurrency model Cue already uses (main-actor-by-default,
`nonisolated` where work leaves the main actor):

- `Recording/RecordingSession` — an actor playing `Conductor`: starts and stops the sub-recorders
  together, owns the shared clock, surfaces errors and disk-space warnings.
- `Recording/DisplayRecorder`, `WindowRecorder`, `AreaRecorder` — `SCStream` over an
  `SCContentFilter` built from `SCShareableContent`. Cue's `WindowDetector` and
  `ScreenCaptureService` already do this enumeration for screenshots; the add-on should reuse the
  existing selection overlay rather than growing a second one.
- `Recording/SystemAudioRecorder` — SCStream audio (macOS 13+); `MicrophoneRecorder` — `AVAudioEngine`;
  `WebcamRecorder` — `AVCaptureSession`, including Continuity Camera.
- `Recording/SessionWriter` — `AVAssetWriter`, HEVC where the hardware supports it and H.264
  otherwise, segmented output so a crash still leaves usable footage, plus backpressure, frame repeat
  and audio gap filling. Those last three are not polish; they are the difference between a recorder
  that drifts and one that does not.
- `Recording/Telemetry/` — `CursorTrack` (position, cursor shape, click events), `KeystrokeTrack`,
  `WindowBoundsTrack`, each appended to a JSONL sidecar as events happen, never buffered to the end.

### 5.6 Project format, editor, export

- `Project/` — a `.cuerec` document package (`NSFileWrapper`): video tracks, audio tracks, webcam
  track, telemetry sidecars, `project.json`. A package, like `.screenstudio`, so a project is one
  object in Finder but cheap to write incrementally.
- `Editor/Timeline/` — a value-type model (clips, trims, speed regions, zoom regions, annotations,
  captions, audio regions) with an undo stack, following the rules Recordly documented: contiguous
  clip packing, zero-duration separators, `sourceStartMs` never re-derived, speed as source-ms per
  timeline-ms, insertion-index dragging, 8-point snapping at every zoom level.
- `Editor/Render/SceneRenderer` — **one** renderer on Core Image/Metal driving both the live preview
  (`MTKView`) and the export encoder. This is the largest architectural advantage a native
  implementation gets: the Electron apps maintain a PixiJS preview and a WebCodecs exporter and spend
  real effort keeping the two in agreement.
- `Export/` — `AVAssetWriter` + `VTCompressionSession` for MP4/HEVC, `ImageIO` for GIF, hardware
  encoded, with no ffmpeg and no gifsicle to bundle, sign or update.
- `Captions/` — on-device `SpeechAnalyzer` / `SFSpeechRecognizer` first. Whisper only if quality
  demands it, built statically through the existing `Vendor/` pattern (Cue already vendors Tesseract
  and Leptonica that way) and fetched as a downloadable model pack, like the language packs.

### 5.7 What the core already provides

The add-on calls into, rather than re-implementing: `CaptureCoordinator` and `CaptureSession`
(capture orchestration), `WindowDetector` (window enumeration and snapping), `OverlayWindow` and
`SelectionView` (area selection with magnifier and handles), `HotkeyManager` and `ShortcutController`
(a rebindable record hotkey beside the existing ⌥⇧3 / ⌥⇧4 / ⌥⇧5), `PermissionManager` and the
onboarding flow (extended to microphone and camera), `CaptureLibrary` (recordings land where
screenshots do), `ShareUploader` (share links) and `AppPreferences` (settings).

Permissions, stated plainly: the add-on carries its own TCC grants. Screen Recording, Microphone and
Camera are requested by `Cue Studio.app` under its own bundle identifier, so the host's existing
grant is untouched, and removing the add-on removes its grants with it.

### 5.8 Optimisation ledger

| | Without the add-on | With the add-on installed |
|---|---|---|
| Cue.app size | ~11 MB, unchanged | ~11 MB plus a few hundred KB of `AddOnKit` |
| Frameworks linked by Cue | unchanged — no encode path, no Metal renderer, no Speech | unchanged |
| Launch time | unchanged | unchanged; the add-on is a separate process, launched on demand |
| Memory at idle | unchanged | unchanged; the add-on process exits after recording and editing |
| Download | — | one-off ~25–40 MB, digest-verified, removable |
| Update cadence | core releases | the add-on ships its own releases, independent of the host |

### 5.9 Build order

1. Add-on plumbing first — `AddOnKit`, `AddOnRegistry`, `AddOnInstaller`, the Add-ons pane, the XPC
   handshake. Without it none of the rest is optional, and retrofitting the boundary later is the
   expensive path.
2. Recording plus telemetry sidecars, writing a `.cuerec` package.
3. Playback and the `SceneRenderer` preview.
4. Timeline editing: trim, speed, crop.
5. Zoom regions and cursor beautification — the features the sidecars exist for.
6. Export: MP4, then GIF.
7. Captions.
8. Share, through the existing uploader.

---

## 6. Open questions

- **Auto-zoom heuristics.** All three tools derive zoom suggestions from cursor activity and none
  document how. Needs its own experiment against real recordings.
- **Cursor artwork.** Recordly ships "macOS-style cursor assets" and Screen Studio carries a full
  `NSCursor` shape table. Drawing our own rather than shipping Apple's artwork is the safe route.
- **Keystroke capture under the sandbox.** Needs an Accessibility grant and a `CGEventTap`. Worth
  deciding whether a keystroke overlay earns that prompt, or whether it waits.
- **GPU budget** for 4K60 preview with blur, shadow and zoom springs in one Core Image graph.
- **Editor placement.** Does the add-on carry its own editor window, or hand finished projects to
  Cue's existing `Cue/Editor`? The second keeps one editor; the first keeps the core free of
  timeline code. Current leaning: the add-on owns it, for the same reason it owns everything else
  heavy.
- **Manifest generality.** Define the add-on manifest broadly enough that other optional features
  (cloud OCR, future tools) reuse the registry, or keep it recorder-specific until a second add-on
  exists.

---

## Sources

- `webadderallorg/Recordly` — README, `package.json`, file tree, `EXTENSIONS.md`,
  `docs/timeline-sequence.md`, `docs/cloud-sharing.md`, `THIRD_PARTY_NOTICES.md`,
  `src/lib/exporter/backendPolicy.ts`, `electron/ipc/export/exportStream.ts`,
  `electron/ipc/recording/mac.ts`; read through the GitHub API on 2026-09-23.
- `siddharthvaddem/openscreen` — README, `package.json`, file tree,
  `docs/architecture/native-bridge.md`, `electron/ipc/recordingStream.ts`,
  `electron/native-bridge/cursor/recording/factory.ts`, `src/hooks/useScreenRecorder.ts`.
- Screen Studio 3.7.5-4595 at `/Applications/Screen Studio.app` — `Info.plist`, code-signing
  entitlements, bundle layout, and `file` / `otool -L` / `nm -u` / `strings` inspection of the
  helpers in `Contents/Resources/app.asar.unpacked/bin/`.
- Cue itself — `README.md`, `Config/Cue.entitlements`, `Cue/OCR/LanguagePackStore.swift`, and the
  module layout under `Cue/`.
