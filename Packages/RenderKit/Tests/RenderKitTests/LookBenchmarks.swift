import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// What a turned picture, a colour grade and a moving background cost per 1080p frame.
///
///     CUE_BENCH=1 swift test --filter LookBenchmarks
///
/// Each is measured against the same frame without it, rendered into a pixel buffer the
/// way the preview and the exporter render, from a real picture rather than a flat colour
/// Core Image could fold away.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CUE_BENCH"] != nil,
                "set CUE_BENCH=1 to measure"),
       .serialized,
       .timeLimit(.minutes(5)))
struct LookBenchmarks {
    private let size = CGSize(width: 1_920, height: 1_080)

    private func source() throws -> CIImage {
        let page = CIImage(cgImage: FollowingFootage.page(height: 1_080, seed: 3))
            .transformed(by: CGAffineTransform(scaleX: 1_920 / FollowingFootage.size.width, y: 1))
        let flattened = try #require(CIContext().createCGImage(page, from: CGRect(origin: .zero, size: size)))
        return CIImage(cgImage: flattened)
    }

    private func buffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1_920, 1_080, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &buffer)
        return try #require(buffer)
    }

    private func measure(_ name: String, _ change: (inout Timeline) -> Void) throws {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 60, preferredTimescale: 600))
        timeline.style.chrome = WindowChrome(kind: .window)
        change(&timeline)
        let builder = SceneBuilder(videoSize: size)
        let renderer = SceneRenderer()
        let source = try source()
        let buffer = try buffer()
        let each = RenderWorkload.median(count: 60, warmup: 5) { index in
            let scene = builder.descriptor(for: timeline, at: CMTime(seconds: Double(index) / 30, preferredTimescale: 600))
            renderer.render(scene, source: source, to: buffer)
            // Wait for the GPU, so the number is the frame and not the call.
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        RenderWorkload.report("1080p, \(name)", microseconds: each)
    }

    @Test func costs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bench-looks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cube = folder.appendingPathComponent("invert.cube")
        try ColorGradeRenderTests.invertingCube(size: 33).write(to: cube, atomically: true, encoding: .utf8)

        try measure("plain frame") { _ in }
        try measure("tilted (Isometric)") { $0.style.perspective = FramePerspective().with(.isometric) }
        try measure("tilted, with annotations over it") {
            $0.style.perspective = FramePerspective().with(.tiltLeft)
            $0.annotations = (0..<3).map { index in
                AnnotationItem(start: .zero, duration: CMTime(seconds: 60, preferredTimescale: 600),
                               kind: .rectangle,
                               rect: CGRect(x: 0.2 + Double(index) * 0.2, y: 0.3, width: 0.1, height: 0.1))
            }
        }
        try measure("colour: brightness, contrast, saturation") {
            $0.style.grade = ColorGrade(brightness: 0.1, contrast: 0.2, saturation: 0.3)
        }
        try measure("colour: warm (with temperature)") { $0.style.grade = ColorGrade().with(.warm) }
        try measure("colour: 33³ LUT") {
            $0.style.grade = ColorGrade(lut: LUTReference(path: cube.path, name: "invert"), lutIntensity: 0.7)
        }
        for kind in AnimatedBackground.Kind.allCases {
            try measure("background: \(kind.title)") { $0.style.background = .animated(AnimatedBackground(kind: kind)) }
        }
        try measure("background: Aurora, blurred") {
            $0.style.background = .animated(AnimatedBackground(kind: .aurora))
            $0.style.backgroundBlur = 0.02
        }
        try measure("everything") {
            $0.style.perspective = FramePerspective().with(.isometric)
            $0.style.grade = ColorGrade(lut: LUTReference(path: cube.path, name: "invert")).with(.vivid)
            $0.style.background = .animated(AnimatedBackground(kind: .aurora))
        }

        let movie = folder.appendingPathComponent("loop.mov")
        try writeMovie(to: movie)
        try measure("background: 720p movie, decoded per frame") { $0.style.background = .video(path: movie.path) }
    }

    /// Two seconds of 720p to loop behind the picture.
    private func writeMovie(to url: URL) throws {
        let done = DispatchSemaphore(value: 0)
        let footage = FollowingFootage(frames: 60) { index in
            (draw: { context in
                context.setFillColor(CGColor(srgbRed: Double(index) / 60, green: 0.3, blue: 0.5, alpha: 1))
                context.fill(CGRect(origin: .zero, size: FollowingFootage.size))
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fillEllipse(in: CGRect(x: Double(index) * 15, y: 200, width: 200, height: 200))
            }, truth: .zero)
        }
        Task.detached {
            try? await footage.write(to: url)
            done.signal()
        }
        done.wait()
    }
}
