import AppKit
import BackgroundKit
import CoreMedia
import Foundation
import Observation
import os
import RecordKit
import RenderKit
import TimelineKit
import UniformTypeIdentifiers

/// An open editor: a document, a playhead, and the picture at it.
///
/// The seam the architecture is built around. The document is a value; the renderer is a
/// pure function of that value and a time; this object is the small piece of state
/// between them — where the playhead is, what is selected, and what came back the last
/// time the renderer was asked.
@MainActor
@Observable
final class EditorModel {
    let document: EditorDocument
    private(set) var playhead: CMTime = .zero
    private(set) var preview: NSImage?
    /// The description the preview was drawn from.
    ///
    /// Kept because a blur rectangle is normalised to the *recording*, which sits inside
    /// the output wherever the camera puts it. Without this the overlay would have to
    /// re-derive the layout the renderer has just done, and the two would disagree the
    /// first time either of them changed.
    private(set) var scene: SceneDescriptor?
    private(set) var isPlaying = false
    /// How fast, and which way, the playhead moves while it plays: 1 for normal speed,
    /// ±2 and ±4 for the shuttle keys, negative backwards. Back to 1 on stopping. See
    /// `EditorModel+Shuttle`.
    private(set) var playbackRate: Double = 1
    private(set) var errorMessage: String?

    /// What the editor is set up to do. Drives the inspector, and — for `.crop` — what
    /// the preview is actually rendering.
    var tool: EditorTool = .frame {
        didSet {
            guard tool != oldValue else { return }
            if tool.isCanvasTool || oldValue.isCanvasTool { refresh() }
        }
    }

    /// Whether the settings panel is answering the selection rather than the tool.
    ///
    /// The panel answers whichever was asked about last. Picking something on the timeline
    /// is a question about that thing, and choosing a tool is a question about the tool —
    /// and neither should need the other put away first. It used to depend on which tool
    /// was open: with Pointer, Webcam, Captions or Audio showing, clicking a zoom or a
    /// caption selected it and changed nothing else, so its settings could not be reached
    /// without first guessing that another tool had to be chosen.
    private(set) var panelFollowsSelection = true

    /// Chooses a tool the way the person at the rail or the menu bar does: the panel
    /// turns to it, whatever is selected. The selection itself is left alone.
    func choose(_ tool: EditorTool) {
        self.tool = tool
        panelFollowsSelection = false
    }

    /// Everything picked out on the timeline, oldest first.
    ///
    /// A list rather than one thing, because a drag with three chips selected is one
    /// gesture and has to stay one: moving them apart because they were dragged one at a
    /// time is the bug this exists to prevent. Ordinary clicking still leaves exactly one
    /// in here, so every reader that wants "the selection" keeps working.
    private(set) var selected: [Selection] = [] {
        didSet {
            // However it came to be selected — a click, a paste, a split — it is now the
            // newest thing asked about.
            if selected != oldValue, !selected.isEmpty { panelFollowsSelection = true }
            // Something on the timeline is what Delete is about now, not words in the
            // transcript. See `TranscriptWordSelection`.
            if !selected.isEmpty { transcriptWords.clear() }
            // The selected annotation is drawn at rest while paused — see
            // `renderedTimeline` — so choosing a different one changes the frame.
            guard Self.annotations(in: selected) != Self.annotations(in: oldValue) else { return }
            refresh()
        }
    }

    private static func annotations(in selection: [Selection]) -> [UUID] {
        selection.compactMap { if case .annotation(let id) = $0 { id } else { nil } }
    }

    let viewport = TimelineViewport()
    let waveform: WaveformStore
    /// The waveforms of the sounds brought in from outside the recording. See
    /// `RegionWaveformStore` for why these are not the one above.
    let regionWaveforms: RegionWaveformStore
    /// Pictures of the footage for the clip lane.
    let thumbnails: ClipThumbnails
    /// The frames and filmstrips of the movies brought into the project. See
    /// `EditorModel+Media`.
    let importedMedia: ImportedMedia
    /// The pacing suggestions under review, while their sheet is up. See
    /// `EditorModel+Pacing`.
    var pacing: PacingReview?
    /// When the recording's picture was changing, once it has been measured.
    var screenActivity: [ClosedRange<Double>]?
    @ObservationIgnored var pacingTask: Task<Void, Never>?
    /// Whether the translate-captions sheet is up.
    var isTranslatingCaptions = false
    /// The words picked in the transcript. See `EditorModel+TranscriptWords`.
    let transcriptWords = TranscriptWordSelection()
    /// The edit, out loud — and, while it plays, the clock the playhead follows.
    private(set) var audio: PreviewAudio?
    /// Writes the edit back on its own, and knows whether it is written.
    let autosaver: EditorAutosaver

    private let renderer = SceneRenderer()
    private var builder: SceneBuilder
    private var frames: FrameSource?
    /// The camera's frames, when this recording has a camera. Its own source rather than a
    /// second track of the first: see `RecordingSession`'s manifest for why the two are
    /// separate files. `nil` for every recording made before the camera was recorded, which
    /// is what keeps their preview the render it always was.
    private var webcamFrames: FrameSource?
    private var renderTask: Task<Void, Never>?
    private var ticker: PlaybackTicker?
    private var lastTick: Date?

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "editor")

    /// Kept, not just read at init: auto-zoom is re-run on demand from the toolbar, and
    /// it should use what the preferences say *then*. Readable, so the menu bar — which
    /// has the editor and nothing else — can reach the same preferences.
    let settings: StudioSettings?

    init(package: RecordingPackage, settings: StudioSettings? = nil) throws {
        self.settings = settings
        document = try EditorDocument(package: package)
        autosaver = EditorAutosaver(document: document, settings: settings)
        let track = document.manifest.track(.screen)
        builder = SceneBuilder(videoSize: track?.pixelSize ?? CGSize(width: 1_920, height: 1_080),
                               displayScale: document.manifest.displayScale,
                               backgrounds: StudioBackgroundResolver(),
                               packageURL: package.url,
                               cursorArtwork: document.cursorArtwork,
                               // Where a resized window's picture went, so the black it
                               // left is cropped away in the preview and the export alike.
                               picture: document.pictureTrack)
        waveform = WaveformStore(package: package, manifest: document.manifest)
        regionWaveforms = RegionWaveformStore(package: package)
        thumbnails = ClipThumbnails(videoURL: document.videoURL,
                                    size: track?.pixelSize ?? CGSize(width: 16, height: 9))
        importedMedia = ImportedMedia(packageURL: package.url)

        if let settings {
            // A project opened for the first time starts as the user's defaults say —
            // background, padding, pointer. Applied only to an untouched document, so
            // changing a default never rewrites an edit someone already made.
            if !document.hasBeenEdited {
                document.adopt(settings.styled(document.timeline))
            }
            // Only for a recording nobody has edited. A project that was saved with no
            // zooms in it is one whose zooms were taken out on purpose, and putting them
            // back every time it is opened would be the editor arguing.
            if settings.suggestsZoomsOnOpen, !document.hasBeenEdited, document.timeline.zooms.isEmpty {
                autoZoomOnOpen = true
            }
        }
        // A take recorded with the camera on opens with the bubble showing.
        //
        // `WebcamSettings.isEnabled` defaults to `false`, which is right for the model — it
        // is what makes every project written before the bubble existed render unchanged —
        // but wrong as the first thing somebody sees after deliberately filming their face.
        // Only on a document nobody has edited, like the style defaults above, so this can
        // never turn a bubble back on that the user switched off.
        if !document.hasBeenEdited, document.manifest.track(.webcam) != nil, !document.timeline.webcam.isEnabled {
            var opened = document.timeline
            opened.webcam.isEnabled = true
            document.adopt(opened)
        }
        // The shortcuts the recorder saw, as where the project starts rather than as an
        // edit — see `EditorDocument.adoptRecordedKeys`.
        document.adoptRecordedKeys()
        Task { await openSource() }
    }

    /// Set at init, run once the frame source is up, so the zooms it proposes are
    /// measured against the real picture size rather than the manifest's guess.
    private var autoZoomOnOpen = false

    var timeline: Timeline { document.timeline }
    var duration: CMTime { document.timeline.duration }
    var isDirty: Bool { document.isDirty }
    var name: String { document.manifest.name }
    var videoSize: CGSize { builder.videoSize }
    var packageURL: URL { document.package.url }

    /// The recording's size in the points the pointer and clicks are measured in, when the
    /// manifest says.
    var recordedFrame: CGSize? {
        guard let size = document.manifest.track(.screen)?.pixelSize else { return nil }
        let scale = document.manifest.displayScale
        guard scale > 0 else { return nil }
        return CGSize(width: size.width / scale, height: size.height / scale)
    }

    /// Whether this recording kept a picture of the pointer it actually had.
    ///
    /// Read from the package rather than assumed from the version: a recording made with
    /// the setting off has none, and neither does one made before it existed.
    var hasRecordedPointer: Bool { !document.cursorArtwork.isEmpty }

    /// Whether the recording captured a given track. Read from the manifest rather than
    /// the asset, which is the reason the manifest lists them.
    func hasTrack(_ kind: RecordingManifest.Track.Kind) -> Bool {
        document.manifest.track(kind) != nil
    }

    /// The finished frame's size, which is what a crop changes and what the inspector
    /// reports so a heavy crop is not a silent loss of resolution.
    var outputSize: CGSize { builder.outputSize(for: timeline.style) }
    var croppedVideoSize: CGSize { builder.croppedVideoSize(for: timeline.style) }
    /// The builder the preview and the export share, for a still of one frame — see
    /// `EditorModel+FrameStill`. Measured against the real picture once it has been read.
    var sceneBuilder: SceneBuilder { builder }

    /// The frame source is opened after init so the window can appear immediately: a
    /// recording is on disk, and waiting on `AVAsset` to load its tracks before showing
    /// anything is a stall the user reads as a hang.
    private func openSource() async {
        guard let url = document.videoURL else {
            errorMessage = "This recording's video file is missing."
            return
        }
        do {
            let source = try await FrameSource(url: url)
            frames = source
            builder = SceneBuilder(videoSize: source.naturalSize,
                                   displayScale: document.manifest.displayScale,
                                   backgrounds: StudioBackgroundResolver(),
                                   packageURL: document.package.url,
                                   cursorArtwork: document.cursorArtwork,
                                   picture: document.pictureTrack)
            if autoZoomOnOpen {
                autoZoomOnOpen = false
                adoptSuggestedZooms()
            }
            refresh()
            waveform.load(videoURL: url)
            // Built here rather than in `init`, for the same reason the frame source is:
            // it needs the recording, and the window should be up before either is read.
            let audio = PreviewAudio(videoURL: url, packageURL: document.package.url,
                                     clicks: document.cursorTrack.clicks,
                                     clickFrame: recordedFrame,
                                     picture: document.pictureTrack,
                                     settings: settings)
            audio.prepare(for: timeline)
            self.audio = audio
            await openWebcamSource()
        } catch {
            errorMessage = error.localizedDescription
            Self.log.error("Couldn't open \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Playhead

    func scrub(to time: CMTime) {
        playhead = max(.zero, min(time, duration))
        audio?.follow(playhead)
        // Not while the pointer is holding it. `reveal` scrolls the timeline to keep the
        // playhead in view, which is right when playback walks it off the edge and wrong
        // while somebody is dragging it: scrolling moves the ruler under the pointer, the
        // pointer is then over a different time, and the playhead chases it. That is a
        // feedback loop, and it reads as the head stuttering and running away.
        if !isScrubbing { viewport.reveal(playhead, duration: duration) }
        refresh()
    }

    // MARK: - Scrubbing

    /// Whether the playhead is being dragged right now.
    ///
    /// Three things read it: the autoscroll above, the preview's fidelity, and the decode
    /// quality. A drag produces pointer events far faster than a 4K frame decodes, and
    /// asking for an exact one at full resolution per event is the single most expensive
    /// thing the editor can be asked to do — it is the same bargain playback already makes,
    /// and a drag has exactly as little use for the detail.
    private(set) var isScrubbing = false

    /// Takes hold of the playhead.
    ///
    /// Playback stops. A drag and a ticker both writing the playhead is two hands on one
    /// control: the picture would jump between where the pointer is and where the clock
    /// thinks it should be, several times a second. Stopping is also what the user means —
    /// reaching for the playhead is reaching for a particular frame.
    func beginScrub() {
        guard !isScrubbing else { return }
        if isPlaying { togglePlayback() }
        isScrubbing = true
        viewport.followsPlayhead = false
        Task { [weak self] in
            guard let self else { return }
            await frames?.setQuality(.preview(previewPixelSize))
        }
    }

    /// Lets go, and draws the frame properly once.
    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        Task { [weak self] in
            guard let self else { return }
            await frames?.setQuality(.exact)
            // `isScrubbing` is already false, so this is full fidelity: the frame the
            // export would write, which is what the user is now looking at rather than
            // dragging past.
            refresh()
        }
    }

    func step(_ seconds: Double) {
        scrub(to: playhead + CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// How long one frame of this recording lasts.
    ///
    /// Read from the recording rather than assumed. "Next frame" used to move a thirtieth
    /// of a second whatever had been recorded, and most takes are recorded at sixty — so
    /// every press skipped a frame, and the one a click landed on could not be reached.
    var frameDuration: Double {
        let rate = document.manifest.track(.screen)?.frameRate ?? 60
        return 1 / Double(max(1, rate))
    }

    /// One frame on or back, landing on a frame rather than beside one.
    func stepFrame(forward: Bool) {
        let frame = frameDuration
        let index = (playhead.seconds / frame).rounded() + (forward ? 1 : -1)
        scrub(to: CMTime(seconds: max(0, index * frame), preferredTimescale: 6_000))
    }

    /// The cut before or after the playhead — ⌥← and ⌥→.
    func stepToBoundary(forward: Bool) {
        let edges = timeline.boundaries.sorted()
        let target = forward
            ? edges.first { $0 > playhead + CMTime(value: 1, timescale: 100) }
            : edges.last { $0 < playhead - CMTime(value: 1, timescale: 100) }
        scrub(to: target ?? (forward ? duration : .zero))
    }

    /// Plays by moving the playhead on a display link and re-rendering when it can.
    ///
    /// The playhead advances every refresh; the picture is only re-rendered when the
    /// last render has finished. That decoupling is what stops the whole timeline
    /// stuttering at whatever rate a 4K frame happens to decode. Real frame-accurate
    /// playback with sound needs a composition, which is the exporter's workstream.
    func togglePlayback() {
        isPlaying ? stop() : play()
    }

    private func play(rate: Double = 1) {
        guard frames != nil else { return }
        playbackRate = rate
        // Off the end in the direction of travel means starting again from the other end.
        if rate > 0, playhead >= duration { playhead = .zero }
        if rate < 0, playhead <= .zero { playhead = duration }
        // Playing answers the question framing mode was asking, so the framing box gets out
        // of the way and stays out of it. Left in `.framing`, pressing pause would snap the
        // picture back to the un-zoomed recording the instant it stopped — the camera state
        // the user had just watched arrive, thrown away by the act of stopping to look at
        // it. See `ZoomPreview`.
        if case .zoom = selection { zoomPreview = .result }
        isPlaying = true
        lastTick = .now
        viewport.followsPlayhead = true
        // Sound only at normal speed, forwards — see `EditorModel+Shuttle` for why.
        if rate == 1 { audio?.play(from: playhead, timeline: timeline) } else { audio?.pause() }
        // The framing box is gone now, which means the rendered timeline has its zooms
        // back: the very first frame of playback has to be described again or it would be
        // the flat one the box was drawn over.
        refresh()
        Task { await frames?.setQuality(.preview(previewPixelSize)) }

        ticker = PlaybackTicker { [weak self] in
            guard let self, let last = self.lastTick else { return }
            let now = Date.now
            self.lastTick = now
            // The sound is the clock when there is sound. A wall-clock playhead drifts
            // against the audio over a long take — slowly, and then unmistakably, because
            // one of them is being resampled by a real audio device and the other is not.
            // The picture may drop a frame; the sound may not, so the picture follows it.
            // At any rate but 1 the sound is paused and its clock is `nil`, so the wall
            // clock keeps time, scaled — and runs the playhead backwards for a negative
            // rate, which is the only way this player plays backwards: every frame shown
            // is a seek. See `EditorModel+Shuttle`.
            let next = self.audio?.clock
                ?? self.playhead + CMTime(seconds: now.timeIntervalSince(last) * self.playbackRate,
                                          preferredTimescale: 600)
            if self.playbackRate < 0, next <= .zero {
                self.playhead = .zero
                self.stop()
            } else if next >= self.duration {
                self.playhead = self.duration
                self.stop()
            } else {
                self.playhead = next
                self.viewport.reveal(self.playhead, duration: self.duration)
                // `refresh` coalesces, so the ticker can simply say what the playhead is now
                // and let it decide whether that is a frame worth drawing. It used to have to
                // ask whether a render was in flight, which meant this tick's playhead was
                // thrown away rather than remembered.
                self.refresh()
            }
        }
    }

    private func stop() {
        isPlaying = false
        // The rate is a property of playing, not of the editor: stopping puts it back.
        playbackRate = 1
        // Playback stopping ends a take, whether the playhead ran into the end of the edit
        // or somebody pressed space: narration is recorded against the picture, and going
        // on recording while the picture stands still would be recording against nothing.
        voiceover?.stop()
        audio?.pause()
        ticker?.stop()
        ticker = nil
        lastTick = nil
        Task { [weak self] in
            await self?.frames?.setQuality(.exact)
            // The one render that has to be perfect. Playback is over, `isPlaying` is
            // already false, so `previewFidelity` is 1 and this draws the frame the export
            // would write — byte for byte, which `RenderFidelityTests` is the guarantee of.
            self?.refresh()
        }
    }

    /// Plays at a rate, or changes the rate of playback already running. The shuttle
    /// keys' one door into playback; the rule for which rate comes next is theirs.
    func setPlaybackRate(_ rate: Double) {
        guard isPlaying else {
            play(rate: rate)
            return
        }
        playbackRate = rate
        // The wall clock takes over from here, not from the last tick the sound drove.
        lastTick = .now
        if rate == 1 { audio?.play(from: playhead, timeline: timeline) } else { audio?.pause() }
    }

    /// Roughly what the preview pane can show. Seeking a full-resolution 4K frame with
    /// zero tolerance thirty times a second is the single most expensive thing the
    /// editor used to do, and none of that detail reaches the screen while it moves.
    private var previewPixelSize: CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: 1_280 * scale, height: 720 * scale)
    }

    // MARK: - Rendering

    /// How big the preview pane is, in points, as SwiftUI last laid it out.
    ///
    /// Reported by `PreviewPane` rather than guessed, because the whole point is to
    /// composite at the size that is actually going to be looked at, and that depends on
    /// the window and on where the user has dragged the inspector's divider.
    ///
    /// `@ObservationIgnored` on purpose: it is written from a layout callback, and a stored
    /// property the view both reads and writes during layout is a loop. Nothing observes
    /// it — it only affects the *next* render, and the next render is already coming.
    @ObservationIgnored private var previewPaneSize: CGSize = .zero

    func previewPaneResized(to size: CGSize) {
        previewPaneSize = size
    }

    /// The fraction of the project's resolution the preview composites at.
    ///
    /// 1 whenever the picture is standing still, which is the rule the export's fidelity
    /// depends on: the moment playback stops, the frame on screen is the frame in the file.
    /// While it plays, the size of the pane — a 4K project in a 900-point-wide pane on a 2×
    /// display needs 1800 pixels across, not 3840, and the window server would throw the
    /// rest away.
    ///
    /// Quantised to eighths rather than taken exactly, because the background cache and
    /// Core Image's own kernels are keyed by size: a factor that drifted by a pixel with
    /// every window resize would miss every cache it has, and would spend more on rebuilding
    /// a gradient than it saved on compositing one.
    private var previewFidelity: Double {
        guard isPlaying || isScrubbing else { return 1 }
        let output = previewSize
        guard output.width > 1, previewPaneSize.width > 1 else { return 1 }
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let wanted = max(previewPaneSize.width * backing / output.width,
                         previewPaneSize.height * backing / output.height)
        // Never below an eighth: past that the picture stops being a preview of anything,
        // and the cost is by then dominated by the decode rather than by the composite.
        return min(1, max(0.125, (wanted * 8).rounded(.up) / 8))
    }

    /// Whether a playhead change arrived while a render was in flight.
    ///
    /// The scrub coalescer. A drag produces events far faster than a frame decodes, and the
    /// only frame that matters is the one under the pointer *now* — so a request that lands
    /// on a busy renderer is remembered as "there is newer work" rather than started, and
    /// picked up when the current frame lands. Cancelling instead, which is what this
    /// replaced, could not help: a cancelled `Task` does not stop a decode already inside
    /// `AVAssetImageGenerator`, so the work happened anyway and the frame the pointer was
    /// over came back last.
    @ObservationIgnored private var hasPendingRender = false

    /// Re-renders the frame under the playhead.
    ///
    /// One render in flight at a time, and one remembered behind it. The synchronous half —
    /// describing the frame — runs on every call, because the overlays read `scene` and must
    /// track the pointer without waiting for a decode; it costs a few microseconds. The
    /// asynchronous half is what gets coalesced.
    func refresh() {
        validateSelection()
        // Here rather than at each place a sound is added, because there are four of them
        // — an import, a voiceover, a paste, an undo — and the list of sounds the edit
        // names is the only thing any of them has in common. Cheap on the ordinary path.
        // The recording's own sources are in here too, and not as an afterthought: each
        // lane draws its own file's peaks, and this store is already the thing that reads a
        // waveform per path and caches it in the package.
        // Skipped mid-gesture: dragging a chip cannot add or remove a sound, and building
        // the list to find that out is two array allocations and a `Set` per frame.
        if !document.isInteracting {
            regionWaveforms.reconcile(paths: timeline.audio.map(\.path) + timeline.soundTracks.map(\.path))
        }
        let scene = builder.descriptor(for: renderedTimeline, at: playhead, cursor: smoothedCursor)
        // Kept at full size whatever the preview draws at: this is the description of the
        // frame the export would write, and the overlays map their handles through its
        // `outputSize`. A scaled copy would work for them too, since everything they read is
        // a ratio — but "what the file will contain" is the more useful thing to publish.
        self.scene = scene

        // Nothing to redraw: the zoom being dragged is not in the rendered timeline, so
        // every frame of a framing drag would decode the same source frame and composite
        // the same output. See `isFramingDrag`.
        guard !isFramingDrag else { return }

        guard renderTask == nil else {
            hasPendingRender = true
            return
        }
        startRender(of: scene)
    }

    private func startRender(of scene: SceneDescriptor) {
        let frames = frames
        // A movie brought into the project is read at the quality the recording is being
        // read at, so a scrub across a cut into one is as quick as a scrub within the take.
        let media = importedMedia
        let quality: FrameSource.Quality = isPlaying || isScrubbing ? .preview(previewPixelSize) : .exact
        // The only place the preview is allowed to differ from the export, and only while
        // the picture is moving.
        let drawn = scene.scaled(by: previewFidelity)
        // Only asked for when the frame being built actually has a bubble in it. The crop
        // tool's flattened preview describes no webcam layer, and neither does a project
        // with the camera switched off — in both cases a seek into the camera's file would be
        // a decode nobody looks at.
        let webcamFrames = drawn.webcam == nil ? nil : webcamFrames
        // The other side of a crossfade, when this frame is in one: its own moment of the
        // same two files. See `SceneBlend`.
        let lent = drawn.blendedScene.flatMap { $0.showsRecording ? $0 : nil }
        let lentWebcamFrames = lent?.webcam == nil ? nil : self.webcamFrames

        renderTask = Task { [renderer] in
            defer {
                renderTask = nil
                if hasPendingRender {
                    hasPendingRender = false
                    // Re-described rather than replayed: by now the playhead has moved on, and
                    // the frame worth drawing is the one it is over now.
                    refresh()
                }
            }
            // A title shows no recording, so there is no frame of it to decode. A clip of
            // another file is read from that file.
            let source: CIImage? = if !drawn.showsRecording {
                nil
            } else if let path = drawn.sourceMedia {
                await media.frame(from: path, at: drawn.sourceTime, quality: quality)
            } else {
                await frames?.frame(at: drawn.sourceTime)
            }
            // The same source time as the screen: the two files were written against one
            // clock, so one moment in the edit is one moment in both of them.
            let camera = await webcamFrames?.frame(at: drawn.sourceTime)
            var blending: CIImage?
            var blendingCamera: CIImage?
            if let lent {
                if let path = lent.sourceMedia {
                    blending = await media.frame(from: path, at: lent.sourceTime, quality: quality)
                } else {
                    blending = await frames?.frame(at: lent.sourceTime)
                    blendingCamera = await lentWebcamFrames?.frame(at: lent.sourceTime)
                }
            }
            guard !Task.isCancelled else { return }
            let image = renderer.cgImage(for: drawn, source: source, webcam: camera,
                                         blending: blending, blendingWebcam: blendingCamera)
            guard !Task.isCancelled, let image else { return }
            // Sized in the *full* frame's points even when the pixels are fewer, so the pane's
            // layout and its aspect-fit arithmetic do not move when the fidelity does. The
            // picture gets softer; nothing shifts.
            preview = NSImage(cgImage: image, size: scene.outputSize)
            // Skipped when a scrub is already waiting: warming the frames around a moment
            // nobody is looking at any more is exactly the backlog this is trying not to
            // build. Playback is the other way round — it is heading straight for those
            // frames, so it pays for them gladly.
            guard isPlaying || !hasPendingRender else { return }
            if let path = drawn.sourceMedia {
                await media.prefetch(from: path, around: drawn.sourceTime, forward: isPlaying && playbackRate > 0)
            } else {
                await frames?.prefetch(around: drawn.sourceTime, forward: isPlaying && playbackRate > 0)
            }
        }
    }

    /// The recorded pointer, smoothed, computed only when it has to be.
    ///
    /// Smoothing filters every sample in the recording twice — 150,000 of them in a long
    /// take. It used to happen inside the builder, which meant redoing it on every
    /// preview frame and every exported frame; scrubbing a long recording spent most of
    /// its time re-filtering a track that had not changed. Cached against the setting it
    /// was made with, so moving the slider still takes effect immediately.
    private var smoothedCursor: CursorTrack {
        let amount = timeline.cursor.smoothing
        if let cache = cursorCache, cache.amount == amount { return cache.track }
        let track = document.cursorTrack.smoothed(amount)
        cursorCache = (amount, track)
        return track
    }

    @ObservationIgnored private var cursorCache: (amount: Double, track: CursorTrack)?

    /// What the preview is showing, which is not always the edit.
    ///
    /// Cropping is direct manipulation of the source frame, and the composited picture —
    /// padded, rounded, zoomed, already cropped — is not a thing you can drag a crop
    /// rectangle over. In crop mode the preview shows the whole recording, flat, so the
    /// mapping from a point on screen to a point in the footage is one aspect-fit.
    private var renderedTimeline: Timeline {
        var draft = timeline
        // The label being typed into is drawn by the text field on the canvas, so the
        // renderer must not draw it as well. It did, and the two were never in the same
        // place: the field sized its font off the box on screen while the renderer sized it
        // off the finished frame, so typing produced a second, differently-sized copy of
        // the words sitting across the first.
        if let editing = editingAnnotation {
            draft.annotations.removeAll { $0.id == editing }
        }
        // The annotation being worked on is shown at full strength while paused.
        //
        // Otherwise the frame you are looking at decides whether you can see what you are
        // editing: a new annotation starts at the playhead, and its first frame is the first
        // frame of its fade — opacity zero. Typing into it changed nothing on the picture.
        // Playing puts the entrance and exit back, and the export always has them, so this
        // is a way of looking at the edit, not a change to it.
        if !isPlaying {
            let working = Set(Self.annotations(in: selected))
            for index in draft.annotations.indices where working.contains(draft.annotations[index].id) {
                draft.annotations[index].animation.entrance = .none
                draft.annotations[index].animation.exit = .none
            }
        }
        // Framing a zoom: the camera comes out and *nothing else does*.
        //
        // A framing box drawn over a picture the zoom has already been applied to would
        // always be the whole picture — the tool would be showing its own answer and
        // refusing the question — so the zooms have to go. The padding, the corners, the
        // shadow and the background stay, which is the difference between this and the crop
        // tool below: those are not in the way of a rectangle *of the recording*, and
        // stripping them made switching into framing look like a different video. The
        // output size is unchanged too, so the picture does not resize underneath the box.
        if isFramingZoom {
            draft.zooms = []
            // The camera goes back to its bubble too: a stretch of Camera Only would hide the
            // very picture the box is being drawn over.
            draft.cameraLayouts = []
            return draft
        }
        guard tool.flattensPreview else { return draft }
        // No camera at all on the flat picture, which is what `startRender` already assumed
        // it described: the bubble covered part of the recording being cropped, and a
        // stretch of Camera Only would have covered all of it.
        draft.webcam.isEnabled = false
        draft.cameraLayouts = []
        draft.style.crop = nil
        draft.style.aspect = .source
        draft.style.padding = 0
        draft.style.cornerRadius = 0
        draft.style.shadowOpacity = 0
        draft.style.borderWidth = 0
        // Square-on and bare, too. The crop overlay maps the stage straight onto the
        // recording, which is only true of a picture with nothing round it and nothing
        // turning it: a window's bar or a phone round it shrank the picture under the
        // handles, and a perspective turned it out from under them.
        draft.style.chrome.kind = .none
        draft.style.perspective = FramePerspective()
        draft.style.background = .color(ColorValue(r: 0.06, g: 0.06, b: 0.07))
        draft.zooms = []
        return draft
    }

    /// The label being typed into, if any — see `renderedTimeline`.
    ///
    /// Re-renders on the way in and on the way out, because it changes what the frame
    /// contains: without that the renderer's copy of the words would stay on screen until
    /// the next keystroke happened to redraw it, which is a double image that appears and
    /// disappears depending on how fast you type.
    var editingAnnotation: UUID? {
        didSet {
            guard editingAnnotation != oldValue else { return }
            refresh()
        }
    }

    /// The preview's own frame size, which differs from the export's while cropping.
    var previewSize: CGSize {
        builder.outputSize(for: renderedTimeline.style)
    }

    // MARK: - Selection

    /// What the inspector is about: the thing most recently picked.
    ///
    /// The *last* rather than the first, because that is the one the user just clicked, and
    /// a panel that jumps back to the first thing they selected five clicks ago would be a
    /// panel about a decision they have moved on from.
    var selection: Selection { selected.last ?? .none }

    /// Whether this is one of the things picked out — which is not the same question as
    /// `selection == x` once more than one thing can be.
    func isSelected(_ selection: Selection) -> Bool {
        selected.contains(selection)
    }

    var hasMultipleSelected: Bool { selected.count > 1 }

    /// Picks something out, or — holding ⌘ — adds it to what is already picked.
    ///
    /// Toggling rather than only adding, so ⌘-clicking something twice puts it back the way
    /// it was. That is what every list on this platform does, and a timeline that only ever
    /// grew a selection would need a second gesture to undo a misclick.
    func select(_ selection: Selection, extending: Bool = false) {
        // Clicking what is already selected is still asking about it.
        if !selection.isEmpty { panelFollowsSelection = true }
        guard extending else {
            guard selected != [selection] else { return }
            let wasZoom = self.selection
            selected = [selection]
            // Picking a *different* zoom is a question about that zoom, and the answer it
            // wants is the framing box. Without this, playing once — which pushes the
            // preview to Result and leaves it there, deliberately — would mean every chip
            // clicked afterwards showed a zoomed picture and no way to edit it, which is
            // the whole feature quietly switching itself off.
            if case .zoom = selection, selection != wasZoom { zoomPreview = .framing }
            return
        }
        if let index = selected.firstIndex(of: selection) {
            selected.remove(at: index)
        } else {
            selected.append(selection)
        }
    }

    /// Everything picked out that can be dragged as one: regions and runs, never a clip.
    ///
    /// A clip has no position of its own — the sequence is contiguous by construction — so
    /// it cannot be slid, and silently dragging the regions while the clips stayed put
    /// would be a group drag that only half happened.
    var draggableSelection: [Selection] {
        selected.filter { $0.regionID != nil }
    }

    func clearSelection() { selected = [] }

    /// Drops a selection that an edit has invalidated.
    ///
    /// Needed because `ClipSequence.clampRegions` quietly removes any region an edit
    /// shortened past `Clip.minimumDuration` — a selection can stop being valid without
    /// anything having deleted it.
    private func validateSelection() {
        selected.removeAll { !$0.isValid(in: timeline) }
    }

    // MARK: - Dragging

    /// The drag in progress, if any. See `TimelineDrag` for why it is not the document.
    let drag = TimelineDrag()
    /// What the finished drag will be called on the undo stack.
    @ObservationIgnored private var dragName = "Move"

    /// Takes hold of everything selected, anchored on the thing under the pointer.
    ///
    /// A drag on something that was not selected selects it first and drops everything
    /// else, which is what every list on this platform does: you cannot drag one thing out
    /// of a selection it is not part of. A drag on something that *is* selected carries the
    /// whole selection, which is the point of being able to pick several.
    func beginDrag(anchor: Selection, grip: TimelineDrag.Grip) {
        if !isSelected(anchor) { select(anchor) }
        // The one under the pointer goes first, because that is the one snapping steers by
        // — and steering a group by whichever chip happened to be selected first would snap
        // an edge the user cannot see to a cut they were not aiming at.
        let picks = [anchor] + draggableSelection.filter { $0 != anchor }
        let items: [TimelineDrag.Item] = picks.compactMap { pick in
            guard let id = pick.regionID, let range = pick.range(in: timeline) else { return nil }
            var isRun = false
            if case .soundRun = pick { isRun = true }
            return TimelineDrag.Item(id: id, start: range.start,
                                     duration: range.duration, isSoundRun: isRun)
        }
        guard !items.isEmpty else { return }
        dragName = switch grip {
        case .body: items.count > 1 ? "Move \(items.count) Items" : "Move"
        case .head, .tail: items.count > 1 ? "Resize \(items.count) Items" : "Resize"
        }
        drag.begin(items, grip: grip, in: timeline)
    }

    /// Whether the pointer is in the middle of something — a drag on the timeline, a trim,
    /// a slider, a handle on the picture.
    ///
    /// Read by the lanes to stop reacting to hover while a gesture runs. A chip sliding
    /// under a stationary pointer fires hover on and off continuously, and each one flipped
    /// a handle through a fade and pushed or popped a cursor: from the outside that is the
    /// chip flashing as it moves.
    var isGesturing: Bool { drag.isActive || document.isInteracting }

    /// The offset the gesture has reached, snapped unless ⌃ is held.
    ///
    /// Snapped on the item the pointer took hold of and then applied to every item in the
    /// drag, so a group keeps its shape: snapping each item to its own nearest edge would
    /// pull a group apart the first time two of them were near different cuts.
    ///
    /// ⌃ rather than ⌘ for free positioning, because ⌘ is now how a selection is extended
    /// and one modifier cannot mean two things in one gesture.
    func dragOffset(_ raw: CMTime, pointsPerSecond: Double) {
        guard let grip = drag.grip, let anchor = drag.items.first else { return }
        guard !NSEvent.modifierFlags.contains(.control) else {
            drag.update(offset: raw)
            return
        }
        let snapping = Snapping(pointsPerSecond: pointsPerSecond)
        // The edge the pointer is actually steering. Snapping the other one would stick the
        // chip to a cut it is moving away from.
        let held = switch grip {
        case .body, .head: anchor.start
        case .tail: anchor.end
        }
        let dragged = held + raw
        let targets = timeline.boundaries.filter { $0 != anchor.start && $0 != anchor.end }
        drag.update(offset: snapping.snap(dragged, to: targets) - held)
    }

    /// Lets go, and tells the document where everything landed — once.
    func endDrag() {
        let moves = drag.end()
        guard !moves.isEmpty else { return }
        apply(Commands.MoveMany(moves, name: dragName))
    }

    /// Where a region sits right now: mid-drag that is the gesture's answer, otherwise the
    /// document's.
    ///
    /// Every lane draws through this, which is what keeps a dragged chip and an undragged
    /// one from being positioned by two different rules.
    func liveRange(of id: UUID, start: CMTime, duration: CMTime) -> (start: CMTime, duration: CMTime) {
        drag.geometry(of: id) ?? (start, duration)
    }

    /// Whether Delete would do anything, so the menu item can be honest about it.
    var canDeleteSelection: Bool {
        if !transcriptWords.isEmpty { return canCutWords }
        if hasMultipleSelected { return selected.contains { $0.regionID != nil } }
        return switch selection {
        case .none, .headTrim, .tailTrim, .sound: false
        case .clip: timeline.clips.count > 1
        case .range(let range): range.duration > .zero
        default: true
        }
    }

    func deleteSelection() {
        // Words picked in the transcript are cut from the video: that is what Delete means
        // to a transcript.
        if !transcriptWords.isEmpty {
            cutPickedWords()
            return
        }
        // Several at once is one edit and one undo entry, like the group drag above it.
        if hasMultipleSelected {
            let ids = selected.compactMap(\.regionID)
            guard !ids.isEmpty else { return }
            document.beginInteraction("Delete")
            for id in ids { apply(Commands.DeleteRegion(id: id)) }
            finishInteraction()
            clearSelection()
            return
        }
        switch selection {
        case .clip(let id):
            // The last clip cannot go: `ClipSequence.delete` refuses to empty a timeline,
            // and a Delete that silently does nothing is worse than a disabled one.
            guard timeline.clips.count > 1,
                  let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
            apply(Commands.DeleteRange(CMTimeRange(start: timeline.start(ofClipAt: index),
                                                   duration: timeline.clips[index].duration)))
        case .range(let range):
            apply(Commands.DeleteRange(range))
        case .none, .headTrim, .tailTrim:
            return
        default:
            guard let id = selection.regionID else { return }
            apply(Commands.DeleteRegion(id: id))
        }
        clearSelection()
    }

    func selectAll() {
        guard duration > .zero else { return }
        select(.range(CMTimeRange(start: .zero, duration: duration)))
    }

    // MARK: - Clipboard

    /// What Copy would put on the pasteboard, or `nil` if there is nothing to put there.
    ///
    /// Computed from the selection each time rather than cached: the selection can stop
    /// being valid without anything having deleted it (see `validateSelection`), and a
    /// stale copy of a region that no longer exists is exactly the thing this must not
    /// hand out.
    private var copyable: CopiedRegion? { CopiedRegion(selection, in: timeline) }

    /// Whether Cut, Copy and Duplicate would do anything.
    ///
    /// One answer for all three because they all need the same thing: something to copy.
    /// Either half of the clipboard will do — a region, or the footage under a selected clip
    /// or range — and which one it is only matters once the verb runs.
    var canCopySelection: Bool { copyable != nil || copyableFootage != nil }

    /// Whether Paste would do anything.
    var canPasteRegion: Bool {
        RegionPasteboard.shared.hasRegion || RegionPasteboard.shared.hasFootage
    }

    func copySelection() { copyRegion(selection) }

    func cutSelection() { cutRegion(selection) }

    func duplicateSelection() { duplicateRegion(selection) }

    /// Copies whatever a selection points at, whether or not it is the current one.
    ///
    /// The `(_ selection:)` forms exist for the timeline's context menu, which acts on the
    /// region the pointer is over. Making it select that region first would mean a
    /// right-click quietly changed what the inspector is showing, which is not what a
    /// context menu is for.
    func copyRegion(_ selection: Selection) {
        guard let region = CopiedRegion(selection, in: timeline) else {
            copyFootage(selection)
            return
        }
        RegionPasteboard.shared.write(region)
    }

    func cutRegion(_ selection: Selection) {
        guard let region = CopiedRegion(selection, in: timeline) else {
            cutFootage(selection)
            return
        }
        // Written before the delete, so a failed encode leaves the region where it is
        // rather than removing something the user can no longer paste back.
        RegionPasteboard.shared.write(region)
        apply(Commands.DeleteRegion(id: region.id))
        selected.removeAll { $0 == selection }
    }

    /// A copy of the pasteboard's region, at the playhead.
    ///
    /// The playhead rather than where the original was, because the playhead is where the
    /// user is looking and pasting on top of the original would make ⌘C ⌘V look like it
    /// did nothing. Length, scale, easing and everything else are kept; only the identity
    /// and the position are new.
    func pasteAtPlayhead() {
        // Footage first, because the two payloads never share a pasteboard — a copy of
        // either clears it — so finding footage means footage is what was copied.
        guard let copied = RegionPasteboard.shared.read() else {
            pasteFootageAtPlayhead()
            return
        }
        // A sound's path is relative to its own project package, so one copied out of
        // another take names a file this project does not have. Refused rather than
        // pasted, because a silent region that cannot be made to play is worse than a
        // paste that explains itself. Bringing the file across is `SoundImport`'s job and
        // a larger change than a paste.
        if let path = copied.audioPath,
           !FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(path).path) {
            errorMessage = "That sound belongs to another recording. Add it to this one with Add Sound…"
            return
        }
        // Pictures the same way, and for the same reason: pasted, it would be invisible.
        if let path = copied.picturePath,
           !FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(path).path) {
            errorMessage = "That picture belongs to another recording. Add it to this one with Picture… or Logo…"
            return
        }
        guard let placed = copied.placed(at: playhead, in: timeline) else { return }
        apply(Commands.InsertRegion(placed, name: "Paste \(placed.title)"))
        select(placed.selection)
    }

    /// A copy of a region, immediately after it.
    ///
    /// After rather than on top of, so the duplicate is visible and draggable the moment
    /// it appears. Near the end of the edit there is no room for that, and `placed` pulls
    /// it back inside — which leaves it overlapping the original, but on screen and
    /// selected rather than somewhere the timeline cannot show.
    func duplicateRegion(_ selection: Selection) {
        guard let region = CopiedRegion(selection, in: timeline) else {
            duplicateFootage(selection)
            return
        }
        guard let placed = region.placed(at: region.end, in: timeline) else { return }
        apply(Commands.InsertRegion(placed, name: "Duplicate \(placed.title)"))
        select(placed.selection)
    }

    // MARK: - Clipboard: footage

    /// The footage half of the clipboard, kept in one block below the region half rather
    /// than interleaved with it.
    ///
    /// Every verb above asks `CopiedRegion` first and falls through to here, which works
    /// because the two initialisers divide every `Selection` between them: a zoom is never
    /// footage and a clip is never a region. So "did the region half refuse?" is a complete
    /// test for "is this footage?", and neither half has to enumerate the other's cases.

    /// What Copy would put on the pasteboard when the selection is footage.
    ///
    /// Computed each time for the reason `copyable` is: a selection can stop being valid
    /// without anything having deleted it, and a stale stretch of an edit is exactly what
    /// this must not hand out.
    private var copyableFootage: CopiedFootage? { CopiedFootage(selection, in: timeline) }

    func copyFootage(_ selection: Selection) {
        guard let footage = CopiedFootage(selection, in: timeline) else { return }
        RegionPasteboard.shared.write(footage)
    }

    /// Cut footage: copy it, then ripple-delete the stretch it came from.
    ///
    /// Two commands' worth of meaning and one edit, which is why it goes through
    /// `Commands.DeleteRange` rather than `DeleteRegion` — closing the gap is the whole
    /// difference between cutting footage and cutting a region, and it is the operation
    /// pasting is the inverse of.
    ///
    /// Written to the pasteboard before the delete, the same order `cutRegion` uses and for
    /// the same reason: a failed encode must leave the footage where it is rather than
    /// removing something the user can no longer paste back.
    func cutFootage(_ selection: Selection) {
        guard let footage = CopiedFootage(selection, in: timeline),
              let range = selection.range(in: timeline) else { return }
        RegionPasteboard.shared.write(footage)
        apply(Commands.DeleteRange(range))
        selected.removeAll { $0 == selection }
    }

    /// A copy of the pasteboard's footage, inserted at the playhead.
    ///
    /// The playhead rather than where it came from, for the reason a region paste uses it:
    /// it is where the user is looking. Unlike a region paste this makes the edit *longer*,
    /// and everything after the playhead moves along with the footage it was placed against
    /// — `ClipSequence.insert` is that arithmetic, and the comment there is the argument for
    /// what travels and what is stretched.
    ///
    /// Sounds whose files this project has not got are dropped rather than refusing the
    /// whole paste, which is the one place this differs from pasting a lone sound region. A
    /// lone sound region *is* the paste, so failing it explains itself; a music cue attached
    /// to ten seconds of picture is not what the user asked for, and throwing away their
    /// footage over it would be the clipboard deciding what they meant.
    func pasteFootageAtPlayhead() {
        guard let copied = RegionPasteboard.shared.readFootage() else { return }
        let package = packageURL
        let isMissing = { (path: String) in
            !FileManager.default.fileExists(atPath: package.appendingPathComponent(path).path)
        }
        // A clip of a movie brought into another project has no file here, and cannot be
        // left out the way a sound can without changing the length of everything after it.
        guard !copied.playsMissingMedia(where: isMissing) else {
            errorMessage = "That footage plays a movie from another recording. Add the movie here with Add Video… first."
            return
        }
        let settled = copied.withoutSounds(where: isMissing).withoutPictures(where: isMissing)
        let droppedPictures = copied.annotations.count - settled.annotations.count
        let dropped = copied.audio.count - settled.audio.count
        let placed = settled.freshened()
        guard applyFootage(placed, at: playhead, name: "Paste \(placed.title)") else { return }
        if droppedPictures > 0, dropped == 0 {
            errorMessage = droppedPictures == 1
                ? "One picture belonged to another recording and was left out. Add it with Picture…"
                : "\(droppedPictures) pictures belonged to another recording and were left out. Add them with Picture…"
        }
        if dropped > 0 {
            errorMessage = dropped == 1
                ? "One sound belonged to another recording and was left out. Add it with Add Sound…"
                : "\(dropped) sounds belonged to another recording and were left out. Add them with Add Sound…"
        }
    }

    /// A copy of the selected footage, immediately after it.
    ///
    /// After rather than on top of, which for footage is not a choice about visibility the
    /// way it is for a region — there is nowhere else to put it. Inserting at the selection's
    /// end is what makes ⌘D on a clip mean "play this twice".
    func duplicateFootage(_ selection: Selection) {
        guard let footage = CopiedFootage(selection, in: timeline),
              let range = selection.range(in: timeline) else { return }
        let placed = footage.freshened()
        _ = applyFootage(placed, at: range.end, name: "Duplicate \(placed.title)")
    }

    /// The one door both of them go through, so the selection lands the same way either way.
    ///
    /// Selects the first clip that arrived rather than the range it occupies: the clips are
    /// the things that exist afterwards and can be dragged, trimmed and deleted, and a
    /// `.range` selection would have to be recomputed from the insertion point — arithmetic
    /// the command has already done and would only get to disagree with.
    @discardableResult
    private func applyFootage(_ footage: CopiedFootage, at time: CMTime, name: String) -> Bool {
        let before = timeline
        apply(Commands.InsertFootage(footage, at: time, name: name))
        guard timeline != before else { return false }
        if let first = footage.clips.first { select(.clip(first.id)) }
        return true
    }

    // MARK: - Editing

    func apply(_ command: some TimelineCommand) {
        guard document.apply(command) else { return }
        refresh()
        // Rebuilding the player's composition means opening the recording's audio and
        // laying every cut down again. Mid-gesture the answer cannot change until the user
        // lets go, and computing the signature to discover that allocates an array per
        // lane, per frame. Once, at the end — see `finishInteraction`.
        if !document.isInteracting { audio?.prepare(for: timeline) }
    }

    /// Ends a gesture and does the work that was deferred while it ran.
    ///
    /// Every drag goes through here rather than calling `document.endInteraction()`
    /// directly, so there is one place that knows what a gesture put off.
    func finishInteraction() {
        guard document.isInteracting else { return }
        document.endInteraction()
        refresh()
        audio?.prepare(for: timeline)
    }

    func change(_ name: String, _ mutate: (inout Timeline) -> Void) {
        document.change(name, mutate)
        refresh()
        audio?.prepare(for: timeline)
    }

    // MARK: - One piece at a time

    /// Whether the playhead is inside this clip, with room to cut on both sides.
    ///
    /// The question the Split button on a selected clip has to answer: a cut at a clip's
    /// own edge is not a cut, and offering it is offering a button that does nothing.
    func canSplit(_ clip: Clip) -> Bool {
        // A title is one card with one entrance, and does not split.
        guard !clip.isTitle,
              let index = timeline.clips.firstIndex(where: { $0.id == clip.id }) else { return false }
        let start = timeline.start(ofClipAt: index)
        return playhead > start + Clip.minimumDuration
            && playhead < start + clip.duration - Clip.minimumDuration
    }

    /// Trims one end of one clip, in source time.
    ///
    /// The timeline already had this on a drag of a clip's edge; what it did not have was
    /// a way to say "a third of a second off the front", which is the request somebody has
    /// after watching the cut rather than while dragging it. `TrimClip` is the same command
    /// the drag uses, so the two cannot mean different things.
    func trim(_ clip: Clip, head: CMTime? = nil, tail: CMTime? = nil) {
        apply(Commands.TrimClip(clipID: clip.id, head: head, tail: tail))
    }

    /// Nudges a clip's in or out point by a small amount of source, keeping the clip long
    /// enough to still be a clip.
    func nudgeTrim(_ clip: Clip, edge: ClipEdge, by seconds: Double) {
        let delta = CMTime(seconds: seconds, preferredTimescale: 600)
        switch edge {
        case .head:
            let proposed = max(.zero, min(clip.sourceStart + delta,
                                          clip.sourceEnd - Clip.minimumDuration))
            guard proposed != clip.sourceStart else { return }
            trim(clip, head: proposed)
        case .tail:
            // Within the clip's own file: the recording, or the movie it plays.
            let proposed = min(timeline.sourceDuration(of: clip),
                               max(clip.sourceEnd + delta,
                                   clip.sourceStart + Clip.minimumDuration))
            guard proposed != clip.sourceEnd else { return }
            trim(clip, tail: proposed)
        }
    }

    enum ClipEdge { case head, tail }

    /// Puts a clip back to the speed it was recorded at, as one step.
    func resetSpeed(of clip: Clip) {
        guard clip.speed != 1 else { return }
        setSpeed(1, of: clip.id)
    }

    func splitAtPlayhead() {
        apply(Commands.Split(at: playhead))
    }

    /// A zoom at the playhead, four seconds long, centred where the pointer is.
    func addZoomAtPlayhead() {
        let length = CMTime(seconds: min(4, max(1.5, duration.seconds - playhead.seconds)), preferredTimescale: 600)
        let region = ZoomRegion(start: playhead, duration: length)
        apply(Commands.AddZoom(region))
        select(.zoom(region.id))
    }

    // MARK: - Framing a zoom on the picture

    /// What the one preview is showing while a zoom is selected.
    ///
    /// There used to be two pictures: the main preview, and a panel in the corner drawing
    /// the same frame again through the zoom being edited. Two previews of one video is one
    /// too many — the eye has to travel between them to answer a single question — and the
    /// small one was the one that actually showed the effect, which is the wrong way round.
    ///
    /// One surface, two readings of it, and the user says which.
    enum ZoomPreview: String, CaseIterable, Identifiable, Hashable {
        /// The whole recording, with the framing rectangle drawn over it. What you edit in.
        case framing
        /// The zoom as it will play and as it will export. What you judge in.
        case result

        var id: String { rawValue }
        var title: String { self == .framing ? "Framing" : "Result" }
        var symbol: String { self == .framing ? "dot.viewfinder" : "play.rectangle" }
    }

    /// Which reading is on screen. Not persisted: it is a way of looking, not a property of
    /// the project.
    var zoomPreview: ZoomPreview = .framing {
        didSet { if zoomPreview != oldValue { refresh() } }
    }

    /// Whether the zoom inspector's Advanced section is open.
    ///
    /// On the model rather than in the view, so opening it for one zoom and clicking the
    /// next chip does not fold it shut again — a panel that forgets is a panel you stop
    /// opening.
    var isZoomAdvancedOpen = false

    /// The same, for the annotation inspector's Advanced section.
    var isAnnotationAdvancedOpen = false

    /// The zoom the picture is being framed for, or `nil` when the picture is just the
    /// picture.
    ///
    /// Selection alone decides this. There is no mode to enter: clicking a chip on the zoom
    /// lane is already an unambiguous statement about which zoom you mean, and making that
    /// statement twice — once on the timeline, once on a tool rail — was the step that made
    /// framing feel like a place you had to go rather than something you could just do.
    var framedZoom: ZoomRegion? {
        guard zoomPreview == .framing, !isPlaying, !tool.flattensPreview else { return nil }
        guard case .zoom(let id) = selection else { return nil }
        return timeline.zooms.first { $0.id == id }
    }

    var isFramingZoom: Bool { framedZoom != nil }

    /// Whether the framing box may be switched at all — a zoom is selected, and playback is
    /// not the thing deciding what the picture shows.
    var canChooseZoomPreview: Bool {
        guard case .zoom = selection else { return false }
        return !isPlaying && !tool.flattensPreview
    }

    /// Set while a framing handle is being dragged.
    ///
    /// The framing preview renders the timeline with the zooms taken out, so the picture
    /// under the box cannot change while the box moves: every frame of the drag would
    /// decode the same source frame and composite the same output. The description is still
    /// rebuilt — the overlay reads `scene` for its coordinate mapping — and the decode is
    /// skipped. See `refresh()`.
    @ObservationIgnored var isFramingDrag = false

    /// Frames a zoom: select it, put the playhead somewhere it can be judged, and show the
    /// box.
    ///
    /// Parking the playhead is not a nicety. A zoom only magnifies while the playhead is
    /// inside it, so switching to Result from outside one shows a completely unchanged
    /// picture — the zoom working perfectly with no moment at which you could see it.
    /// Moved to just past the ramp-in, where the camera has arrived; the region's first
    /// frame is the one instant inside it where the scale is still 1.
    func frameSelectedZoom() {
        guard let zoom = activeZoom else { return }
        select(.zoom(zoom.id))
        parkPlayhead(inside: zoom)
        if tool.flattensPreview { tool = .frame }
        zoomPreview = .framing
    }

    /// Shows the selected zoom as it will play, from a moment where it is fully in.
    func previewZoomResult() {
        guard let zoom = activeZoom else { return }
        select(.zoom(zoom.id))
        parkPlayhead(inside: zoom)
        if tool.flattensPreview { tool = .frame }
        zoomPreview = .result
    }

    private func parkPlayhead(inside zoom: ZoomRegion) {
        guard !zoom.contains(playhead) else { return }
        let settled = zoom.start + min(zoom.ramps.in, CMTimeMultiplyByFloat64(zoom.duration, multiplier: 0.5))
        scrub(to: min(settled, zoom.end - CMTime(value: 1, timescale: 600)))
    }

    // MARK: - Zooms, on the second pass

    /// The zoom the verbs act on: the selected one, or — with nothing selected — the one
    /// under the playhead.
    ///
    /// Falling back to the playhead is not a convenience, it is what makes the menu items
    /// usable: somebody scrubbing to the moment a push-in should become two has their hands
    /// on the playhead, not on the lane, and making them click the chip first to say
    /// something the playhead already says would be a step for the computer's benefit.
    /// The last match wins where two overlap, which is the topmost chip on the lane.
    var activeZoom: ZoomRegion? {
        if case .zoom(let id) = selection, let zoom = timeline.zooms.first(where: { $0.id == id }) {
            return zoom
        }
        return timeline.zooms.last { $0.contains(playhead) }
    }

    /// The zoom this one would be merged with: the next one along the lane.
    ///
    /// The next rather than the nearest, because the lane is sorted by start and "merge with
    /// the one after this" is a sentence the user can predict the outcome of. `nil` for the
    /// last zoom on the lane, which is what disables the menu item.
    var zoomToMergeInto: ZoomRegion? {
        guard let zoom = activeZoom,
              let index = timeline.zooms.firstIndex(where: { $0.id == zoom.id }),
              index + 1 < timeline.zooms.count else { return nil }
        return timeline.zooms[index + 1]
    }

    /// Whether the playhead is somewhere the active zoom can actually be cut.
    ///
    /// Asked before the command so the menu item can be grey rather than inert: a split
    /// within a few frames of either end would leave a chip too small to see or grab, and
    /// `ZoomLane.split` refuses it.
    var canSplitZoom: Bool {
        guard let zoom = activeZoom else { return false }
        return ZoomLane.split(zoom, at: playhead) != nil
    }

    /// One long push-in becomes two, cut at the playhead.
    ///
    /// The second half is left selected: the playhead is sitting at its start, so it is the
    /// part the user is looking at and the one they cut in order to aim somewhere else.
    func splitZoomAtPlayhead() {
        guard let zoom = activeZoom else { return }
        let before = Set(timeline.zooms.map(\.id))
        apply(Commands.SplitZoom(id: zoom.id, at: playhead))
        if let fresh = timeline.zooms.first(where: { !before.contains($0.id) }) {
            select(.zoom(fresh.id))
        }
    }

    func mergeZoomWithNext() {
        guard let zoom = activeZoom, let next = zoomToMergeInto else { return }
        apply(Commands.MergeZooms(zoom.id, next.id))
        // The earlier id survives a merge, so the selection lands on a region that is still
        // there — which is the reason `MergeZooms` keeps it rather than minting a new one.
        select(.zoom(zoom.id))
    }

    /// Switches a zoom off, or back on — see `ZoomRegion.isEnabled` for why this is not
    /// the same as deleting it or locking it.
    ///
    /// Acts on every selected zoom when several are, so auditioning a run of suggestions is
    /// one gesture rather than one per chip. The decision is taken from the zoom the
    /// inspector is about, so a mixed selection all ends up the same way rather than each
    /// flipping to its own opposite — which is what makes it a switch rather than a toggle
    /// you have to press twice to line up.
    func setZoomsEnabled(_ enabled: Bool? = nil) {
        let ids = selected.compactMap { selection -> UUID? in
            guard case .zoom(let id) = selection else { return nil }
            return id
        }
        let targets = ids.isEmpty ? [activeZoom?.id].compactMap { $0 } : ids
        guard !targets.isEmpty else { return }
        let wanted = enabled ?? !(timeline.zooms.first { $0.id == targets[0] }?.isEnabled ?? true)

        document.beginInteraction(wanted ? "Turn Zoom On" : "Turn Zoom Off")
        for id in targets {
            apply(Commands.RestyleZoom(id: id, name: wanted ? "Turn Zoom On" : "Turn Zoom Off") {
                $0.isEnabled = wanted
            })
        }
        finishInteraction()
    }

    /// Whether the zoom the inspector is about is switched on. `true` when there is none,
    /// so a control bound to this does not flicker as the selection changes.
    var isActiveZoomEnabled: Bool { activeZoom?.isEnabled ?? true }

    func toggleZoomLock() {
        guard let zoom = activeZoom else { return }
        let locking = !zoom.isLocked
        apply(Commands.RestyleZoom(id: zoom.id, name: locking ? "Lock Zoom" : "Unlock Zoom") {
            $0.isLocked = locking
        })
    }

    /// Scale, ramp and easing back to what a new zoom has; where it is and what it points at
    /// left alone. `ZoomLane.reset` says why.
    func resetZoom() {
        guard let zoom = activeZoom else { return }
        apply(Commands.RestyleZoom(id: zoom.id, name: "Reset Zoom") { $0 = ZoomLane.reset($0) })
    }

    /// Framing back to the middle of the picture at the default magnification, following
    /// the pointer again.
    ///
    /// The way out of a framing somebody has dragged into a corner and cannot get back.
    /// It puts `followsCursor` back on, because that is what a new zoom does and because a
    /// zoom aimed at the middle of the screen and held there is almost never what anyone
    /// wants — aiming it by hand was the thing that turned following off, so undoing the
    /// aim has to undo that too.
    ///
    /// `isEdited` goes back with it: a zoom whose framing is the default again has no
    /// hand-made framing left for a suggestion run to protect.
    func resetZoomFraming() {
        guard let zoom = activeZoom else { return }
        apply(Commands.RestyleZoom(id: zoom.id, name: "Reset Framing") {
            $0.scale = ZoomRegion.defaultScale
            $0.center = CGPoint(x: 0.5, y: 0.5)
            $0.followsCursor = true
            $0.isEdited = false
        })
    }

    /// Point a zoom at somewhere on the picture.
    ///
    /// `center` is normalised to the *recording*, like a blur's rect — the overlay converts
    /// for us, because it is the only place that knows where the picture landed on screen.
    /// Clamped here rather than there, so a point that came from a drag off the edge of the
    /// window cannot be stored.
    ///
    /// Following the pointer is turned off in the same step, and that is the one thing here
    /// that changes a setting the user did not touch. It is the honest reading of the
    /// gesture: a zoom that follows the cursor works out its own centre every frame, so
    /// placing a crosshair on a following zoom would be an edit with no effect on any frame.
    /// One undo puts both back.
    func aimZoom(_ id: UUID, at point: CGPoint) {
        let clamped = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        apply(Commands.RestyleZoom(id: id, name: "Aim Zoom") {
            $0.center = clamped
            $0.followsCursor = false
            // Pointed by hand, so the next auto-zoom run leaves it alone. See
            // `ZoomRegion.isEdited`.
            $0.isEdited = true
        })
    }

    /// Sets what a zoom frames — where it looks *and* how much it takes in — from a
    /// rectangle drawn on the picture.
    ///
    /// Aiming alone was half the job. A zoom is a rectangle of the recording promoted to
    /// fill the frame, so the thing the user actually has in mind is "this part of the
    /// screen", which is an area, not a point: they know which window they want in shot
    /// and how much of it, and asking them to express the second half as a scale on a
    /// slider is asking them to do the arithmetic the rectangle already did.
    ///
    /// The scale comes from the width alone. A zoom scales both axes by one number, so a
    /// rectangle whose proportions differ from the picture's cannot be honoured as drawn;
    /// taking the width and letting the height follow is the version where the thing the
    /// user framed is never cropped tighter than they drew it.
    ///
    /// A zoom out is framed as the whole recording, and a box the whole recording wide
    /// says nothing about how far out it is — so it leaves a zoom out's scale alone rather
    /// than quietly turning it into 1×. Drawing the box smaller is a push in, and says so.
    func setZoomArea(_ id: UUID, to rect: CGRect, name: String = "Frame Zoom") {
        guard rect.width > 0 else { return }
        let area = ZoomFraming.honoured(rect)
        let scale = ZoomFraming.scale(forSide: area.width)
        apply(Commands.RestyleZoom(id: id, name: name) {
            guard !($0.zoomsOut && scale <= 1) else { return }
            $0.scale = scale
            $0.center = CGPoint(x: area.midX, y: area.midY)
            $0.followsCursor = false
            $0.isEdited = true
        })
    }

    /// The rectangle a drawn one will actually become.
    ///
    /// `ZoomFraming` owns the arithmetic, so the box on the picture, the command that
    /// stores it and the tests are all reading one implementation. Kept here as the name
    /// the overlay already calls, because the overlay's job is to draw what will be stored
    /// and this is how it asks.
    static func honouredZoomArea(_ rect: CGRect) -> CGRect { ZoomFraming.honoured(rect) }

    /// What a zoom currently frames, as a rectangle of the recording — the inverse of
    /// `setZoomArea`, and what the overlay draws.
    func zoomArea(of zoom: ZoomRegion) -> CGRect { ZoomFraming.area(of: zoom) }

    /// Nudges when a zoom begins, or how long it runs, by a fraction of a second.
    ///
    /// Through `MoveRegion` — the command a drag on the lane uses — so typing and dragging
    /// cannot end up meaning different things, and so the lane's clamping applies here too.
    func nudgeZoom(_ id: UUID, start: Double? = nil, duration: Double? = nil) {
        guard let zoom = timeline.zooms.first(where: { $0.id == id }) else { return }
        if let start {
            let moved = max(.zero, zoom.start + CMTime(seconds: start, preferredTimescale: 600))
            apply(Commands.MoveRegion(id: id, start: moved))
        } else if let duration {
            let length = max(Clip.minimumDuration,
                             zoom.duration + CMTime(seconds: duration, preferredTimescale: 600))
            apply(Commands.MoveRegion(id: id, start: zoom.start, duration: length))
        }
    }

    /// Puts a zoom's start, or its end, on the playhead — keeping the other end where it is.
    ///
    /// The two requests people actually have about a zoom's timing, and both are awkward to
    /// express by dragging: "it should start *here*" means dragging the chip until its left
    /// edge is under a line you cannot see behind it.
    func moveZoom(_ id: UUID, toStartAt time: CMTime? = nil, toEndAt end: CMTime? = nil) {
        guard let zoom = timeline.zooms.first(where: { $0.id == id }) else { return }
        if let time {
            apply(Commands.MoveRegion(id: id, start: max(.zero, time), duration: zoom.duration))
        } else if let end {
            let start = max(.zero, min(zoom.start, end - Clip.minimumDuration))
            apply(Commands.MoveRegion(id: id, start: start, duration: max(Clip.minimumDuration, end - start)))
        }
    }

    func setSpeed(_ speed: Double, of clipID: UUID) {
        guard let index = timeline.clips.firstIndex(where: { $0.id == clipID }) else { return }
        apply(Commands.SetSpeed(CMTimeRange(start: timeline.start(ofClipAt: index),
                                            duration: timeline.clips[index].duration),
                                speed: speed))
    }

    func setCrop(_ crop: CropRect?) {
        apply(Commands.SetCrop(crop))
    }

    // MARK: - Captions

    /// Whether a transcript is being made right now, so the inspector can say so.
    private(set) var isGeneratingCaptions = false
    /// How far along it is, when the recogniser can honestly say — `nil` when it cannot,
    /// which is the whole of the older recogniser's run and the whole of a model download.
    /// The inspector spins on `nil` and fills on a number; neither of them invents one.
    private(set) var captionProgress: Double?

    /// Listens to the recording and writes down what was said.
    ///
    /// Replaces whatever captions were there, as one undoable step: a transcript is a
    /// single thing the user asked for, and taking it back should not be two hundred
    /// presses of ⌘Z.
    /// The file to listen to.
    ///
    /// A microphone on its own file transcribes far better than a recording's whole
    /// soundtrack does, because it is a voice rather than a voice over the top of whatever
    /// the browser was playing. On a recording made before the sources were separated there
    /// is only the video file, which is where the sound is — and if the lane a project
    /// names has gone missing from the package, that is where this falls back to as well,
    /// rather than failing with "no audio".
    private var speechURL: URL? {
        if let track = timeline.soundTrackForSpeech {
            let url = packageURL.appendingPathComponent(track.path)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        return document.videoURL
    }

    func generateCaptions() {
        guard !isGeneratingCaptions, let videoURL = speechURL else { return }
        isGeneratingCaptions = true
        captionProgress = nil

        Task {
            defer {
                isGeneratingCaptions = false
                captionProgress = nil
            }
            do {
                // Held for as long as the work runs, which the task around this already
                // does: a report of progress cannot outlive the thing it is reporting on.
                let cues = try await CaptionGenerator.cues(for: videoURL, timeline: timeline,
                                                           locale: settings?.captionLocale ?? .current) { [self] done in
                    Task { @MainActor in
                        guard self.isGeneratingCaptions else { return }
                        self.captionProgress = done
                    }
                }
                apply(Commands.SetCaptions(cues))
            } catch let failure as CaptionGenerator.Failure {
                errorMessage = failure.message
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setCaptionText(_ id: UUID, _ text: String) {
        apply(Commands.SetCaptionText(id: id, text: text))
    }

    func clearCaptions() {
        apply(Commands.SetCaptions([]))
        selected.removeAll { if case .caption = $0 { true } else { false } }
    }

    /// Captions on or off, without losing them.
    func toggleCaptions() {
        let shows = !timeline.captionStyle.isVisible
        apply(Commands.Restyle(shows ? "Show Captions" : "Hide Captions") { $0.captionStyle.isVisible = shows })
    }

    /// Adds an empty caption at the playhead, for typing into.
    ///
    /// With the playhead inside a caption the new one goes after it, the way a new line in
    /// a document goes under the line the caret is on. Putting it at the playhead itself
    /// cut the caption already there short, to a sliver if the playhead was near its
    /// start, which is not what anybody adding a line meant to do to the one before.
    ///
    /// - Returns: its id, so the caller can put the caret in it.
    @discardableResult
    func addCaptionAtPlayhead() -> UUID? {
        guard let slot = CaptionPlacement.slot(at: playhead, among: timeline.captions, in: duration) else {
            errorMessage = "There is no room here for another caption. Shorten the one before or after it first."
            return nil
        }
        let cue = CaptionCue(start: slot.start, duration: slot.duration, text: "")
        let before = timeline.captions
        apply(Commands.AddCaption(cue))
        guard timeline.captions != before else {
            errorMessage = "There is no room here for another caption. Shorten the one before or after it first."
            return nil
        }
        // Captions that nobody can see would be a caption added to nothing.
        if !timeline.captionStyle.isVisible {
            apply(Commands.Restyle("Captions") { $0.captionStyle.isVisible = true })
        }
        select(.caption(cue.id))
        // Where the line is, so what is typed is typed over the moment it belongs to.
        if slot.start != playhead { scrub(to: slot.start) }
        return cue.id
    }

    /// Cuts the caption under the playhead in two there.
    func splitCaptionAtPlayhead(_ id: UUID) {
        let before = timeline.captions
        apply(Commands.SplitCaption(id: id, at: playhead))
        if timeline.captions == before {
            errorMessage = "Put the playhead inside the caption, between two of its words, to split it there."
        }
    }

    func canSplitCaption(_ cue: CaptionCue) -> Bool {
        cue.timedWords.count > 1
            && playhead - cue.start >= Clip.minimumDuration
            && cue.end - playhead >= Clip.minimumDuration
    }

    /// Joins a caption to the one after it.
    func mergeCaptionWithNext(_ id: UUID) {
        apply(Commands.MergeCaptions(id: id))
    }

    /// The caption after this one, which is what merging would join it to.
    func captionAfter(_ id: UUID) -> CaptionCue? {
        let ordered = timeline.captions.sorted { $0.start < $1.start }
        guard let index = ordered.firstIndex(where: { $0.id == id }), index + 1 < ordered.count else { return nil }
        return ordered[index + 1]
    }

    /// Writes the captions out as a subtitle file, wherever the user says.
    func exportCaptions(as format: CaptionExport.Format) {
        guard !timeline.captions.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Captions"
        panel.nameFieldStringValue = "\(name).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CaptionExport.text(for: timeline.captions, as: format)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "The captions couldn't be written. \(error.localizedDescription)"
        }
    }

    /// The caption on screen at the playhead, which is the one the inspector should
    /// have focused for editing.
    var captionAtPlayhead: CaptionCue? {
        timeline.captions.last { $0.contains(playhead) }
    }

    // MARK: - Things drawn on the picture

    /// How long a blur or an annotation lasts when it is first drawn.
    ///
    /// Long enough to be seen in the finished video, short enough that it is a thing on
    /// the timeline rather than a change to the whole recording — and trimmable from
    /// either end afterwards, like every other region.
    static let drawnRegionDuration = CMTime(seconds: 3, preferredTimescale: 600)

    /// The span a newly drawn region covers: from the playhead, clamped to the end.
    private var drawnRange: (start: CMTime, duration: CMTime) {
        let start = min(playhead, max(.zero, duration - Clip.minimumDuration))
        return (start, min(Self.drawnRegionDuration, max(Clip.minimumDuration, duration - start)))
    }

    // MARK: - Sound

    /// Brings a sound into the project and lays it at the playhead.
    ///
    /// Trimmed to what is left of the edit, so a four-minute track dropped near the end
    /// does not silently make the video four minutes longer — it plays to the end and
    /// stops, and the region can be dragged or resized from there like any other.
    func addSound() {
        guard let url = SoundImport.choose() else { return }
        Task {
            do {
                let sound = try await SoundImport.copy(url, into: packageURL)
                let room = duration - playhead
                guard room > Clip.minimumDuration else {
                    errorMessage = "There is no room at the playhead for a sound."
                    return
                }
                let region = AudioRegion(start: playhead,
                                         duration: min(sound.duration, room),
                                         path: sound.path)
                apply(Commands.AddAudio(region))
                select(.audio(region.id))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Voiceover

    /// The take being recorded, or `nil` when none is. Read by the inspector so the panel
    /// can count in and offer Stop.
    private(set) var voiceover: VoiceoverRecorder?

    /// The timeline time the current take punched in at.
    ///
    /// Read once, at the instant the file opened, and never recomputed: by the time the
    /// take stops the playhead has moved on by however long it lasted, so asking then
    /// would place every voiceover at its own end.
    private var voiceoverPunchIn: CMTime?

    var isRecordingVoiceover: Bool { voiceover?.state.isBusy == true }

    func toggleVoiceover() {
        isRecordingVoiceover ? stopVoiceover() : startVoiceover()
    }

    /// Records narration against the edit, starting at the playhead.
    ///
    /// The permission comes first and on its own: a dialog that appears *during* a
    /// count-in would eat the count-in, and a refusal has to be something the editor says
    /// out loud rather than a take that turns out to be silence.
    func startVoiceover() {
        guard voiceover == nil else { return }
        guard duration - playhead >= Clip.minimumDuration else {
            errorMessage = "There is no room at the playhead for a voiceover. Move it back and try again."
            return
        }

        Task {
            do {
                try await VoiceoverRecorder.requestAccess()
            } catch let denial as RecordingError {
                // Said in full, because the two halves are different facts: what is
                // missing, and where to go and grant it.
                errorMessage = [denial.errorDescription, denial.recoverySuggestion]
                    .compactMap { $0 }
                    .joined(separator: " ")
                return
            } catch {
                report(error)
                return
            }
            guard voiceover == nil, isRecordingVoiceover == false else { return }
            arm()
        }
    }

    private func arm() {
        // A take starts from a stationary playhead: the count-in is time to draw breath,
        // and the picture running through it would leave the first words over the wrong
        // few seconds.
        if isPlaying { stop() }

        let recorder = VoiceoverRecorder(
            deviceID: settings?.microphoneID,
            countIn: settings?.voiceoverCountInSeconds ?? 3,
            onPunchIn: { [weak self] in self?.voiceoverDidPunchIn() },
            onFinish: { [weak self] result in self?.voiceoverDidFinish(result) }
        )
        voiceover = recorder
        // Before anything is written, not when the file opens: the speakers have to be
        // quiet for the whole of the take, including the moment it begins.
        audio?.silenceForCapture()

        do {
            try recorder.arm()
        } catch {
            voiceover = nil
            audio?.stopSilencingForCapture()
            report(error)
        }
    }

    /// The file is open. This is the take's zero, and the moment the edit starts playing.
    private func voiceoverDidPunchIn() {
        voiceoverPunchIn = playhead
        if !isPlaying { play() }
    }

    func stopVoiceover() {
        voiceover?.stop()
    }

    private func voiceoverDidFinish(_ result: Result<URL, Error>) {
        let punchIn = voiceoverPunchIn ?? playhead
        voiceoverPunchIn = nil
        voiceover = nil
        audio?.stopSilencingForCapture()
        if isPlaying { stop() }

        switch result {
        case .success(let url):
            Task { await adoptVoiceover(url, punchedInAt: punchIn) }
        case .failure(let error):
            // A cancelled take is something the user did, not something that went wrong.
            guard (error as? RecordingError) != .cancelled else { return }
            report(error)
        }
    }

    /// Brings a finished take into the project.
    ///
    /// The same road an imported sound takes — copied into the package's `Audio` folder,
    /// laid down as an `AudioRegion` through one command — because a voiceover is an
    /// imported sound that happened to be recorded here, and two ways of getting sound
    /// into a package would be two things to keep working.
    ///
    /// A re-take adds another region beside the last one rather than over it: the file has
    /// its own name and the region its own identity, so the previous take stays on the lane
    /// to be listened to, muted or deleted. Nothing is thrown away on the user's behalf.
    private func adoptVoiceover(_ url: URL, punchedInAt punchIn: CMTime) async {
        // The take was written somewhere temporary; once it has been copied in — or
        // failed to be — the original has no reason to exist.
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let sound = try await SoundImport.copy(url, into: packageURL)
            guard let placement = timeline.voiceoverPlacement(punchedInAt: punchIn,
                                                              recorded: sound.duration) else {
                // Nothing will refer to the copy, so it does not stay in the package.
                try? FileManager.default.removeItem(at: packageURL.appendingPathComponent(sound.path))
                errorMessage = "That take was too short to put on the timeline."
                return
            }
            let region = AudioRegion(start: placement.start,
                                     duration: placement.duration,
                                     path: sound.path)
            apply(Commands.AddAudio(region, name: "Record Voiceover"))
            select(.audio(region.id))
            if placement.wasTrimmed {
                errorMessage = "The voiceover ran past the end of the video, so the region stops there. The whole take is in the file — drag the region's edge if you want more of it."
            }
        } catch {
            report(error)
        }
    }

    /// Mutes or unmutes the recording's own sound.
    func toggleRecordedSound() {
        let muted = timeline.sound.isMuted
        apply(Commands.Restyle(muted ? "Unmute" : "Mute") { $0.sound.isMuted = !muted })
    }

    // MARK: - The recording's sources

    /// The lanes, in the order they are drawn. Empty for a recording made before the
    /// sources were captured separately, which is what keeps its single lane single.
    var soundTracks: [SoundTrack] { timeline.soundTracks }

    func toggleSoundMute(_ id: UUID) {
        guard let track = timeline.soundTrack(id) else { return }
        let muted = track.style.isMuted
        apply(Commands.RestyleSoundTrack(id: id, name: muted ? "Unmute \(track.name)" : "Mute \(track.name)") {
            $0.style.isMuted = !muted
        })
    }

    func setSoundGain(_ id: UUID, to gain: Double) {
        apply(Commands.RestyleSoundTrack(id: id, name: "Level") { $0.style.gain = gain })
    }

    func renameSound(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty name would leave a lane with nothing on it and no way to tell it from
        // its neighbour, so the source's own word for itself is the floor.
        guard let track = timeline.soundTrack(id) else { return }
        let resolved = trimmed.isEmpty ? track.source.defaultName : trimmed
        guard resolved != track.name else { return }
        apply(Commands.RestyleSoundTrack(id: id, name: "Rename Source") { $0.name = resolved })
    }

    func soloSound(_ id: UUID) {
        apply(Commands.SoloSoundTrack(id: id))
        select(.soundTrack(id))
    }

    func unmuteAllSound() {
        apply(Commands.UnmuteAllSoundTracks())
    }

    // MARK: - Detaching the recording's own sound

    var isSoundDetached: Bool { timeline.isSoundDetached }

    /// What re-attaching is about to throw away, or `nil` when nothing is pending.
    ///
    /// Lives here rather than in the lane's view because two places ask for a re-attach —
    /// the lane's context menu and the Edit menu — and a dialogue owned by one of them
    /// would not appear for the other. The view watches this and presents it; the model
    /// never presents anything itself.
    private(set) var soundReattachWarning: String?

    /// Cuts the recording's sound loose from the picture, and selects its first run so
    /// the inspector explains what just happened instead of leaving the lane looking
    /// merely redrawn.
    func detachSound() {
        guard !isSoundDetached else { return }
        apply(Commands.DetachSound())
        if let first = timeline.detachedSound?.first { select(.soundRun(first.id)) }
    }

    /// Asks to put the sound back in step, warning first when that costs an edit.
    ///
    /// Silent when the lane has not been touched, because then re-attaching is a no-op you
    /// can hear nothing of and a dialogue would be a question with one sensible answer.
    func requestSoundReattach() {
        guard isSoundDetached else { return }
        guard !timeline.detachedSoundIsInStepWithClips else {
            attachSound()
            return
        }
        soundReattachWarning = Self.reattachWarning(for: timeline)
    }

    func cancelSoundReattach() { soundReattachWarning = nil }

    func attachSound() {
        soundReattachWarning = nil
        guard isSoundDetached else { return }
        apply(Commands.AttachSound())
    }

    /// Says what will go, in the units the user worked in.
    ///
    /// Counting runs rather than saying "your edits will be lost": the lane is a row of
    /// runs and the user can see how many they moved, so a number they can check against
    /// the screen is the difference between a warning and a scare.
    private static func reattachWarning(for timeline: Timeline) -> String {
        let runs = timeline.detachedSound ?? []
        let expected = timeline.soundRunsFollowingClips
        let moved = runs.count == expected.count
            ? zip(runs, expected).count { $0.start != $1.start || $0.duration != $1.duration
                                          || $0.sourceStart != $1.sourceStart || $0.speed != $1.speed }
            : max(runs.count, expected.count)
        let what = moved == 1 ? "one run of sound" : "\(moved) runs of sound"
        return """
            Re-attaching cuts the recording's sound where the picture is cut again, \
            which undoes \(what) you moved or trimmed. The picture is not touched.
            """
    }

    /// What the next mask drawn on the picture is: a blur unless the Mask panel or the
    /// Mask menu said otherwise. Editor state, not a preference — it is about this
    /// sitting, and remembering it across launches would surprise more than it helped.
    var newMaskStyle: BlurRegion.Style = .gaussian

    /// A mask being made to follow its content, while one is. See `EditorModel+Following`.
    let following = MaskFollowingJob()

    /// The scan for sensitive text and its review sheet. See `EditorModel+Sensitive`.
    let sensitive = SensitiveScanJob()

    /// Hides something: a password, a name, a face. Or, as a spotlight, shows it.
    @discardableResult
    func addBlur(rect: CGRect) -> UUID {
        let range = drawnRange
        let region = BlurRegion(start: range.start, duration: range.duration, rect: rect, style: newMaskStyle)
        apply(Commands.AddBlur(region))
        select(.blur(region.id))
        return region.id
    }

    /// The things the Annotate tool can put on the picture, as something a button can
    /// offer.
    ///
    /// `AnnotationItem.Kind` carries a payload — the words, the arrow's two ends — so it
    /// cannot be offered directly by a menu. This is the choice before the payload exists.
    /// What each one is called, looks like and lands as is in `EditorModel+AnnotationKinds`.
    enum NewAnnotation: String, CaseIterable, Identifiable {
        case text, arrow, box, ellipse, line, highlight, step, callout

        var id: String { rawValue }
    }

    /// Adds one in the middle of the frame, ready to be dragged where it belongs.
    ///
    /// The other way in is drawing one on the picture, which works well and which you have
    /// to be told about. A button says the feature is there.
    @discardableResult
    func addAnnotation(_ new: NewAnnotation) -> UUID {
        // The tool comes with it: the handles that move and resize what was just added live
        // on the Annotate canvas, and adding something you then cannot touch would be worse
        // than not offering the button.
        tool = .annotate
        let aspect = outputSize.height > 0 ? outputSize.width / outputSize.height : 16.0 / 9
        return addAnnotation(new.kind(nextStep: timeline.nextStepNumber),
                             rect: offsetForClearSpace(new.rect(aspect: aspect)),
                             named: "Add \(new.title)",
                             configure: new.configure)
    }

    /// Nudges a new rectangle clear of anything already at the playhead.
    ///
    /// Two labels added in a row land exactly on top of each other otherwise, and the
    /// second one looks like nothing happened. Cascading down and right is what every
    /// document-based app does with a duplicate, and for the same reason.
    private func offsetForClearSpace(_ rect: CGRect) -> CGRect {
        let step = 0.035
        var rect = rect
        var tries = 0
        while tries < 8,
              annotationsAtPlayhead.contains(where: { abs($0.rect.minX - rect.minX) < 0.001
                                                   && abs($0.rect.minY - rect.minY) < 0.001 }) {
            rect.origin.x += step
            rect.origin.y += step
            tries += 1
        }
        return rect
    }

    /// Puts something on top: a label, an arrow, a box, a picture.
    ///
    /// - Parameter during: when it shows; at the playhead for the usual length if `nil`.
    @discardableResult
    func addAnnotation(_ kind: AnnotationItem.Kind, rect: CGRect,
                       during: (start: CMTime, duration: CMTime)? = nil,
                       animation: AnnotationAnimation? = nil,
                       named name: String? = nil,
                       configure: ((inout AnnotationItem) -> Void)? = nil) -> UUID {
        let range = during ?? drawnRange
        var item = AnnotationItem(start: range.start, duration: range.duration, kind: kind, rect: rect)
        if let animation { item.animation = animation }
        // Text is sized to the box that was drawn for it. The font is a fraction of the
        // finished frame's height and the box is a fraction of it too, so one line of text
        // filling the box is simply the box's own height — a little under, to leave the
        // descenders somewhere to go. Without this a box drawn any size at all got the same
        // default size of type, which either rattled around inside it or spilled straight
        // out of it, and the first thing anybody had to do after typing was go and find the
        // size slider.
        if case .text = kind {
            item.fontSize = min(0.4, max(0.02, rect.height * 0.82))
        }
        configure?(&item)
        // And then the box is the words, so the frame on the picture starts out round the
        // label rather than round the space it was drawn in. See `AnnotationFit`.
        if AnnotationFit.isLabel(item) {
            item.rect = AnnotationFit.fitted(item, frame: outputSize, setByCaller: false)
        }
        apply(Commands.AddAnnotation(item, name: name))
        select(.annotation(item.id))
        return item.id
    }

    func setRegionRect(_ id: UUID, rect: CGRect) {
        apply(Commands.SetRegionRect(id: id, rect: rect))
    }

    func restyleAnnotation(_ id: UUID, _ name: String, _ change: @escaping @Sendable (inout AnnotationItem) -> Void) {
        // A label's box is refitted to its words whatever changed them — the text, the
        // size, the weight, the plate — so its frame on the picture is always the label.
        // See `AnnotationFit`.
        let frame = outputSize
        apply(Commands.RestyleAnnotation(id: id, name: name) { item in
            let before = item
            change(&item)
            guard AnnotationFit.needsFitting(before, item) else { return }
            item.rect = AnnotationFit.fitted(item, frame: frame, setByCaller: before.rect != item.rect)
        })
    }

    /// Resizes a text label from the canvas: its wrap width from the box, and — from a
    /// corner — its type scaled with it. One command, so the box and the type land together.
    func resizeLabel(_ id: UUID, rect: CGRect, fontSize: Double) {
        restyleAnnotation(id, "Resize") { item in
            guard !item.isLocked else { return }
            item.rect = rect
            item.fontSize = min(max(fontSize, 0.012), 0.3)
        }
    }

    /// What is on screen at the playhead, for the canvas to put handles on.
    var blursAtPlayhead: [BlurRegion] {
        timeline.blurs.filter { $0.contains(playhead) }
    }

    var annotationsAtPlayhead: [AnnotationItem] {
        timeline.annotations.filter { $0.contains(playhead) }
    }

    // MARK: - The pointer over time

    /// Hides the pointer over the selected stretch, or over a few seconds at the playhead.
    ///
    /// Two behaviours in one item on purpose: "hide the pointer *here*" is the same wish
    /// whether the user has marked a range first or has only parked the playhead, and a
    /// menu item that is disabled until a range exists teaches nobody how to make one. A
    /// selected range wins when there is one, because saying where is more specific than
    /// not saying.
    @discardableResult
    func hidePointerOverSelection() -> UUID? {
        let span = selection.range(in: timeline) ?? {
            let range = drawnRange
            return CMTimeRange(start: range.start, duration: range.duration)
        }()
        guard span.duration >= Clip.minimumDuration else {
            errorMessage = "There is no room at the playhead to hide the pointer over."
            return nil
        }
        let region = CursorRegion(start: span.start, duration: span.duration)
        apply(Commands.AddCursorRegion(region))
        guard timeline.cursorRegions.contains(where: { $0.id == region.id }) else { return nil }
        select(.cursorRegion(region.id))
        return region.id
    }

    /// Changes what one cursor region does. Undoable like every other edit.
    func restyleCursorRegion(_ id: UUID,
                             _ name: String,
                             _ change: @escaping @Sendable (inout CursorRegion) -> Void) {
        apply(Commands.RestyleCursorRegion(id: id, name: name, change))
    }

    /// The cursor region under the playhead, for the inspector to offer when nothing is
    /// selected — the pointer panel is where someone looking for this will already be.
    var cursorRegionAtPlayhead: CursorRegion? {
        timeline.cursorRegions.first { $0.contains(playhead) }
    }

    /// Reads the recorded clicks and focus events and proposes zooms.
    ///
    /// `quietly` is for the automatic pass when a project opens: a recording with no
    /// clicks in it is a perfectly ordinary recording, and saying so unprompted is a
    /// dialog nobody asked for.
    /// The zooms auto-zoom proposes for this recording as it stands.
    private func suggestedZooms() -> [ZoomRegion] {
        let track = document.manifest.track(.screen)
        let size = track?.pixelSize ?? CGSize(width: 1_920, height: 1_080)
        let scale = document.manifest.displayScale
        // The suggester works in recorded points, which is what the sidecar holds.
        let suggester = ZoomSuggester(frameSize: CGSize(width: size.width / scale, height: size.height / scale),
                                      // Against the picture as it is cropped, which is what
                                      // a zoom's centre is a fraction of.
                                      crop: timeline.style.crop?.rect ?? CropRect.full.rect,
                                      // And through the picture's own crop, for a window
                                      // resized while it was recorded — see `PictureTrack`.
                                      picture: document.pictureTrack,
                                      tuning: zoomTuning)
        // The suggester reads the recording, so what it proposes is in the recording's
        // time, over the whole recording. Placed as it came, every zoom after a cut, a
        // speed change, a freeze frame or a title landed on the wrong moment — so each is
        // put where its moment now is in the edit, and one whose moment was cut goes.
        let found = suggester.suggestions(cursor: document.cursorTrack.samples,
                                          input: document.inputSamples,
                                          focus: document.focusSamples,
                                          duration: timeline.sourceDuration)
        return timeline.placedOnTimeline(found)
    }

    /// The zooms a recording opens with, as where it starts rather than as an edit.
    ///
    /// They used to arrive as a step on the undo stack, which made a recording that had
    /// only been opened a recording with unsaved changes: it asked to be saved when it was
    /// closed, by somebody who had not touched it. They are the same kind of thing as the
    /// background and the padding a new project starts with — see `EditorDocument.adopt`.
    private func adoptSuggestedZooms() {
        var opened = document.timeline
        guard Commands.SuggestZooms(suggestedZooms()).apply(to: &opened) else { return }
        document.adopt(opened)
        refresh()
        audio?.prepare(for: timeline)
    }

    func suggestZooms(quietly: Bool = false) {
        let regions = suggestedZooms()
        guard !regions.isEmpty else {
            if !quietly { errorMessage = "Nothing in this recording looked like a moment to zoom into." }
            return
        }
        // `SuggestZooms`, not `AddZooms`: this button gets pressed more than once over a
        // take, and appending would double the last run's work and leave it fighting with
        // whatever the user has placed since. See `ZoomLane.reconciled`.
        let before = timeline.zooms
        apply(Commands.SuggestZooms(regions))
        // A run that proposed things and changed nothing is the ordinary outcome of pressing
        // the button twice, or of having already covered those moments by hand — and silence
        // there reads as a broken button rather than as agreement.
        if timeline.zooms == before, !quietly {
            errorMessage = "Auto-zoom came up with the same zooms you already have."
        }
    }

    /// Takes every zoom out, except the ones that have been locked.
    func removeAllZooms() {
        let removed = Set(timeline.zooms.filter { !$0.isLocked }.map(\.id))
        guard !removed.isEmpty else { return }
        apply(Commands.RemoveAllZooms())
        // A selection pointing at something that has gone is an inspector open on nothing.
        selected.removeAll { selection in
            if case .zoom(let id) = selection { return removed.contains(id) }
            return false
        }
    }

    /// Whether there is a zoom that "Remove All Zooms" would take out.
    var hasRemovableZooms: Bool { timeline.zooms.contains { !$0.isLocked } }

    // MARK: - The camera bubble

    /// Opens the camera's file, if there is one.
    ///
    /// After the screen's source and the sound, and failing quietly: a camera file that has
    /// gone missing or will not decode costs a bubble, and it must not stop a recording of
    /// the screen from opening. `webcamFrames` staying `nil` is exactly the state every
    /// project without a camera is already in, and the renderer draws no bubble without a
    /// frame to draw one from.
    private func openWebcamSource() async {
        guard let url = document.webcamURL else { return }
        do {
            // A small cache: the bubble is a fraction of the frame, so its decoded frames are
            // small, but there is no reason to hold as many of them as the screen's.
            webcamFrames = try await FrameSource(url: url, capacity: 12)
            refresh()
        } catch {
            Self.log.error("Couldn't open the camera's file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Puts the bubble where it was dragged to, as one undoable edit.
    ///
    /// `point` is the bubble's centre, normalised to the *output* frame — the same reading
    /// `SceneBuilder` gives `WebcamSettings.position`, so what the overlay measures and what
    /// the renderer draws cannot disagree. Setting the corner to `.custom` is part of the
    /// same change rather than a second one: a position that the corner overrides would be a
    /// drag that visibly does nothing.
    func moveWebcam(to point: CGPoint) {
        let clamped = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        apply(Commands.Restyle("Move Camera") {
            $0.webcam.corner = .custom
            $0.webcam.position = clamped
        })
    }

    /// Where the bubble is now, normalised to the output frame with a top-left origin.
    ///
    /// Read off the descriptor the preview was actually drawn from rather than recomputed
    /// from the settings, for the reason `scene` exists at all: the corners, the margin and
    /// the zoom reaction are the builder's arithmetic, and a second copy of it here would be
    /// a handle that sits somewhere the renderer is not.
    ///
    /// Only while it is a bubble: a camera a layout has spread across the frame or half of
    /// it is not a thing to drag, and a drag on it would park a bubble somewhere nobody
    /// asked for one.
    var webcamRect: CGRect? { scene?.webcam.flatMap { $0.isBubble ? $0.rect : nil } }

    /// An exporter for this project, set up the way the editor is showing it.
    ///
    /// Made here rather than in the export sheet because everything it needs — the
    /// builder measured against the real frame size, the cursor track, where the media
    /// is — already exists here, and a second assembly of the same parts is a second
    /// place for the file to come out different from the preview.
    /// - Parameter range: the part of the edit to write, or `nil` for the whole of it.
    ///   Cut by `Timeline.cut(to:)`, so the excerpt is the whole video's own frames with
    ///   the clock started at zero.
    func exporter(settings: ExportSettings, range: CMTimeRange? = nil) -> VideoExporter? {
        guard let videoURL = document.videoURL else { return nil }
        // `timeline`, never `renderedTimeline`: the latter is the flattened picture the
        // crop tool drags a rectangle over, with the crop, the zooms and the background
        // deliberately taken off. Exporting from it would quietly produce the wrong film
        // whenever the crop tool happened to be selected.
        return VideoExporter(timeline: range.map { timeline.cut(to: $0) } ?? timeline,
                             builder: builder,
                             cursor: document.cursorTrack,
                             videoURL: videoURL,
                             // Handed over unconditionally; the exporter opens it only if the
                             // timeline actually draws a bubble. `nil` for a take with no
                             // camera, which is the path every older project takes.
                             webcamURL: document.webcamURL,
                             packageURL: packageURL,
                             settings: settings)
    }

    /// What the finished file would be, before anything is written.
    func exportSize(for settings: ExportSettings) -> CGSize {
        settings.outputSize(fitting: builder.outputSize(for: timeline.style))
    }

    /// The user's auto-zoom preferences, or the suggester's own defaults when the editor
    /// was opened without settings — a preview window, a test.
    private var zoomTuning: ZoomSuggester.Tuning {
        guard let settings else { return ZoomSuggester.Tuning() }
        return ZoomSuggester.Tuning(holdAfter: settings.zoomHoldSeconds,
                                    scale: settings.zoomScale,
                                    followsFocus: settings.zoomsOnFocus,
                                    followsWindows: settings.zoomsOnWindowChange)
    }

    func deleteSelection(_ id: UUID) {
        apply(Commands.DeleteRegion(id: id))
    }

    func undo() {
        document.undo()
        refresh()
        audio?.prepare(for: timeline)
    }

    func redo() {
        document.redo()
        refresh()
        audio?.prepare(for: timeline)
    }

    /// Writes the edit now — ⌘S. Through the autosaver, so a write it has in flight is
    /// waited for rather than raced, and so the toolbar's account of saving stays true.
    func save() {
        Task {
            // No pruning of unused pictures here: the undo stack outlives a save, and
            // undoing back to a background chosen before it has to find its file. They go
            // as the window closes — see `silence()`.
            if await !autosaver.flush(), let failure = autosaver.failure {
                errorMessage = failure
            }
        }
    }

    /// Deletes imported background pictures no longer referred to.
    ///
    /// Only as the window closes with everything saved: until then undoing a background
    /// change has to be able to find the file it went back to — a save does not clear the
    /// undo stack, so pruning after ⌘S left Undo pointing at a deleted picture.
    private func pruneUnusedBackgrounds() {
        var kept: Set<String> = []
        if case .image(let path) = timeline.style.background { kept.insert(path) }
        // A background movie lives in the same folder.
        if let path = timeline.style.background.videoPath { kept.insert(path) }
        for url in BackgroundImport.unused(in: packageURL, keeping: kept) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Says something went wrong, in the one place the window shows such things.
    func report(_ error: some Error) {
        errorMessage = error.localizedDescription
    }

    func dismissError() { errorMessage = nil }

    /// Stops playing, and lets go of the sound. For a window on its way out.
    func silence() {
        // Cancelled rather than stopped: a window on its way out has nowhere to put a
        // take, and adding a region to a document that is closing would be worse than
        // losing the few seconds it holds.
        voiceover?.cancel()
        following.cancel()
        sensitive.cancel()
        if isPlaying { stop() }
        audio?.cancel()
        waveform.cancel()
        regionWaveforms.cancel()
        thumbnails.stop()
        importedMedia.stop()
        // The window has already written what it wanted written — see
        // `EditorWindowController.windowShouldClose` — so nothing is left waiting, and
        // the undo stack is going with the window: a background nothing refers to any
        // more can go too, which autosave deliberately never does on its own account.
        autosaver.stop()
        if !isDirty {
            pruneUnusedBackgrounds()
            pruneUnusedPictures()
            pruneUnusedMovies()
        }
    }
}

/// A display-link tick, wrapped so the model needs no AppKit view of its own.
///
/// A `Timer` at 30 Hz was close enough while the only thing moving was a still image;
/// next to a timeline and a playhead it reads as a stutter, and at 120 Hz it is free.
///
/// Asked of the *screen* rather than of a view: a display link is driven by the display
/// its object is on, and a bare `NSView` that was never added to a window is on no
/// display at all — so it never fires, and pressing Play does nothing but change the
/// button. The timer is the fallback for a Mac with no screen to ask.
@MainActor
private final class PlaybackTicker {
    private var link: CADisplayLink?
    private var timer: Timer?
    private let tick: () -> Void

    init(tick: @escaping () -> Void) {
        self.tick = tick
        if let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(fire))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    @objc private func fire() { tick() }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }
}
