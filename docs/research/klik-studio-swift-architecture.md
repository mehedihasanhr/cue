# Klik Studio — Swift implementation architecture

How every feature surveyed in [screen-recording-addon.md](screen-recording-addon.md) is built in
Swift, as the separately installed `Klik Studio.app` add-on. This is the implementation companion:
module tree, types, concurrency model, data flow, and the Apple API behind each feature.

Baseline: Swift 6, Xcode 26, macOS 14+. Approachable Concurrency on, **Default Actor Isolation =
MainActor** (what Klik core already uses), no third-party dependencies, no ffmpeg.

---

## 1. Principles

1. **One renderer.** Preview and export run the same `SceneRenderer` over the same
   `SceneDescriptor`. The Electron tools all maintain two and pay for it forever.
2. **Record data, not appearance.** Capture writes clean video plus telemetry sidecars; every
   effect is applied at render time. Auto-zoom, cursor smoothing and re-framing exist only because
   of this.
3. **Value types for the document.** The whole timeline is `struct`s. Undo, autosave, diffing and
   "is this project dirty?" become one code path instead of one per feature.
4. **Main actor until profiling says otherwise.** UI, document, timeline editing: main actor.
   Capture, encode, decode, waveform and caption work: off it, explicitly, in that order —
   `async` → `@concurrent` → `actor`.
5. **Typed throws at layer boundaries**, matching `CaptureError` in `Klik/Capture/ScreenCaptureService.swift`.

---

## 2. Targets and packages

```
Klik.xcodeproj
├── Klik                (existing app, sandboxed — gains Klik/AddOns/ only)
├── KlikStudio          (new app target: Klik Studio.app)
├── KlikStudioHelper    (SMAppService login item that vends the XPC Mach service)
└── Packages/
    ├── AddOnKit        (shared: manifest, XPC contracts, project types)  ← linked by BOTH
    ├── RecordKit       (capture + telemetry + writers)                   ← KlikStudio only
    ├── TimelineKit     (document model, clip math, undo)                 ← KlikStudio only
    └── SceneKitten     (SceneDescriptor + SceneRenderer + exporters)     ← KlikStudio only
```

`AddOnKit` is the only one Klik core links, and it contains no AVFoundation, no Metal and no Speech —
that is what keeps the ledger in the research doc honest. Packages use
`swiftSettings: [.defaultIsolation(MainActor.self)]` except `RecordKit` and `SceneKitten`, which are
`nonisolated` by default because their callers decide where the work runs.

---

## 3. Module tree

```
RecordKit/
├── Session/         RecordingSession, RecordingConfiguration, RecordingState, RecordingError
├── Sources/         DisplayRecorder, WindowRecorder, AreaRecorder, WebcamRecorder,
│                    SystemAudioRecorder, MicrophoneRecorder, DeviceRecorder
├── Writing/         SessionWriter, TrackWriter, SegmentPolicy, FrameClock, FramePacer,
│                    AudioGapFiller, DiskSpaceMonitor
├── Telemetry/       CursorTracker, FocusTracker, KeystrokeTracker,
│                    JSONLWriter, TelemetrySample
└── Discovery/       ShareableContentStore, CaptureTarget, DeviceObserver

TimelineKit/
├── Document/        StudioProject, ProjectPackage, ProjectMigrator, RecordingManifest
├── Model/           Timeline, Clip, ZoomRegion, SpeedRegion, BlurRegion, AnnotationItem,
│                    CaptionCue, AudioRegion, WebcamSettings, FrameStyle, CursorStyle
├── Editing/         TimelineCommand, ClipSequence, Snapping, SelectionState, UndoStack
└── Analysis/        ZoomSuggester, CursorSmoother, SilenceDetector, WaveformBuilder

SceneKitten/
├── Scene/           SceneDescriptor, SceneBuilder, LayerDescriptor, CameraTransform
├── Render/          SceneRenderer, FrameSource, CursorAtlas, TextRasterizer, BlurPipeline
├── Preview/         PreviewCoordinator, PreviewView (MTKView), PlaybackClock
└── Export/          VideoExporter, GIFExporter, AudioMixdown, ExportSettings, ExportProgress

KlikStudio/
├── App/             StudioApp, StudioMenu, RecorderHUD, CountdownOverlay
├── Recorder/        SourcePicker, RecordingController, DeviceMenus
├── Editor/          EditorWindow, TimelineView, InspectorView, CanvasView
├── Captions/        CaptionGenerator, CaptionEditor
├── Library/         ProjectBrowser, Thumbnailer
└── Bridge/          StudioXPCService, HostHandshake

Klik/AddOns/         (host side) AddOnRegistry, AddOnCatalog, AddOnInstaller,
                     AddOnSettingsView, RecordingAddOnClient
```

---

## 4. Concurrency model

| Component | Isolation | Why |
|---|---|---|
| `StudioProject`, `Timeline`, editor views | main actor | document editing is UI-paced; value types make it cheap |
| `RecordingSession` | `actor` | owns state mutated from several capture callbacks |
| `SCStreamOutput` / `AVCaptureVideoDataOutput` delegates | `nonisolated`, own serial `DispatchQueue` | frames arrive on the system's queue; hop nothing |
| `SessionWriter` | `actor` | serialises `AVAssetWriterInput` appends from video + audio producers |
| `SceneRenderer` | `nonisolated final class`, one per consumer | preview holds one on the render thread, export holds another |
| `VideoExporter`, `WaveformBuilder`, `CaptionGenerator` | `@concurrent` methods | CPU/GPU heavy, started from a UI task |
| `AddOnRegistry`, `AddOnInstaller` (host) | main actor, `@Observable` | drives SwiftUI directly, like `LanguagePackStore` |

Frames never touch the main actor. The capture path is delegate queue → `SessionWriter` actor →
disk. The preview path is `CVDisplayLink`/`MTKView` draw → `SceneRenderer` → Metal, with the
document read through an immutable `SceneDescriptor` snapshot published on each edit, so playback
never blocks on the main actor mid-frame.

```swift
// SceneKitten/Preview/PreviewCoordinator.swift
@MainActor @Observable
final class PreviewCoordinator {
    private(set) var descriptor: SceneDescriptor   // rebuilt on edit, read by the renderer
    private let renderer: SceneRenderer            // nonisolated, lives on the draw thread

    func timelineDidChange(_ timeline: Timeline) {
        descriptor = SceneBuilder.descriptor(for: timeline)   // pure, value-typed, cheap
    }
}
```

---

## 5. Capture

### 5.1 Targets and configuration

```swift
// RecordKit/Discovery/CaptureTarget.swift
public enum CaptureTarget: Sendable, Hashable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case area(CGDirectDisplayID, CGRect)          // an SCContentFilter over a display + sourceRect
    case device(String)                            // iPhone/iPad over Continuity, by unique ID
}

public struct RecordingConfiguration: Sendable {
    public var target: CaptureTarget
    public var frameRate: Int = 60                 // minimumFrameInterval
    public var capturesCursor = false              // false: we draw it ourselves from telemetry
    public var systemAudio = true
    public var microphone: AVCaptureDevice.UniqueID?
    public var webcam: AVCaptureDevice.UniqueID?
    public var countdown: Duration = .seconds(3)
    public var hidesDesktopIcons = false
    public var excludedBundleIDs: Set<String> = ["com.stackrover.klik", "com.stackrover.klik.studio"]
    public var codec: VideoCodec = .hevcIfSupported
    public var quality: CaptureQuality = .high     // maps to bitrate + pixel scale
}
```

Focus is recorded alongside the cursor, in `telemetry/focus.jsonl`: which app came
forward, where its front window was, and — with the Accessibility grant — which text
field took the caret. A click knows a *point*; a focus event knows a *rectangle*, which
is what lets `ZoomSuggester` choose how far in to go as well as where to aim. The app
and window halves need no grant beyond the Screen Recording one; the field half is
simply absent without Accessibility, and the suggester degrades to clicks.

`showsCursor` is **off** by default. The cursor is recorded as data and re-drawn at render time —
that is the whole reason cursor size, smoothing, click bounce and sway are possible later. A
"record the real cursor" escape hatch stays for users who want a faithful capture.

Klik core already enumerates sources: `ScreenCaptureService.shareableContent()`, `display(containing:)`
and `filterLeavingKlikOut(display:in:)`, plus `WindowDetector` for window hit-testing and the
`OverlayWindow` / `SelectionView` area picker. `ShareableContentStore` wraps the same calls for the
add-on and refreshes on display-configuration and `NSWorkspace` app notifications.

### 5.2 Stream plumbing

```swift
// RecordKit/Sources/DisplayRecorder.swift
nonisolated final class DisplayRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "studio.capture.video", qos: .userInitiated)
    private let writer: SessionWriter

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws(RecordingError) { … }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard case .complete = buffer.frameStatus else { return }   // SCStreamFrameInfoStatus
        Task { await writer.appendVideo(buffer) }
    }
}
```

`SCStreamConfiguration` carries `width`/`height` in pixels (`filter.pointPixelScale`),
`minimumFrameInterval`, `pixelFormat` (`kCVPixelFormatType_32BGRA`, or `420v` for HEVC efficiency),
`colorSpaceName` (sRGB or Display P3), `queueDepth: 8`, `capturesAudio`, and
`excludingApplications` so Klik's own HUD never lands in the recording — the same exclusion
`filterLeavingKlikOut` already builds.

Frame status matters: ScreenCaptureKit only delivers frames when the screen changes. A `.idle` or
`.blank` status is not a dropped frame; it means "same as before", which is what `FramePacer` turns
back into real presentation timestamps (§5.4).

### 5.3 Audio and webcam

- **System audio**: `SCStreamConfiguration.capturesAudio = true` plus an `.audio` output type on the
  same stream (macOS 13+), so it is already sample-aligned with video.
- **Microphone**: `AVAudioEngine` tap → `AVAudioFile` at 48 kHz, written as its own track so the
  editor can mute, gain or duck it independently. Device changes mid-recording are caught with an
  `AVAudioEngine.configurationChangeNotification` observer (Screen Studio has
  `AudioHALDeviceObserver` for exactly this) and heal by restarting the engine and gap-filling.
- **Webcam**: `AVCaptureSession` with an `AVCaptureDeviceInput` and `AVCaptureMovieFileOutput`, in a
  **separate file**, never composited into the screen recording. Position, shape, mirror and scale
  are editor-time decisions. Continuity Camera is discovered with
  `AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], …)`.
- **iPhone/iPad screen capture** (the one Screen Studio feature the open-source tools lack): the
  device appears as an `AVCaptureDevice` of type `.external` once
  `CMIOExtensionProperty`/`kCMIOHardwarePropertyAllowScreenCaptureDevices` is enabled — a
  `DeviceRecorder` wrapping `AVCaptureSession` covers it. Phase 2 feature; the architecture reserves
  the slot.

### 5.4 Writing, pacing and sync

```swift
// RecordKit/Writing/SessionWriter.swift
actor SessionWriter {
    private let writer: AVAssetWriter                  // .mov, segmented
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput
    private let clock: FrameClock                      // one CMClock shared by every producer

    func appendVideo(_ buffer: CMSampleBuffer) { … }    // synchronous body: the transaction
    func appendAudio(_ buffer: CMSampleBuffer, to track: AudioTrack) { … }
    func finish() async throws(RecordingError) -> RecordingManifest
}
```

Four details separate a recorder that drifts from one that does not, and all four have a named
counterpart in Screen Studio's binary:

| Problem | Type | Approach |
|---|---|---|
| Screen idle, no frames delivered | `FramePacer` (`FrameRepeater`) | re-append the last pixel buffer with a new PTS so the timeline stays wall-clock accurate |
| Audio device hiccup leaves a hole | `AudioGapFiller` (`TimedAudioGapFiller`) | insert silence of exactly the missing duration rather than letting audio slide forward |
| Encoder falls behind | `BackpressureBuffer` | bounded queue; drop-oldest with a counted diagnostic instead of unbounded memory growth |
| Long recording, crash risk | `SegmentPolicy` (`SegmentedAssetWriterDelegate`) | `AVAssetWriterDelegate` segment output every N seconds so a crash still leaves playable media |

Disk space is watched by `DiskSpaceMonitor` (`URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`)
and surfaces as a distinct `RecordingError.lowDiskSpace` — ScreenCaptureKit stops silently
otherwise, which is why Screen Studio ships a dedicated string for it.

```swift
public enum RecordingError: Error, LocalizedError, Sendable {
    case permissionDenied(PermissionKind)
    case targetDisappeared
    case lowDiskSpace(bytesAvailable: Int64)
    case deviceLost(name: String)
    case writerFailed(any Error)
    case cancelled
}
```

### 5.5 Session orchestration

```swift
// RecordKit/Session/RecordingSession.swift
public actor RecordingSession {
    public enum State: Sendable { case idle, countdown(remaining: Duration), recording(started: Date),
                                  paused, finishing, finished(URL), failed(RecordingError) }

    public private(set) var state: State = .idle
    public nonisolated let events: AsyncStream<State>     // the HUD and the host both subscribe

    public func start(_ configuration: RecordingConfiguration) async throws(RecordingError)
    public func pause() async          // stops appends, keeps streams warm
    public func resume() async
    public func stop() async throws(RecordingError) -> URL   // the .klikrec package
}
```

Sub-recorders start inside one `withThrowingTaskGroup` so a failure in any of them tears the rest
down; `stop()` drains in reverse order, finishes the writer, flushes telemetry, writes the manifest
and returns the package URL.

---

## 6. Telemetry sidecars

```swift
// RecordKit/Telemetry/TelemetrySample.swift
public struct CursorSample: Codable, Sendable {
    public let t: Double                 // seconds from session start, on the shared FrameClock
    public let x: Double, y: Double      // points, in the captured target's coordinate space
    public let shape: CursorShape        // .arrow, .iBeam, .pointingHand, .resize(.eastWest), …
    public let scale: Double             // display backing scale at that moment
}

public enum InputSample: Codable, Sendable {
    case mouseDown(t: Double, button: MouseButton)
    case mouseUp(t: Double, button: MouseButton)
    case scroll(t: Double, dx: Double, dy: Double)
    case key(t: Double, characters: String, modifiers: KeyModifiers)
}
```

- **Cursor position and shape**: a `CVDisplayLink`-paced sampler (or a 120 Hz timer) reading
  `NSEvent.mouseLocation` and `NSCursor.currentSystem`, mapped into target space. Cheap, no special
  permission.
- **Clicks and scrolls**: `NSEvent.addGlobalMonitorForEvents(matching:)` — no Accessibility grant
  needed for mouse events.
- **Keystrokes**: `CGEvent.tapCreate` **does** need Accessibility, so it is opt-in behind a settings
  toggle and its own permission prompt. Everything else works without it.
- **Window bounds**: an `AXObserver` on the recorded window (or repeated `SCShareableContent`
  lookups when Accessibility is unavailable), so the editor can re-frame if the user moves the
  window mid-take.

All four append to `JSONLWriter`, one line per sample, `FileHandle` + a small buffer, flushed on a
timer. Never accumulate in memory: a 20-minute recording at 120 Hz is ~150 k samples, and the
crash-safety argument is the same one Recordly makes for streaming video chunks to disk.

---

## 7. Project format

```
MyDemo.klikrec/                       (NSFileWrapper package, an Editor-role document type)
├── project.json                      Timeline + settings, the only file the editor writes often
├── manifest.json                     RecordingManifest: tracks, clock, device names, versions
├── media/
│   ├── screen.mov                    primary capture (HEVC or H.264)
│   ├── webcam.mov
│   ├── mic.m4a
│   └── system.m4a
├── telemetry/
│   ├── cursor.jsonl
│   ├── input.jsonl
│   └── window-bounds.jsonl
└── derived/                          regenerable: waveform peaks, filmstrip tiles, thumbnail
```

```swift
// TimelineKit/Document/StudioProject.swift
@MainActor @Observable
public final class StudioProject {
    public private(set) var timeline: Timeline           // value type; every edit replaces it
    public private(set) var manifest: RecordingManifest
    public var isDirty: Bool { timeline != savedTimeline }

    public func apply(_ command: some TimelineCommand)   // pushes onto UndoStack
    public func save() async throws                      // atomic package write
}
```

Saving is atomic the way Recordly's `project/atomicSave.ts` is: write `project.json` to a temp file
inside the package, `FileManager.replaceItemAt`, then update the wrapper. `derived/` is never part of
dirty state and is rebuilt on demand. `ProjectMigrator` keys off a `formatVersion` integer and
normalises legacy documents **before** the undo baseline is established — the exact trap Recordly
documents for projects with primary-track gaps.

---

## 8. Timeline model and editing

```swift
// TimelineKit/Model/Timeline.swift
public struct Timeline: Equatable, Codable, Sendable {
    public var clips: [Clip]                 // ordered, contiguous, no gaps
    public var zooms: [ZoomRegion]
    public var speeds: [SpeedRegion]
    public var blurs: [BlurRegion]
    public var annotations: [AnnotationItem]
    public var captions: [CaptionCue]
    public var audio: [AudioRegion]
    public var style: FrameStyle             // background, padding, radius, shadow, aspect
    public var cursor: CursorStyle
    public var webcam: WebcamSettings
}

public struct Clip: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var start: CMTime                 // edited timeline coordinates
    public var duration: CMTime
    public var sourceStart: CMTime           // retained in-point; NEVER re-derived from `start`
    public var speed: Double                 // source seconds consumed per timeline second
}
```

The clip rules are taken wholesale from Recordly's `docs/timeline-sequence.md`, because they are
correct and hard-won:

- primary footage is one contiguous sequence; a cut has **zero** duration;
- `sourceStart` survives packing, reordering and speed changes;
- resize is bounded by available source footage and a minimum clip duration, not by the next clip;
- a drag resolves to an **insertion index**, never a search for empty space;
- connected annotations, captions and audio anchors move with their clip;
- everything snaps within 8 points of any other boundary, at every zoom level.

Editing is command-shaped so undo is uniform:

```swift
public protocol TimelineCommand: Sendable {
    var name: String { get }                       // shown in Undo menu
    func apply(to timeline: inout Timeline)
}

struct SplitClip: TimelineCommand { let at: CMTime; … }
struct SetSpeed: TimelineCommand { let range: CMTimeRange; let speed: Double; … }
struct AddZoom: TimelineCommand { let region: ZoomRegion; … }
```

`UndoStack` stores whole `Timeline` values, not inverse operations. A timeline of a few thousand
value-typed regions is kilobytes; correctness beats cleverness here, and COW means the untouched
arrays are shared between snapshots.

### Auto-zoom

```swift
// TimelineKit/Analysis/ZoomSuggester.swift
public struct ZoomSuggester: Sendable {
    public struct Tuning: Sendable {
        var dwellWindow: Duration = .milliseconds(600)   // cursor must settle this long
        var travelThreshold: Double = 120                // points of movement that ends a zoom
        var minimumRegion: Duration = .seconds(1.2)
        var maximumScale: Double = 2.5
    }
    public func suggestions(cursor: [CursorSample], input: [InputSample], tuning: Tuning) -> [ZoomRegion]
}
```

The heuristic nobody documents, stated plainly: cluster click events, extend each cluster to
neighbouring dwell periods, drop clusters shorter than `minimumRegion`, merge clusters closer than
0.5 s, and set scale from the spread of cursor positions inside the cluster. Pure function over
sidecar arrays, so it is trivially testable and re-runnable with different tuning.

---

## 9. Rendering

### 9.1 The descriptor

```swift
// SceneKitten/Scene/SceneDescriptor.swift
public struct SceneDescriptor: Equatable, Sendable {
    public var outputSize: CGSize
    public var background: BackgroundDescriptor        // .color, .gradient, .image(id), .wallpaper(id)
    public var screen: ScreenLayer                     // frame rect, corner radius, shadow, crop
    public var camera: CameraTransform                 // zoom scale + centre, post-spring
    public var blurs: [BlurLayer]
    public var cursor: CursorLayer?
    public var webcam: WebcamLayer?
    public var annotations: [AnnotationLayer]
    public var caption: CaptionLayer?
}
```

`SceneBuilder.descriptor(for:at:)` is a **pure function** of `(Timeline, CMTime, motion state)`. That
is what lets preview and export share one renderer, and what makes "does the exported file match the
preview?" a unit test rather than a bug report.

### 9.2 The renderer

```swift
// SceneKitten/Render/SceneRenderer.swift
public nonisolated final class SceneRenderer {
    public init(device: MTLDevice, colorSpace: CGColorSpace)
    public func render(_ scene: SceneDescriptor, frame: CVPixelBuffer, into target: CVPixelBuffer)
}
```

Core Image is the right tool here: `CIImage` composition is GPU-backed, the filters needed already
exist, and a `CIContext(mtlDevice:)` renders straight into a `CVPixelBuffer` — the same buffer type
both `AVAssetWriterInputPixelBufferAdaptor` and `MTKView` want. The layer order per frame:

1. background — `CIConstantColorGenerator` / `CILinearGradient` / a cached wallpaper `CIImage`;
2. screen frame — source frame → crop → `CIAffineTransform` for the camera zoom → rounded-rect mask
   (`CIRoundedRectangleGenerator` as a mask, or an SDF in a small custom `CIKernel`) → drop shadow
   (`CIGaussianBlur` on the mask, offset, multiplied by shadow colour);
3. blur regions — `CIPixellate` or `CIGaussianBlur` composited through a rect/path mask, positions
   optionally tracked by `VNTrackObjectRequest` for the moving case;
4. cursor — a sprite from `CursorAtlas` at the smoothed position, scaled by
   `cursorScale × cameraScale`, with click bounce and optional motion blur;
5. webcam — cropped, mirrored, mask-shaped, shadowed, positioned, optionally scaled by camera zoom;
6. annotations — `TextRasterizer` (Core Text) and shape layers, cached per item and invalidated on
   edit;
7. caption — rasterised text with its own background pill;
8. output colour management — one `CIContext` working space, `.workingColorSpace` pinned so preview
   and export cannot drift.

Drop to a hand-written Metal pass only where Core Image measurably costs too much — a full-frame
gaussian at 4K60 is the likely candidate, and `MPSImageGaussianBlur` is the fallback before a custom
kernel.

### 9.3 Motion

```swift
// SceneKitten/Scene/CameraTransform.swift
public struct SpringState: Sendable {           // critically damped by default
    var value: Double, velocity: Double
    mutating func step(toward target: Double, dt: Double, response: Double, damping: Double)
}
```

Zoom transitions, cursor follow and webcam scaling all run through the same spring, stepped by the
frame clock — which means export must step it at the **export** frame rate, not the preview's, or
motion lands differently in the file. One `MotionState` struct, advanced by `dt`, owned by whoever
drives frames.

Cursor polish, each a pure transform over `[CursorSample]`:

| Effect | Implementation |
|---|---|
| Smoothing | one-euro filter, or a spring with a user-facing "smoothness" mapping to response |
| Click bounce | scale impulse on `mouseDown`, decayed by the spring |
| Sway | low-amplitude perpendicular offset driven by velocity direction |
| Motion blur | sample the sprite along the last N positions with decreasing alpha |
| Loop mode | ease the tail of the path back to the first sample so an exported loop has no jump |
| Size | multiplier applied before the camera scale, so zoom does not shrink the pointer |

### 9.4 Preview

`PreviewView` is an `NSViewRepresentable` over `MTKView`, driven by a `CVDisplayLink`-backed
`PlaybackClock`. The video frame comes from `AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:)`
(seek-accurate, hardware-decoded, and it handles the speed regions by driving `AVPlayer.rate`), or,
for scrubbing, from an `AVAssetImageGenerator` with a small LRU cache — the same job Recordly's
filmstrip `frameCache` does.

---

## 10. Export

```swift
// SceneKitten/Export/VideoExporter.swift
public struct ExportSettings: Sendable {
    public var size: CGSize                      // from aspect preset × resolution
    public var frameRate: Int                    // 30 / 60
    public var codec: VideoCodec                 // .h264, .hevc, .hevcWithAlpha
    public var bitrate: Int?                     // nil → quality-derived
    public var colorSpace: OutputColorSpace      // .rec709, .displayP3
    public var audio: AudioExportSettings
}

public nonisolated struct VideoExporter {
    @concurrent
    public func export(_ project: StudioProject, settings: ExportSettings,
                       to url: URL) -> AsyncThrowingStream<ExportProgress, any Error>
}
```

The loop, per output frame:

1. `SceneBuilder.descriptor(for: timeline, at: t, motion: &motion)` — same call the preview makes;
2. pull the decoded source frame for `t` (an `AVAssetReader` running ahead, not random seeks);
3. `SceneRenderer.render(_:frame:into:)` into a buffer from a `CVPixelBufferPool`;
4. `AVAssetWriterInputPixelBufferAdaptor.append(_:withPresentationTime:)`, respecting
   `isReadyForMoreMediaData`;
5. yield progress; check `Task.isCancelled` before each frame.

Encoding is `AVAssetWriter` with `AVVideoCodecType.hevc` where
`VTIsHardwareDecodeSupported`/encoder availability allows, H.264 otherwise — VideoToolbox does the
work, so there is nothing to bundle. Audio is mixed first by `AudioMixdown` using
`AVAudioEngine`'s offline manual-rendering mode (system audio + mic + imported regions, per-region
gain, clip speed applied via `AVAudioUnitTimePitch`), then muxed as an AAC track.

**GIF** goes through `ImageIO`: `CGImageDestination` with `kUTTypeGIF`, frames sampled at the chosen
GIF frame rate, `kCGImagePropertyGIFDelayTime` per frame, loop count 0 or 1, and a size preset —
plus an octree palette pass when the default quantisation is not good enough. No gifsicle.

**Caption sidecars**: `.srt` and `.vtt` written from `[CaptionCue]`, alongside burned-in rendering,
so users can upload either.

---

## 11. Captions

```swift
// KlikStudio/Captions/CaptionGenerator.swift
nonisolated struct CaptionGenerator {
    @concurrent
    func cues(for audio: URL, locale: Locale) async throws -> [CaptionCue]
}
```

macOS 26's `SpeechAnalyzer` + `SpeechTranscriber` is the primary engine: on-device, no download for
supported locales, word-level timings that map straight onto `CaptionCue`. `SFSpeechRecognizer` with
`requiresOnDeviceRecognition = true` is the macOS 14–15 path. Whisper stays a documented escape
hatch, built statically with the `Vendor/build-tesseract.sh` pattern Klik already uses and fetched as
a model pack through the same store — nothing about the design forces it up front.

Cue editing is ordinary timeline work: cues are value types, the caption row reprojects them when
clips move (Recordly's rule: source-based captions are reprojected from their original cues), and
styling (`font`, `size`, `fill`, `stroke`, `background`, `position`) lives in `CaptionStyle`.

---

## 12. Audio

- **Waveform peaks**: `WaveformBuilder` reads with `AVAssetReader` into `Float` buffers and reduces
  to min/max pairs per pixel column, `@concurrent`, writing `derived/peaks.bin`. Hot loop uses
  `.span` rather than `withUnsafeBufferPointer`, and sizes the output once instead of chaining
  `map`/`filter`.
- **Level meters** during recording: an `AVAudioEngine` tap computing RMS on the capture queue,
  published through an `AsyncStream` the HUD consumes.
- **Silence detection** for "remove silences": `SilenceDetector` over the same peak data, emitting
  candidate `SpeedRegion`s or cuts the user can accept.
- **Noise reduction**: `AVAudioUnitEQ` high-pass plus an optional `AUAudioUnit` noise gate covers the
  common case. A DeepFilter-class model is deliberately out of scope for v1 — it is a bundled binary
  and a model download for a second-order benefit.

---

## 13. Host integration (Klik core side)

```swift
// Klik/AddOns/RecordingAddOnClient.swift
@MainActor @Observable
final class RecordingAddOnClient {
    enum Availability: Equatable { case notInstalled, outdated(installed: String, required: String), ready }
    private(set) var availability: Availability = .notInstalled

    func startRecording(_ request: RecordingRequest) async throws(AddOnError)
    func cancel() async
}
```

`AddOnKit` carries the protocol both sides compile against:

```swift
public protocol StudioRecording: Sendable {
    func capabilities() async -> StudioCapabilities          // capability-first, per §5.4 of the research doc
    func beginRecording(_ request: RecordingRequest) async throws(AddOnError) -> RecordingHandle
    func cancelRecording(_ handle: RecordingHandle) async
}
```

Transport is `NSXPCConnection` to the App-Group-prefixed Mach service vended by
`KlikStudioHelper` (registered with `SMAppService`), with the launch-plus-URL-scheme fallback
described in the research doc. Finished projects land in the shared group container and are handed
to `CaptureLibrary` exactly like a screenshot; `ShareUploader` handles the share link unchanged.

Install state mirrors `LanguagePackStore`: `@Observable`, one in-flight task per add-on, catalogue
entries carrying byte length and SHA-256, and Team-ID-pinned `SecStaticCodeCheckValidity` before the
host will talk to what it found.

---

## 14. Settings, presets, shortcuts, i18n

- **Presets**: `.klikpreset` is a `Codable` `StylePreset` (background, padding, radius, shadow,
  cursor, webcam, caption style, export defaults) — a plain file, importable and shareable, the way
  `.screenstudiopreset` is.
- **Shortcuts**: `HotkeyManager` and `ShortcutRecorderView` already exist in Klik core; the add-on
  registers a record/stop hotkey next to ⌥⇧3/4/5 and its own editor shortcuts through the same
  machinery.
- **Settings**: `AppPreferences`-shaped, `@Observable`, `UserDefaults`-backed in the add-on's own
  suite so uninstalling leaves nothing behind.
- **i18n**: String Catalogs (`.xcstrings`). Both Electron tools carry 13–14 locales; Klik's existing
  language picker sets the precedent.
- **Reduced motion**: `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` damps the springs
  and disables sway — motion features must not be the reason the app is unusable for someone.

---

## 15. Permissions and entitlements

| Permission | When | API |
|---|---|---|
| Screen Recording | first recording | `CGPreflightScreenCaptureAccess()` / `SCShareableContent` probe, reusing `PermissionManager`'s flow |
| Microphone | mic enabled | `AVCaptureDevice.requestAccess(for: .audio)` |
| Camera | webcam enabled | `AVCaptureDevice.requestAccess(for: .video)` |
| Accessibility | keystroke overlay only | `AXIsProcessTrustedWithOptions` |

The add-on's own entitlements: `com.apple.security.app-sandbox`,
`com.apple.security.device.audio-input`, `com.apple.security.device.camera`,
`com.apple.security.files.user-selected.read-write`, `com.apple.security.network.client`,
`com.apple.security.application-groups` (`group.com.stackrover.klik`). Notably **not**
`disable-library-validation` — nothing is loaded dynamically, which is the whole argument for the
separate-app design.

---

## 16. Performance budget

| Path | Budget | Instrumentation |
|---|---|---|
| Capture callback | < 2 ms per frame on the capture queue | `os_signpost` interval per frame |
| Preview render | 16.6 ms at 1440p, 8.3 ms target at 60 Hz | Metal System Trace |
| Export | ≥ 1× realtime at 1080p60 on M-series | signpost per exported frame |
| Memory during recording | < 400 MB regardless of length | Allocations; nothing buffers to the end |
| Idle add-on | process not running | it exits after export |

`Logger(subsystem: "com.stackrover.klik.studio", category:)` per module, with a per-session
correlation UUID logged at `.notice`, so a user's bug report can be filtered out of a device log
archive without a reproduction — the same reason the host already logs this way.

---

## 17. Testing

Swift Testing throughout (`@Test`, `#expect`, `try #require`, `@Test(arguments:)`), matching
`KlikTests/`.

- **Timeline math** — parameterised tests over split/trim/reorder/speed, plus property tests: total
  duration is invariant under reordering; `sourceStart` never changes on a move; packing is
  idempotent. This is where Recordly's 135 sequence tests earned their keep.
- **Renderer** — golden-frame tests: a fixed `SceneDescriptor` renders to a `CVPixelBuffer` compared
  against a checked-in PNG within a tolerance. The single-renderer design means these cover export
  too.
- **Preview/export parity** — render the same descriptor through both paths and assert pixel
  equality; this is the test that keeps the core promise honest.
- **Motion** — step the spring at 30 and 60 fps and assert the same value at the same wall-clock
  time.
- **Capture** — `SessionWriter` against synthetic `CMSampleBuffer`s: idle gaps produce repeated
  frames with correct PTS, audio holes are filled with exactly the missing silence, segments close
  cleanly on abrupt stop.
- **Analysis** — `ZoomSuggester` and `SilenceDetector` over recorded fixture sidecars, asserted as
  region counts and bounds.
- **Add-on plumbing** — `AddOnRegistry` state machine, digest mismatch rejection, version handshake
  refusal, all without touching the network.

---

## 18. Milestones

| # | Deliverable | Proves |
|---|---|---|
| 1 | `AddOnKit` + registry + installer + XPC handshake; add-on does nothing but report capabilities | the optional-by-design boundary works |
| 2 | `RecordingSession` writing `.klikrec` with screen + audio + cursor sidecar | capture, pacing, sync, crash safety |
| 3 | `SceneRenderer` + preview with background, padding, radius, shadow | one renderer, real frames |
| 4 | Timeline: trim, split, speed, crop, undo | the document model |
| 5 | Zoom regions + auto-zoom + cursor polish | the reason the sidecars exist |
| 6 | Export MP4, then GIF | parity tests go green |
| 7 | Webcam overlay, annotations, blur regions | the rest of the visual feature set |
| 8 | Captions, then share through `ShareUploader` | feature parity with the open-source tools |

Each milestone is shippable on its own: the add-on can go out after #6 and gain the rest by its own
update cadence, without a Klik core release.
