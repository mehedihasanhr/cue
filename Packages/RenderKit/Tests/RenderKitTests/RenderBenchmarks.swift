import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// Where the time goes.
///
/// Off by default. These measure rather than assert: they take seconds rather than
/// milliseconds, their numbers depend on the machine and on what else it is doing, and a
/// suite that takes a minute is a suite nobody runs. They are here so a claim about
/// performance can be checked instead of believed —
///
///     KLIK_BENCH=1 swift test --filter RenderBenchmarks
///
/// What they measure is **throughput and per-call cost**. Nothing here can see a dropped
/// frame, a hitch while scrubbing or a scroll that does not keep up: those live in the
/// window server and in a person's eye, and neither is reachable from a test process.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KLIK_BENCH"] != nil,
                "set KLIK_BENCH=1 to measure"),
       .serialized,
       .timeLimit(.minutes(5)))
struct RenderBenchmarks {

    // MARK: - Describing a frame

    /// The pure function, on a heavy but plausible project.
    ///
    /// Reported four ways, because they separate the suspects: the whole call, the call
    /// with no pointer track (so no averaging, no smoothing lookups), the call with the
    /// pointer's motion blur off (which is what doubles the pointer arithmetic), and the
    /// call on a bare timeline (which is the floor — layout and nothing else).
    @Test func describingAFrame() {
        let timeline = RenderWorkload.timeline()
        let track = RenderWorkload.cursorTrack()
        let builder = RenderWorkload.builder()
        let times = (0..<600).map { RenderWorkload.time(Double($0) / 10) }

        var bare = timeline
        bare.zooms = []; bare.blurs = []; bare.annotations = []
        bare.captions = []; bare.cursorRegions = []

        var still = timeline
        still.cursor.motionBlur = false

        RenderWorkload.report("descriptor, full project", microseconds: RenderWorkload.median(count: 600) {
            _ = builder.descriptor(for: timeline, at: times[$0 % times.count], cursor: track)
        })
        RenderWorkload.report("descriptor, no motion blur", microseconds: RenderWorkload.median(count: 600) {
            _ = builder.descriptor(for: still, at: times[$0 % times.count], cursor: track)
        })
        RenderWorkload.report("descriptor, no cursor track", microseconds: RenderWorkload.median(count: 600) {
            _ = builder.descriptor(for: timeline, at: times[$0 % times.count], cursor: nil)
        })
        RenderWorkload.report("descriptor, bare timeline", microseconds: RenderWorkload.median(count: 600) {
            _ = builder.descriptor(for: bare, at: times[$0 % times.count], cursor: track)
        })
    }

    /// How the cost grows with the number of regions.
    ///
    /// Every region search in the builder is a linear scan, so the expectation is linear;
    /// what this is really for is finding out whether the constant is small enough that
    /// linear does not matter, and whether anything is quietly quadratic.
    @Test func describingAFrameAsRegionsPileUp() {
        let track = RenderWorkload.cursorTrack()
        let builder = RenderWorkload.builder()
        for count in [1, 8, 32, 128, 512] {
            let timeline = RenderWorkload.timeline(regions: count)
            let times = (0..<200).map { RenderWorkload.time(Double($0) * 0.29) }
            let each = RenderWorkload.median(count: 400) {
                _ = builder.descriptor(for: timeline, at: times[$0 % times.count], cursor: track)
            }
            RenderWorkload.report("descriptor, \(count) of each region", microseconds: each,
                                  extra: String(format: "%.3f µs/region", each / Double(count)))
        }
    }

    /// The pointer track's own lookups, which the descriptor leans on several times over.
    @Test func lookingUpThePointer() {
        let track = RenderWorkload.cursorTrack()
        RenderWorkload.report("track.position", microseconds: RenderWorkload.median(count: 2_000) {
            _ = track.position(at: Double($0 % 600) / 10)
        })
        RenderWorkload.report("track.averagePosition window 0.25", microseconds: RenderWorkload.median(count: 2_000) {
            _ = track.averagePosition(at: Double($0 % 600) / 10, window: 0.25)
        })
        RenderWorkload.report("track.averagePosition window 0.5", microseconds: RenderWorkload.median(count: 2_000) {
            _ = track.averagePosition(at: Double($0 % 600) / 10, window: 0.5)
        })
        RenderWorkload.report("track.smoothed(0.4) — whole take", microseconds: RenderWorkload.median(count: 5, warmup: 1) { _ in
            _ = track.smoothed(0.4)
        })
    }

    /// What the timeline itself charges per frame.
    @Test func askingTheTimeline() {
        let timeline = RenderWorkload.timeline()
        RenderWorkload.report("timeline.sourceTime", microseconds: RenderWorkload.median(count: 4_000) {
            _ = timeline.sourceTime(at: RenderWorkload.time(Double($0 % 600) / 10))
        })
        RenderWorkload.report("timeline.cursorOverride (24 regions)", microseconds: RenderWorkload.median(count: 4_000) {
            _ = timeline.cursorOverride(at: RenderWorkload.time(Double($0 % 600) / 10))
        })
    }

    // MARK: - Drawing a frame

    /// The compositing, at the two sizes that matter.
    ///
    /// `image(for:)` builds the Core Image graph and returns immediately — Core Image is
    /// lazy — so it is timed apart from `render(to:)`, which is where the GPU work
    /// actually happens. A graph that is expensive to *build* is a per-frame cost the
    /// preview pays on the main actor; a graph that is expensive to *run* is not.
    @Test func drawingAFrame() throws {
        let timeline = RenderWorkload.timeline()
        let track = RenderWorkload.cursorTrack()
        let renderer = SceneRenderer()

        for size in [CGSize(width: 1_280, height: 720),
                     CGSize(width: 1_920, height: 1_080),
                     CGSize(width: 3_840, height: 2_160)] {
            let builder = SceneBuilder(videoSize: size, displayScale: 2)
            let source = RenderWorkload.source(size)
            let scenes = (0..<60).map {
                builder.descriptor(for: timeline, at: RenderWorkload.time(Double($0) * 0.9), cursor: track)
            }
            let label = "\(Int(size.width))×\(Int(size.height))"

            RenderWorkload.report("graph build, \(label)", microseconds: RenderWorkload.median(count: 120) {
                _ = renderer.image(for: scenes[$0 % scenes.count], source: source)
            })
            // The same graph with one overlay taken out at a time, so the per-frame
            // Core Graphics drawing can be told apart from the Core Image book-keeping.
            let noCaption = scenes.map { var scene = $0; scene.caption = nil; return scene }
            RenderWorkload.report("graph build, no caption, \(label)", microseconds: RenderWorkload.median(count: 120) {
                _ = renderer.image(for: noCaption[$0 % noCaption.count], source: source)
            })
            let bare = noCaption.map { var scene = $0; scene.annotations = []; scene.cursor = nil; return scene }
            RenderWorkload.report("graph build, no overlays at all, \(label)", microseconds: RenderWorkload.median(count: 120) {
                _ = renderer.image(for: bare[$0 % bare.count], source: source)
            })

            let buffer = try Self.pixelBuffer(size)
            RenderWorkload.report("render to buffer, \(label)", microseconds: RenderWorkload.median(count: 60) {
                renderer.render(scenes[$0 % scenes.count], source: source, to: buffer)
            })
            RenderWorkload.report("cgImage (what the preview asks for), \(label)",
                                  microseconds: RenderWorkload.median(count: 40) {
                _ = renderer.cgImage(for: scenes[$0 % scenes.count], source: source)
            })
        }
    }

    /// The same frame described smaller, which is what the preview does while it moves.
    ///
    /// The comparison the preview's fidelity switch rests on. A 4K project composites eight
    /// megapixels to fill a pane a few hundred points across; the rows below are the cost of
    /// that frame at full size and at the fractions of it a real pane asks for. The `graph
    /// build` rows are here too because they are the part the main actor pays synchronously
    /// — if describing the smaller frame cost *more* to set up, the saving on the GPU would
    /// be beside the point.
    @Test func drawingAFrameAtPreviewScale() {
        let timeline = RenderWorkload.timeline()
        let track = RenderWorkload.cursorTrack()
        let renderer = SceneRenderer()
        let size = CGSize(width: 3_840, height: 2_160)
        let builder = SceneBuilder(videoSize: size, displayScale: 2)
        let source = RenderWorkload.source(size)
        let scenes = (0..<60).map {
            builder.descriptor(for: timeline, at: RenderWorkload.time(Double($0) * 0.9), cursor: track)
        }

        // 1 is the frame at rest, which must stay exactly what the export writes; the rest
        // are a 4K project in a pane roughly 1000, 700 and 500 points wide on a 2× display.
        for factor in [1.0, 0.5, 0.35, 0.25] {
            let scaled = scenes.map { $0.scaled(by: factor) }
            let label = String(format: "%.2f× (%d×%d)", factor,
                               Int(scaled[0].outputSize.width), Int(scaled[0].outputSize.height))
            RenderWorkload.report("preview graph build, 4K scene at \(label)",
                                  microseconds: RenderWorkload.median(count: 120) {
                _ = renderer.image(for: scaled[$0 % scaled.count], source: source)
            })
            RenderWorkload.report("preview cgImage, 4K scene at \(label)",
                                  microseconds: RenderWorkload.median(count: 40) {
                _ = renderer.cgImage(for: scaled[$0 % scaled.count], source: source)
            })
        }
    }

    /// The per-frame artwork, drawn through Core Graphics rather than Core Image.
    ///
    /// Separated out because these are `CGContext`s created per call, which is the one
    /// shape of per-frame cost the codebase already decided was worth caching for the
    /// pointer — the question is whether the caption and the label deserve the same.
    @Test func drawingTheOverlays() {
        let output = CGSize(width: 1_920, height: 1_080)
        let caption = CaptionLayer(text: "And then we click the button that says step 4.",
                                   fontSize: 0.05,
                                   color: ColorValue(r: 1, g: 1, b: 1),
                                   backgroundOpacity: 0.55,
                                   position: .bottom,
                                   margin: 0.06)
        RenderWorkload.report("CaptionArtwork.image", microseconds: RenderWorkload.median(count: 300) { _ in
            _ = CaptionArtwork.image(caption, outputSize: output)
        })
        // What it cost before the plate was kept: the cache emptied before every call, so
        // every call lays the text out and draws a bitmap, which is what the old code did
        // unconditionally.
        RenderWorkload.report("CaptionArtwork.image, uncached", microseconds: RenderWorkload.median(count: 100) { _ in
            CaptionArtwork.clearCache()
            _ = CaptionArtwork.image(caption, outputSize: output)
        })
        for size in [CGSize(width: 1_280, height: 720), CGSize(width: 3_840, height: 2_160)] {
            RenderWorkload.report("CaptionArtwork.image, uncached, \(Int(size.height))p",
                                  microseconds: RenderWorkload.median(count: 100) { _ in
                CaptionArtwork.clearCache()
                _ = CaptionArtwork.image(caption, outputSize: size)
            })
        }

        let annotation = AnnotationLayer(kind: .text("Step 4"),
                                         rect: CGRect(x: 0.55, y: 0.1, width: 0.35, height: 0.1),
                                         color: ColorValue(r: 1, g: 0.23, b: 0.19),
                                         fontSize: 0.06,
                                         opacity: 1)
        let rect = CGRect(x: 0.55 * output.width, y: 0.1 * output.height,
                          width: 0.35 * output.width, height: 0.1 * output.height)
        RenderWorkload.report("AnnotationArtwork.image (text)", microseconds: RenderWorkload.median(count: 300) { _ in
            _ = AnnotationArtwork.image(annotation, in: rect, outputHeight: output.height)
        })
        RenderWorkload.report("AnnotationArtwork.image (text), uncached",
                              microseconds: RenderWorkload.median(count: 100) { _ in
            AnnotationArtwork.clearCache()
            _ = AnnotationArtwork.image(annotation, in: rect, outputHeight: output.height)
        })

        RenderWorkload.report("CursorArtwork.image (cached)", microseconds: RenderWorkload.median(count: 2_000) {
            _ = CursorArtwork.image(.arrow, size: 40 + Double($0 % 3))
        })
    }

    // MARK: - Scrubbing

    /// What a fast drag of the scrubber actually costs.
    ///
    /// `EditorModel.refresh` does three things per playhead change: describe the frame on
    /// the main actor, seek, and render. Only the first is synchronous on the main actor,
    /// so it is the one a drag can be blocked by — the seek and the render are cancelled
    /// and restarted. This measures the synchronous part at the rate a trackpad produces
    /// events, and separately the frame source's seek, which is what the render task is
    /// mostly waiting on.
    @Test func scrubbing() async throws {
        let timeline = RenderWorkload.timeline()
        let track = RenderWorkload.cursorTrack()
        let builder = RenderWorkload.builder()

        // A drag across ten seconds of timeline at 120 events a second, which is roughly
        // what a trackpad on a 120 Hz display delivers.
        let drag = (0..<1_200).map { RenderWorkload.time(10 + Double($0) / 120) }
        let each = RenderWorkload.median(count: 1_200) {
            _ = builder.descriptor(for: timeline, at: drag[$0 % drag.count], cursor: track)
        }
        RenderWorkload.report("main-actor work per scrub event", microseconds: each,
                              extra: String(format: "%.1f%% of a 120 Hz frame", each / 8_333 * 100))

        // And the seek behind it, against a real file.
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("scrub.mov")
        let size = CGSize(width: 1_920, height: 1_080)
        try await ExportTests.writeSilentVideo(to: movie, size: size, frames: 120, frameRate: 30)

        let source = try await FrameSource(url: movie)
        for quality in [FrameSource.Quality.exact, .preview(CGSize(width: 1_280, height: 720))] {
            await source.setQuality(quality)
            // Fresh times every call, so this is seeking rather than reading the cache.
            let clock = ContinuousClock()
            var samples: [Double] = []
            for index in 0..<24 {
                let at = CMTime(seconds: 0.1 + Double(index) * 0.13, preferredTimescale: 600)
                let elapsed = await clock.measure { _ = await source.frame(at: at) }
                samples.append(Double(elapsed.components.attoseconds) / 1e12)
                await source.clearCache()
            }
            samples.sort()
            let label = quality == .exact ? "exact" : "preview"
            RenderWorkload.report("FrameSource seek, cold, \(label)", microseconds: samples[samples.count / 2])
        }

        // The cache is the other half of the story: a scrub back over ground already
        // covered should cost nothing at all.
        await source.setQuality(.exact)
        _ = await source.frame(at: CMTime(seconds: 1, preferredTimescale: 600))
        let clock = ContinuousClock()
        var hits: [Double] = []
        for _ in 0..<200 {
            let elapsed = await clock.measure { _ = await source.frame(at: CMTime(seconds: 1, preferredTimescale: 600)) }
            hits.append(Double(elapsed.components.attoseconds) / 1e12)
        }
        hits.sort()
        RenderWorkload.report("FrameSource seek, cached", microseconds: hits[hits.count / 2])
    }

    /// What a relaxed seek tolerance actually buys — asked directly of the generator.
    ///
    /// The one measurement that decides whether the preview may show a *different frame*
    /// while it plays. `FrameSource.Quality.preview` already sets a tolerance of 1/120 s,
    /// which at 30 fps is narrower than a single frame, so it can never let the generator
    /// hand back something it has already decoded. The rows below widen it to one frame, two
    /// frames, half a second and "anything you like", against the same file, so the question
    /// can be answered with a number instead of an argument. If a whole group of pictures'
    /// worth of slack does not move the median, then the cost is the decode itself and no
    /// amount of tolerance is going to touch it.
    ///
    /// Deliberately not routed through `FrameSource`: adding a tolerance knob to production
    /// code in order to find out whether production code should have one is how a feature
    /// gets shipped by accident.
    @Test func seekingWithARelaxedTolerance() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("tolerance.mov")
        try await ExportTests.writeSilentVideo(to: movie,
                                              size: CGSize(width: 1_920, height: 1_080),
                                              frames: 120, frameRate: 30)

        let cases: [(String, CMTime)] = [
            ("zero (what scrubbing uses)", .zero),
            ("1/120 s (what playback uses today)", CMTime(value: 1, timescale: 120)),
            ("one frame at 30 fps", CMTime(value: 1, timescale: 30)),
            ("two frames at 30 fps", CMTime(value: 2, timescale: 30)),
            ("half a second", CMTime(value: 1, timescale: 2)),
            ("positiveInfinity", .positiveInfinity),
        ]
        for (label, tolerance) in cases {
            // A fresh generator per case: a generator that has already decoded around a
            // time is not seeking cold any more, and the whole question here is cold cost.
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            generator.maximumSize = CGSize(width: 1_280, height: 720)

            let clock = ContinuousClock()
            var samples: [Double] = []
            for index in 0..<24 {
                let at = CMTime(seconds: 0.1 + Double(index) * 0.13, preferredTimescale: 600)
                let elapsed = await clock.measure {
                    _ = await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                        generator.generateCGImageAsynchronously(for: at) { image, _, _ in
                            continuation.resume(returning: image)
                        }
                    }
                }
                samples.append(Double(elapsed.components.attoseconds) / 1e12)
            }
            samples.sort()
            RenderWorkload.report("seek, tolerance \(label)", microseconds: samples[samples.count / 2])
        }
    }

    /// A burst of scrub events, with and without coalescing.
    ///
    /// `EditorModel.refresh` used to cancel its render task and start another on every
    /// playhead change. Cancelling a `Task` cannot stop a decode that is already inside
    /// `AVAssetImageGenerator`, and the frame source is an actor, so a fast drag queued one
    /// full decode per event and the frame the pointer is actually over came back last. This
    /// measures the only number that matters to a drag: how long until the picture under the
    /// pointer is on screen.
    ///
    /// "backlog" asks for all twenty times at once, as the old code did. "coalesced" asks for
    /// the first, then — holding only the latest request — asks for the twentieth, which is
    /// what the pending-render latch in `refresh` now does.
    @Test func scrubbingABurstOfEvents() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("burst.mov")
        try await ExportTests.writeSilentVideo(to: movie,
                                              size: CGSize(width: 1_920, height: 1_080),
                                              frames: 120, frameRate: 30)
        let source = try await FrameSource(url: movie)
        // Times 40 ms apart and far enough from each other to miss the 20 ms cache buckets:
        // a drag over new ground, which is the expensive case.
        let burst = (0..<20).map { CMTime(seconds: 0.2 + Double($0) * 0.04, preferredTimescale: 600) }
        let clock = ContinuousClock()

        await source.clearCache()
        let backlog = await clock.measure {
            await withTaskGroup(of: Void.self) { group in
                for at in burst { group.addTask { _ = await source.frame(at: at) } }
            }
        }
        RenderWorkload.report("scrub burst of 20, backlog (every event decoded)",
                              microseconds: Double(backlog.components.attoseconds) / 1e12
                                  + Double(backlog.components.seconds) * 1e6)

        await source.clearCache()
        let coalesced = await clock.measure {
            _ = await source.frame(at: burst[0])
            _ = await source.frame(at: burst[burst.count - 1])
        }
        RenderWorkload.report("scrub burst of 20, coalesced (first and latest only)",
                              microseconds: Double(coalesced.components.attoseconds) / 1e12
                                  + Double(coalesced.components.seconds) * 1e6)
    }

    // MARK: - Export

    /// Frames a second out of the whole pipeline, and where those frames spend their time.
    ///
    /// Two passes over the same synthetic recording: one through `VideoExporter` for the
    /// real number, and one that walks the same frames by hand with a clock around each
    /// stage, because the exporter cannot be instrumented from outside and is another
    /// agent's file.
    @Test func exportThroughput() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("source.mov")
        let size = CGSize(width: 1_920, height: 1_080)
        let frames = 150
        try await ExportTests.writeSilentVideo(to: movie, size: size, frames: frames, frameRate: 30)

        let timeline = RenderWorkload.timeline(regions: 8, duration: 5)
        let track = RenderWorkload.cursorTrack(duration: 5)
        let builder = SceneBuilder(videoSize: size, displayScale: 2)

        let settings = ExportSettings(format: .mp4, frameRate: 30, includesAudio: false)
        let exporter = VideoExporter(timeline: timeline,
                                     builder: builder,
                                     cursor: track,
                                     videoURL: movie,
                                     packageURL: nil,
                                     settings: settings)
        let started = ContinuousClock.now
        try await exporter.export(to: folder.appendingPathComponent("out.mp4"))
        let elapsed = Double((ContinuousClock.now - started).components.seconds)
            + Double((ContinuousClock.now - started).components.attoseconds) / 1e18
        print(String(format: "BENCH %-46@ %9.2f s   %8.1f fps",
                     "VideoExporter, 5 s at 1080p30" as NSString, elapsed, Double(frames) / elapsed))

        // The same work, stage by stage.
        let reader = try await ExportFrameReader(url: movie)
        _ = await reader.naturalSize()
        let renderer = SceneRenderer()
        let smoothed = track.smoothed(timeline.cursor.smoothing)
        let buffer = try Self.pixelBuffer(builder.outputSize(for: timeline.style))

        var describe = 0.0, decode = 0.0, graph = 0.0, draw = 0.0
        let clock = ContinuousClock()
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        // Emptying the artwork caches before each frame reproduces exactly what the
        // renderer did before they existed: every plate and every label drawn again from
        // nothing. Measured in the same run as the cached path, on the same machine, so the
        // before and after in the report are a comparison rather than two anecdotes.
        var uncachedGraph = 0.0
        for index in 0..<frames {
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            let scene = builder.descriptor(for: timeline, at: time, cursor: smoothed)
            let frame = try? reader.frame(at: timeline.sourceTime(at: time) ?? time)
            CaptionArtwork.clearCache()
            AnnotationArtwork.clearCache()
            uncachedGraph += seconds(clock.measure { _ = renderer.image(for: scene, source: frame) })
        }
        RenderWorkload.report("export stage: graph build, artwork uncached",
                              microseconds: uncachedGraph / Double(frames) * 1e6)

        for index in 0..<frames {
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            var scene: SceneDescriptor?
            describe += seconds(clock.measure {
                scene = builder.descriptor(for: timeline, at: time, cursor: smoothed)
            })
            guard let scene else { continue }
            var frame: CIImage?
            decode += seconds(clock.measure {
                frame = try? reader.frame(at: timeline.sourceTime(at: time) ?? time)
            })
            var image: CIImage?
            graph += seconds(clock.measure {
                image = renderer.image(for: scene, source: frame)
            })
            guard let image else { continue }
            draw += seconds(clock.measure {
                renderer.context.render(image, to: buffer,
                                        bounds: CGRect(origin: .zero, size: scene.outputSize),
                                        colorSpace: renderer.colorSpace)
            })
        }
        reader.cancel()
        let total = describe + decode + graph + draw
        for (name, value) in [("scene building", describe), ("decode", decode),
                              ("graph build", graph), ("render + encode-ready draw", draw)] {
            RenderWorkload.report("export stage: \(name)", microseconds: value / Double(frames) * 1e6,
                                  extra: String(format: "%4.1f%% of measured", value / total * 100))
        }
    }

    // MARK: - Memory

    /// Whether anything grows without bound over a long playback.
    ///
    /// Resident size is a blunt instrument — the allocator does not hand pages back the
    /// moment an object dies, so a rise is not proof of a leak — but a cache with no
    /// ceiling shows up as a rise that does not stop, and that is what this looks for.
    @Test func memoryOverALongPlayback() throws {
        let timeline = RenderWorkload.timeline()
        let track = RenderWorkload.cursorTrack()
        let builder = SceneBuilder(videoSize: CGSize(width: 1_280, height: 720), displayScale: 2)
        let renderer = SceneRenderer()
        let source = RenderWorkload.source(CGSize(width: 1_280, height: 720))
        let buffer = try Self.pixelBuffer(builder.outputSize(for: timeline.style))

        // Warm first, so the number is growth rather than start-up.
        for index in 0..<120 {
            let scene = builder.descriptor(for: timeline, at: RenderWorkload.time(Double(index) / 30), cursor: track)
            renderer.render(scene, source: source, to: buffer)
        }
        let before = RenderWorkload.residentBytes() ?? 0

        // Half a minute of playback at 30 fps, with the pointer's scale animating so the
        // artwork cache is asked for a size it has not seen.
        var timeline2 = timeline
        for index in 0..<900 {
            timeline2.cursor.scale = 1 + Double(index % 60) / 200
            let scene = builder.descriptor(for: timeline2, at: RenderWorkload.time(Double(index) / 30), cursor: track)
            renderer.render(scene, source: source, to: buffer)
        }
        let after = RenderWorkload.residentBytes() ?? 0
        let grown = Double(Int64(after) - Int64(before)) / 1_048_576
        print(String(format: "BENCH %-46@ %9.1f MB grown over 900 frames", "renderer residency" as NSString, grown))

        // The same loop with the autorelease pool drained per frame.
        //
        // Core Image and Core Graphics are Objective-C, and everything they hand back is
        // autoreleased: a tight synchronous loop holds every intermediate until the pool
        // at the top drains, which here is the end of the test. Measured separately so the
        // number above can be read as what it is — a pool that nobody drained — rather
        // than as a cache with no ceiling. The app's own loops both suspend, which drains
        // the pool for them; this is the difference that tells us so.
        let beforePooled = RenderWorkload.residentBytes() ?? 0
        for index in 0..<900 {
            autoreleasepool {
                timeline2.cursor.scale = 1 + Double(index % 60) / 200
                let scene = builder.descriptor(for: timeline2, at: RenderWorkload.time(Double(index) / 30), cursor: track)
                renderer.render(scene, source: source, to: buffer)
            }
        }
        let afterPooled = RenderWorkload.residentBytes() ?? 0
        print(String(format: "BENCH %-46@ %9.1f MB grown over 900 frames",
                     "renderer residency, pool drained per frame" as NSString,
                     Double(Int64(afterPooled) - Int64(beforePooled)) / 1_048_576))
    }

    // MARK: - Odds and ends

    private static func pixelBuffer(_ size: CGSize) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                         kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                                         &buffer)
        return try #require(status == kCVReturnSuccess ? buffer : nil)
    }

    private static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("klik-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Editing a zoom by hand

    /// What a framing drag costs, per pointer event.
    ///
    /// The three things a drag actually does sixty times a second: work out the new
    /// rectangle, clamp it to what the camera will honour, and re-describe the frame so the
    /// overlay has a current mapping to draw against. The decode is *not* in here and that
    /// is the point — framing renders the timeline with its zooms taken out, so the picture
    /// under the box cannot change while the box moves, and the model skips it for the whole
    /// gesture. See `ZoomFramingAgreementTests.aFramingDragCannotChangeTheFrameUnderTheBox`.
    ///
    /// The budget to read these against is 16.6 ms, one frame at 60 Hz.
    @Test func draggingAFramingBox() {
        let timeline = RenderWorkload.timeline()
        var framing = timeline
        framing.zooms = []
        let builder = RenderWorkload.builder()
        let track = RenderWorkload.cursorTrack()
        let at = RenderWorkload.time(4)
        let mapping = PictureMapping(stage: CGRect(x: 30, y: 12, width: 1_280, height: 720),
                                     video: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        var area = ZoomFraming.area(of: ZoomRegion(start: .zero, duration: .zero, scale: 2))

        RenderWorkload.report("framing: geometry alone", microseconds: RenderWorkload.median(count: 2_000) { step in
            let delta = mapping.delta(view: CGSize(width: Double(step % 7) - 3, height: 2))
            area = ZoomFraming.moved(area, by: delta)
            _ = mapping.view(recording: area)
        })
        RenderWorkload.report("framing: a resize handle", microseconds: RenderWorkload.median(count: 2_000) { step in
            let delta = mapping.delta(view: CGSize(width: Double(step % 5) - 2, height: 1))
            area = ZoomFraming.resized(area, by: delta, handle: .bottomRight)
        })
        RenderWorkload.report("framing: one pointer event", microseconds: RenderWorkload.median(count: 600) { step in
            let delta = mapping.delta(view: CGSize(width: Double(step % 7) - 3, height: 2))
            area = ZoomFraming.moved(area, by: delta)
            _ = mapping.view(recording: area)
            // What the drag actually asks the model for: the description, never the decode.
            _ = builder.descriptor(for: framing, at: at, cursor: track)
        })
    }

    /// Scrubbing, and moving a slider in the inspector — both of which *do* change the
    /// picture, so both pay for a description on every event.
    @Test func scrubbingAndTuning() {
        var timeline = RenderWorkload.timeline()
        let builder = RenderWorkload.builder()
        let track = RenderWorkload.cursorTrack()
        let times = (0..<600).map { RenderWorkload.time(Double($0) / 20) }

        RenderWorkload.report("scrub: one pointer event", microseconds: RenderWorkload.median(count: 600) { step in
            _ = builder.descriptor(for: timeline, at: times[step % times.count], cursor: track)
        })
        RenderWorkload.report("inspector: one slider step", microseconds: RenderWorkload.median(count: 600) { step in
            timeline.zooms[0].scale = 1 + Double(step % 70) * 0.1
            _ = builder.descriptor(for: timeline, at: times[step % times.count], cursor: track)
        })
    }
}
