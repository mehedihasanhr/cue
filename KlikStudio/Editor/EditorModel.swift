import AppKit
import BackgroundKit
import CoreMedia
import Foundation
import Observation
import os
import RecordKit
import RenderKit
import TimelineKit

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
    private(set) var errorMessage: String?

    /// What the editor is set up to do. Drives the inspector, and — for `.crop` — what
    /// the preview is actually rendering.
    var tool: EditorTool = .frame {
        didSet {
            guard tool != oldValue else { return }
            if tool.isCanvasTool || oldValue.isCanvasTool { refresh() }
        }
    }

    private(set) var selection: Selection = .none

    let viewport = TimelineViewport()
    let waveform: WaveformStore
    /// The edit, out loud — and, while it plays, the clock the playhead follows.
    private(set) var audio: PreviewAudio?

    private let renderer = SceneRenderer()
    private var builder: SceneBuilder
    private var frames: FrameSource?
    private var renderTask: Task<Void, Never>?
    private var ticker: PlaybackTicker?
    private var lastTick: Date?

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "editor")

    /// Kept, not just read at init: auto-zoom is re-run on demand from the toolbar, and
    /// it should use what the preferences say *then*.
    private let settings: StudioSettings?

    init(package: RecordingPackage, settings: StudioSettings? = nil) throws {
        self.settings = settings
        document = try EditorDocument(package: package)
        let track = document.manifest.track(.screen)
        builder = SceneBuilder(videoSize: track?.pixelSize ?? CGSize(width: 1_920, height: 1_080),
                               displayScale: document.manifest.displayScale,
                               backgrounds: StudioBackgroundResolver(),
                               packageURL: package.url)
        waveform = WaveformStore(package: package, manifest: document.manifest)

        if let settings {
            // A project opened for the first time starts as the user's defaults say —
            // background, padding, pointer. Applied only to an untouched document, so
            // changing a default never rewrites an edit someone already made.
            if !document.hasBeenEdited {
                document.adopt(settings.styled(document.timeline))
            }
            if settings.suggestsZoomsOnOpen, document.timeline.zooms.isEmpty {
                autoZoomOnOpen = true
            }
        }
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

    /// Whether the recording captured a given track. Read from the manifest rather than
    /// the asset, which is the reason the manifest lists them.
    func hasTrack(_ kind: RecordingManifest.Track.Kind) -> Bool {
        document.manifest.track(kind) != nil
    }

    /// The finished frame's size, which is what a crop changes and what the inspector
    /// reports so a heavy crop is not a silent loss of resolution.
    var outputSize: CGSize { builder.outputSize(for: timeline.style) }
    var croppedVideoSize: CGSize { builder.croppedVideoSize(for: timeline.style) }

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
                                   packageURL: document.package.url)
            if autoZoomOnOpen {
                autoZoomOnOpen = false
                suggestZooms(quietly: true)
            }
            refresh()
            waveform.load(videoURL: url)
            // Built here rather than in `init`, for the same reason the frame source is:
            // it needs the recording, and the window should be up before either is read.
            let audio = PreviewAudio(videoURL: url, packageURL: document.package.url, settings: settings)
            audio.prepare(for: timeline)
            self.audio = audio
        } catch {
            errorMessage = error.localizedDescription
            Self.log.error("Couldn't open \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Playhead

    func scrub(to time: CMTime) {
        playhead = max(.zero, min(time, duration))
        audio?.follow(playhead)
        viewport.reveal(playhead, duration: duration)
        refresh()
    }

    func step(_ seconds: Double) {
        scrub(to: playhead + CMTime(seconds: seconds, preferredTimescale: 600))
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

    private func play() {
        guard frames != nil else { return }
        if playhead >= duration { playhead = .zero }
        isPlaying = true
        lastTick = .now
        viewport.followsPlayhead = true
        audio?.play(from: playhead, timeline: timeline)
        Task { await frames?.setQuality(.preview(previewPixelSize)) }

        ticker = PlaybackTicker { [weak self] in
            guard let self, let last = self.lastTick else { return }
            let now = Date.now
            self.lastTick = now
            // The sound is the clock when there is sound. A wall-clock playhead drifts
            // against the audio over a long take — slowly, and then unmistakably, because
            // one of them is being resampled by a real audio device and the other is not.
            // The picture may drop a frame; the sound may not, so the picture follows it.
            let next = self.audio?.clock
                ?? self.playhead + CMTime(seconds: now.timeIntervalSince(last), preferredTimescale: 600)
            if next >= self.duration {
                self.playhead = self.duration
                self.stop()
            } else {
                self.playhead = next
                self.viewport.reveal(self.playhead, duration: self.duration)
                self.refreshIfIdle()
            }
        }
    }

    private func stop() {
        isPlaying = false
        audio?.pause()
        ticker?.stop()
        ticker = nil
        lastTick = nil
        Task { [weak self] in
            await self?.frames?.setQuality(.exact)
            self?.refresh()
        }
    }

    /// Roughly what the preview pane can show. Seeking a full-resolution 4K frame with
    /// zero tolerance thirty times a second is the single most expensive thing the
    /// editor used to do, and none of that detail reaches the screen while it moves.
    private var previewPixelSize: CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: 1_280 * scale, height: 720 * scale)
    }

    // MARK: - Rendering

    /// Re-renders the frame under the playhead.
    ///
    /// One render in flight at a time: dragging the scrubber asks for a new frame far
    /// faster than a 4K frame can be decoded, and queueing them all would make the
    /// picture lag the pointer by seconds.
    func refresh() {
        renderTask?.cancel()
        validateSelection()
        let scene = builder.descriptor(for: renderedTimeline, at: playhead, cursor: smoothedCursor)
        self.scene = scene
        let frames = frames

        renderTask = Task { [renderer] in
            defer { if !Task.isCancelled { self.renderTask = nil } }
            let source = await frames?.frame(at: scene.sourceTime)
            guard !Task.isCancelled else { return }
            let image = renderer.cgImage(for: scene, source: source)
            guard !Task.isCancelled, let image else { return }
            preview = NSImage(cgImage: image, size: scene.outputSize)
            await frames?.prefetch(around: scene.sourceTime, forward: isPlaying)
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

    private func refreshIfIdle() {
        guard renderTask == nil else { return }
        refresh()
    }

    /// What the preview is showing, which is not always the edit.
    ///
    /// Cropping is direct manipulation of the source frame, and the composited picture —
    /// padded, rounded, zoomed, already cropped — is not a thing you can drag a crop
    /// rectangle over. In crop mode the preview shows the whole recording, flat, so the
    /// mapping from a point on screen to a point in the footage is one aspect-fit.
    private var renderedTimeline: Timeline {
        guard tool.flattensPreview else { return timeline }
        var draft = timeline
        draft.style.crop = nil
        draft.style.aspect = .source
        draft.style.padding = 0
        draft.style.cornerRadius = 0
        draft.style.shadowOpacity = 0
        draft.style.background = .color(ColorValue(r: 0.06, g: 0.06, b: 0.07))
        draft.zooms = []
        return draft
    }

    /// The preview's own frame size, which differs from the export's while cropping.
    var previewSize: CGSize {
        builder.outputSize(for: renderedTimeline.style)
    }

    // MARK: - Selection

    func select(_ selection: Selection) {
        guard self.selection != selection else { return }
        self.selection = selection
    }

    func clearSelection() { selection = .none }

    /// Drops a selection that an edit has invalidated.
    ///
    /// Needed because `ClipSequence.clampRegions` quietly removes any region an edit
    /// shortened past `Clip.minimumDuration` — a selection can stop being valid without
    /// anything having deleted it.
    private func validateSelection() {
        if !selection.isValid(in: timeline) { selection = .none }
    }

    /// Whether Delete would do anything, so the menu item can be honest about it.
    var canDeleteSelection: Bool {
        switch selection {
        case .none, .headTrim, .tailTrim: false
        case .clip: timeline.clips.count > 1
        case .range(let range): range.duration > .zero
        default: true
        }
    }

    func deleteSelection() {
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
        selection = .none
    }

    func selectAll() {
        guard duration > .zero else { return }
        select(.range(CMTimeRange(start: .zero, duration: duration)))
    }

    // MARK: - Editing

    func apply(_ command: some TimelineCommand) {
        guard document.apply(command) else { return }
        refresh()
        audio?.prepare(for: timeline)
    }

    func change(_ name: String, _ mutate: (inout Timeline) -> Void) {
        document.change(name, mutate)
        refresh()
        audio?.prepare(for: timeline)
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

    /// Listens to the recording and writes down what was said.
    ///
    /// Replaces whatever captions were there, as one undoable step: a transcript is a
    /// single thing the user asked for, and taking it back should not be two hundred
    /// presses of ⌘Z.
    func generateCaptions() {
        guard !isGeneratingCaptions, let videoURL = document.videoURL else { return }
        isGeneratingCaptions = true

        Task {
            defer { isGeneratingCaptions = false }
            do {
                let cues = try await CaptionGenerator.cues(for: videoURL, timeline: timeline)
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

    /// Hides something: a password, a name, a face.
    @discardableResult
    func addBlur(rect: CGRect) -> UUID {
        let range = drawnRange
        let region = BlurRegion(start: range.start, duration: range.duration, rect: rect)
        apply(Commands.AddBlur(region))
        select(.blur(region.id))
        return region.id
    }

    /// Puts something on top: a label, an arrow, a box.
    @discardableResult
    func addAnnotation(_ kind: AnnotationItem.Kind, rect: CGRect) -> UUID {
        let range = drawnRange
        let item = AnnotationItem(start: range.start, duration: range.duration, kind: kind, rect: rect)
        apply(Commands.AddAnnotation(item))
        select(.annotation(item.id))
        return item.id
    }

    func setRegionRect(_ id: UUID, rect: CGRect) {
        apply(Commands.SetRegionRect(id: id, rect: rect))
    }

    func restyleAnnotation(_ id: UUID, _ name: String, _ change: @escaping @Sendable (inout AnnotationItem) -> Void) {
        apply(Commands.RestyleAnnotation(id: id, name: name, change))
    }

    /// What is on screen at the playhead, for the canvas to put handles on.
    var blursAtPlayhead: [BlurRegion] {
        timeline.blurs.filter { $0.contains(playhead) }
    }

    var annotationsAtPlayhead: [AnnotationItem] {
        timeline.annotations.filter { $0.contains(playhead) }
    }

    /// Reads the recorded clicks and focus events and proposes zooms.
    ///
    /// `quietly` is for the automatic pass when a project opens: a recording with no
    /// clicks in it is a perfectly ordinary recording, and saying so unprompted is a
    /// dialog nobody asked for.
    func suggestZooms(quietly: Bool = false) {
        let track = document.manifest.track(.screen)
        let size = track?.pixelSize ?? CGSize(width: 1_920, height: 1_080)
        let scale = document.manifest.displayScale
        // The suggester works in recorded points, which is what the sidecar holds.
        let suggester = ZoomSuggester(frameSize: CGSize(width: size.width / scale, height: size.height / scale),
                                      tuning: zoomTuning)
        let regions = suggester.suggestions(cursor: document.cursorTrack.samples,
                                            input: document.inputSamples,
                                            focus: document.focusSamples,
                                            duration: duration)
        guard !regions.isEmpty else {
            if !quietly { errorMessage = "Nothing in this recording looked like a moment to zoom into." }
            return
        }
        apply(Commands.AddZooms(regions))
    }

    /// An exporter for this project, set up the way the editor is showing it.
    ///
    /// Made here rather than in the export sheet because everything it needs — the
    /// builder measured against the real frame size, the cursor track, where the media
    /// is — already exists here, and a second assembly of the same parts is a second
    /// place for the file to come out different from the preview.
    func exporter(settings: ExportSettings) -> VideoExporter? {
        guard let videoURL = document.videoURL else { return nil }
        // `timeline`, never `renderedTimeline`: the latter is the flattened picture the
        // crop tool drags a rectangle over, with the crop, the zooms and the background
        // deliberately taken off. Exporting from it would quietly produce the wrong film
        // whenever the crop tool happened to be selected.
        return VideoExporter(timeline: timeline,
                             builder: builder,
                             cursor: document.cursorTrack,
                             videoURL: videoURL,
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
        return ZoomSuggester.Tuning(scale: settings.zoomScale,
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

    func save() {
        do {
            try document.save()
            pruneUnusedBackgrounds()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes imported background pictures no longer referred to.
    ///
    /// After the save, never before: undoing a background change has to be able to find
    /// the file it went back to.
    private func pruneUnusedBackgrounds() {
        var kept: Set<String> = []
        if case .image(let path) = timeline.style.background { kept.insert(path) }
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
        if isPlaying { stop() }
        audio?.cancel()
        waveform.cancel()
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
