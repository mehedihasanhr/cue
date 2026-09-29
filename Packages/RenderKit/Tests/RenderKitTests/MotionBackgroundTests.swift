import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// Backgrounds that move are a function of the moment and nothing else.
///
/// Drawn twice at the same moment by two renderers they are the same picture; drawn at two
/// moments they are not; and a movie behind the picture shows the frame of itself that
/// the moment, looped, lands on — whichever order the moments are asked for in.
struct MotionBackgroundTests {
    private let size = CGSize(width: 480, height: 270)

    private func pixels(_ layer: BackgroundLayer, renderer: SceneRenderer = SceneRenderer()) throws -> DressingPixels {
        let scene = SceneDescriptor(outputSize: size, background: layer,
                                    videoFrame: CGRect(x: 0, y: 0, width: 1, height: 1))
        return DressingPixels(try #require(renderer.cgImage(for: scene, source: nil)))
    }

    private func animated(_ kind: AnimatedBackground.Kind, at time: Double, speed: Double = 1) -> BackgroundLayer {
        .animated(AnimatedBackgroundLayer(kind: kind, colors: AnimatedBackground.defaultColors, speed: speed, time: time))
    }

    /// The largest difference in any channel of any pixel, sampled on a grid.
    private func difference(_ a: DressingPixels, _ b: DressingPixels) -> Double {
        var largest = 0.0
        for y in stride(from: 3, to: a.height, by: 17) {
            for x in stride(from: 3, to: a.width, by: 17) {
                largest = max(largest, DressingPixels.distance(a.colour(x, y), b.colour(x, y)))
            }
        }
        return largest
    }

    @Test(arguments: AnimatedBackground.Kind.allCases)
    func theSameMomentIsTheSamePicture(_ kind: AnimatedBackground.Kind) throws {
        let first = try pixels(animated(kind, at: 4.2))
        let again = try pixels(animated(kind, at: 4.2))
        #expect(difference(first, again) == 0)
    }

    @Test(arguments: AnimatedBackground.Kind.allCases)
    func itMoves(_ kind: AnimatedBackground.Kind) throws {
        let now = try pixels(animated(kind, at: 1))
        let later = try pixels(animated(kind, at: 4))
        #expect(difference(now, later) > 0.02, "\(kind) did not move")
    }

    /// Twice the speed is the same pictures in half the time.
    @Test(arguments: AnimatedBackground.Kind.allCases)
    func speedScalesTime(_ kind: AnimatedBackground.Kind) throws {
        let fast = try pixels(animated(kind, at: 3, speed: 2))
        let slow = try pixels(animated(kind, at: 6, speed: 1))
        #expect(difference(fast, slow) == 0)
    }

    /// Slowly: a thirtieth of a second changes the picture by very little, so nothing
    /// flickers — except the grain, which is meant to.
    @Test(arguments: [AnimatedBackground.Kind.drift, .aurora])
    func itMovesSlowly(_ kind: AnimatedBackground.Kind) throws {
        let now = try pixels(animated(kind, at: 2))
        let next = try pixels(animated(kind, at: 2 + 1.0 / 30))
        #expect(difference(now, next) < 0.02)
    }

    /// Grain changes with the film frame, twenty-four times a second, and holds between.
    @Test func grainHoldsForAFilmFrame() throws {
        let a = try pixels(animated(.grain, at: 2.001))
        let b = try pixels(animated(.grain, at: 2.03))
        let c = try pixels(animated(.grain, at: 2.05))
        // The same film frame: only the ground under it has moved, by less than a step.
        #expect(difference(a, b) < 0.01, "the same film frame")
        #expect(difference(a, c) > 0.03, "the next one")
        // And subtle: the grain moves a pixel by a few percent, not by half.
        #expect(difference(a, c) < 0.2)
    }

    // MARK: - The description

    @Test func theBuilderStampsTheMoment() throws {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.style.background = .animated(AnimatedBackground(kind: .aurora, speed: 1.5))
        let builder = SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000))
        let scene = builder.descriptor(for: timeline, at: CMTime(seconds: 3.5, preferredTimescale: 600))
        guard case .animated(let layer) = scene.background else {
            Issue.record("not a moving background: \(scene.background)")
            return
        }
        #expect(layer.time == 3.5)
        #expect(layer.speed == 1.5)
        #expect(layer.kind == .aurora)
        // The preview's smaller frame is the same moment.
        #expect(scene.scaled(by: 0.5).background == scene.background)
    }

    @Test func aStillBackgroundIsNotStamped() {
        let timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        let builder = SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000))
        let early = builder.descriptor(for: timeline, at: CMTime(seconds: 1, preferredTimescale: 600))
        let late = builder.descriptor(for: timeline, at: CMTime(seconds: 7, preferredTimescale: 600))
        #expect(early.background == late.background)
    }

    @Test func oldProjectsDecodeWithoutTheNewFields() throws {
        let json = #"{ "padding": 0.1, "background": { "color": { "_0": { "r": 1, "g": 0, "b": 0, "a": 1 } } } }"#
        let style = try JSONDecoder().decode(FrameStyle.self, from: Data(json.utf8))
        #expect(style.padding == 0.1)
        #expect(style.perspective == FramePerspective())
        #expect(style.grade == ColorGrade())
    }

    @Test func movingBackgroundsRoundTrip() throws {
        var style = FrameStyle()
        style.background = .animated(AnimatedBackground(kind: .grain, colors: [.white, .black], speed: 2))
        let decoded = try JSONDecoder().decode(FrameStyle.self, from: JSONEncoder().encode(style))
        #expect(decoded.background == style.background)
        style.background = .video(path: "Backgrounds/loop.mov")
        #expect(try JSONDecoder().decode(FrameStyle.self, from: JSONEncoder().encode(style)).background == style.background)
    }

    // MARK: - A movie

    /// A third of a second of footage whose every frame is a different shade of red, so
    /// the frame on screen can be read off its colour.
    private static let frames = 10

    private static func shade(_ frame: Int) -> Double { 0.05 + Double(frame) * 0.09 }

    private func movie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loop-\(UUID().uuidString).mov")
        let footage = FollowingFootage(frames: Self.frames) { index in
            (draw: { context in
                context.setFillColor(CGColor(srgbRed: Self.shade(index), green: 0.2, blue: 0.3, alpha: 1))
                context.fill(CGRect(origin: .zero, size: FollowingFootage.size))
            }, truth: .zero)
        }
        try await footage.write(to: url)
        return url
    }

    /// Which frame of the movie a picture shows, read off its red.
    private func frameShown(_ pixels: DressingPixels) -> Int {
        let red = pixels.colour(pixels.width / 2, pixels.height / 2).r
        return Int(((red - 0.05) / 0.09).rounded())
    }

    @Test func aMovieLoopsBehindThePicture() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = SceneRenderer()
        let rate = Double(FollowingFootage.frameRate)
        let length = Double(Self.frames) / rate
        func shown(at seconds: Double) throws -> Int {
            try frameShown(pixels(.video(url: url, time: seconds), renderer: renderer))
        }
        // Played forwards, frame by frame.
        for frame in 0..<Self.frames {
            #expect(try shown(at: (Double(frame) + 0.5) / rate) == frame)
        }
        // Round the end and back to the start, seamlessly.
        #expect(try shown(at: length + 0.5 / rate) == 0)
        #expect(try shown(at: length * 3 + 4.5 / rate) == 4)
        // Scrubbed backwards, and jumped a long way forwards.
        #expect(try shown(at: 2.5 / rate) == 2)
        #expect(try shown(at: length * 40 + 7.5 / rate) == 7)
        // And a second renderer, reading from scratch, agrees.
        #expect(try frameShown(pixels(.video(url: url, time: length * 40 + 7.5 / rate))) == 7)
    }

    /// The preview draws on the main thread, and opening a movie waits for it to load. The
    /// loading must not need the thread it is keeping waiting.
    @MainActor
    @Test func theMainThreadCanOpenAMovie() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = ContinuousClock()
        let started = clock.now
        let shown = try frameShown(pixels(.video(url: url, time: 4.5 / Double(FollowingFootage.frameRate))))
        #expect(shown == 4)
        #expect(clock.now - started < .seconds(2), "opened promptly rather than after the time-out")
    }

    /// The export draws the movie too, looped by the finished video's clock — with the
    /// picture turned and graded in front of it, so all three new things go through the
    /// exporter's own renderer on its own thread.
    @Test func theExportPlaysTheMovie() async throws {
        let background = try await movie()
        defer { try? FileManager.default.removeItem(at: background) }
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        let size = CGSize(width: 320, height: 180)
        try await ExportTests.writeSilentVideo(to: source, size: size, frames: 30, frameRate: 30)

        var edit = Timeline(sourceDuration: DressingFixtures.time(1))
        edit.style.background = .video(path: background.path)
        edit.style.padding = 0.2
        edit.style.shadowOpacity = 0
        edit.style.perspective = FramePerspective().with(.tiltLeft)
        edit.style.grade = ColorGrade(saturation: -1)
        let exporter = VideoExporter(timeline: edit, builder: SceneBuilder(videoSize: size), cursor: nil,
                                     videoURL: source, packageURL: nil, settings: ExportSettings())
        let file = folder.appendingPathComponent("moving.mp4")
        try await exporter.export(to: file)

        // The export's frames 3, 15 and 24 — the movie's 3, 5 and 4 once it has looped. A
        // hair before each, because the reader hands back the first frame at or after it.
        let rate = Double(FollowingFootage.frameRate)
        for (exported, frame) in [(3, 3), (15, 5), (24, 4)] {
            let seconds = Double(exported) / rate - 0.002
            let pixels = try await DressingFixtures.frame(of: file, at: seconds)
            let red = pixels.colour(3, 3).r
            let shown = Int(((red - 0.05) / 0.09).rounded())
            #expect(shown == frame, "at \(seconds)s the movie is on frame \(shown) (red \(red)), not \(frame)")        }
    }

    @Test func aMissingMovieIsTheMissingBackground() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mov")
        let drawn = try pixels(.video(url: missing, time: 1))
        #expect(drawn.isClose(10, 10, to: BackgroundLayer.fallbackColor, within: 0.02))
    }

    @Test func loopingWraps() {
        #expect(BackgroundMovie.looped(2.5, duration: 1) == 0.5)
        #expect(BackgroundMovie.looped(-0.25, duration: 1) == 0.75)
        #expect(BackgroundMovie.looped(3, duration: 0) == 0)
    }
}
