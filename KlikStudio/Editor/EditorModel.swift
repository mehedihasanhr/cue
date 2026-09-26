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
    /// The waveforms of the sounds brought in from outside the recording. See
    /// `RegionWaveformStore` for why these are not the one above.
    let regionWaveforms: RegionWaveformStore
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
        regionWaveforms = RegionWaveformStore(package: package)

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
        guard isPlaying else { return 1 }
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
        regionWaveforms.reconcile(paths: timeline.audio.map(\.path))
        let scene = builder.descriptor(for: renderedTimeline, at: playhead, cursor: smoothedCursor)
        // Kept at full size whatever the preview draws at: this is the description of the
        // frame the export would write, and the overlays map their handles through its
        // `outputSize`. A scaled copy would work for them too, since everything they read is
        // a ratio — but "what the file will contain" is the more useful thing to publish.
        self.scene = scene

        guard renderTask == nil else {
            hasPendingRender = true
            return
        }
        startRender(of: scene)
    }

    private func startRender(of scene: SceneDescriptor) {
        let frames = frames
        // The only place the preview is allowed to differ from the export, and only while
        // the picture is moving.
        let drawn = scene.scaled(by: previewFidelity)

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
            let source = await frames?.frame(at: drawn.sourceTime)
            guard !Task.isCancelled else { return }
            let image = renderer.cgImage(for: drawn, source: source)
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
            await frames?.prefetch(around: drawn.sourceTime, forward: isPlaying)
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
        case .none, .headTrim, .tailTrim, .sound: false
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
    /// One answer for all three because they all need the same thing: a region. A clip, a
    /// range and the trim handles are footage rather than regions, and pasting footage is
    /// a different operation — the note on `CopiedRegion.placed(at:in:)` says why.
    var canCopySelection: Bool { copyable != nil }

    /// Whether Paste would do anything.
    var canPasteRegion: Bool { RegionPasteboard.shared.hasRegion }

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
        guard let region = CopiedRegion(selection, in: timeline) else { return }
        RegionPasteboard.shared.write(region)
    }

    func cutRegion(_ selection: Selection) {
        guard let region = CopiedRegion(selection, in: timeline) else { return }
        // Written before the delete, so a failed encode leaves the region where it is
        // rather than removing something the user can no longer paste back.
        RegionPasteboard.shared.write(region)
        apply(Commands.DeleteRegion(id: region.id))
        if self.selection == selection { self.selection = .none }
    }

    /// A copy of the pasteboard's region, at the playhead.
    ///
    /// The playhead rather than where the original was, because the playhead is where the
    /// user is looking and pasting on top of the original would make ⌘C ⌘V look like it
    /// did nothing. Length, scale, easing and everything else are kept; only the identity
    /// and the position are new.
    func pasteAtPlayhead() {
        guard let copied = RegionPasteboard.shared.read() else { return }
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
        guard let region = CopiedRegion(selection, in: timeline),
              let placed = region.placed(at: region.end, in: timeline) else { return }
        apply(Commands.InsertRegion(placed, name: "Duplicate \(placed.title)"))
        select(placed.selection)
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
        })
    }

    /// Turn the aiming overlay on for a zoom, having selected it.
    func aimSelectedZoom() {
        guard let zoom = activeZoom else { return }
        select(.zoom(zoom.id))
        tool = .zoom
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
    func generateCaptions() {
        guard !isGeneratingCaptions, let videoURL = document.videoURL else { return }
        isGeneratingCaptions = true
        captionProgress = nil

        Task {
            defer {
                isGeneratingCaptions = false
                captionProgress = nil
            }
            do {
                let cues = try await CaptionGenerator.cues(for: videoURL, timeline: timeline) { [weak self] done in
                    Task { @MainActor in
                        guard let self, self.isGeneratingCaptions else { return }
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
        // Cancelled rather than stopped: a window on its way out has nowhere to put a
        // take, and adding a region to a document that is closing would be worse than
        // losing the few seconds it holds.
        voiceover?.cancel()
        if isPlaying { stop() }
        audio?.cancel()
        waveform.cancel()
        regionWaveforms.cancel()
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
