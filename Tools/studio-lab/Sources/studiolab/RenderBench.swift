import CoreImage
import CoreMedia
import Foundation
import RecordKit
import RenderKit
import TimelineKit

/// `studiolab renderbench <recording.klikrec> <zoomed-second> <unzoomed-second>` — how long
/// the renderer takes to draw one preview frame, zoomed and not, and which layer costs what.
/// Uses a flat stand-in for the recorded picture, so decoding is not measured.
@MainActor
enum RenderBench {
    static func run(_ arguments: [String]) async -> Int32 {
        guard arguments.count >= 3, let zoomedAt = Double(arguments[1]), let flatAt = Double(arguments[2]) else {
            print("usage: studiolab renderbench <recording.klikrec> <zoomed-second> <unzoomed-second> [fidelity]")
            return 2
        }
        let package = RecordingPackage(url: URL(fileURLWithPath: arguments[0]))
        guard let document = try? EditorDocument(package: package) else { print("could not open"); return 1 }
        var timeline = document.timeline
        let size = document.manifest.track(.screen)?.pixelSize ?? CGSize(width: 1_920, height: 1_080)
        let points = CGSize(width: size.width / document.manifest.displayScale, height: size.height / document.manifest.displayScale)
        let suggester = ZoomSuggester(frameSize: points, crop: timeline.style.crop?.rect ?? CropRect.full.rect,
                                      picture: document.pictureTrack,
                                      tuning: ZoomSuggester.Tuning(transition: timeline.camera.zoomSpeed.transition))
        _ = Commands.SuggestZooms(timeline.placedOnTimeline(suggester.smartSuggestions(
            cursor: document.cursorTrack.samples, input: document.inputSamples,
            focus: document.focusSamples, duration: timeline.sourceDuration))).apply(to: &timeline)
        let fidelity = arguments.count > 3 ? Double(arguments[3]) ?? 0.5 : 0.5
        let builder = SceneBuilder(videoSize: size, displayScale: document.manifest.displayScale,
                                   packageURL: package.url, cursorArtwork: document.cursorArtwork,
                                   picture: document.pictureTrack)
        let cursor = document.cursorTrack.smoothed(timeline.cursor.smoothing)
        let renderer = SceneRenderer()
        let source = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.92)).cropped(to: CGRect(origin: .zero, size: size))

        func time(_ scene: SceneDescriptor, _ label: String) {
            _ = renderer.cgImage(for: scene, source: source)
            let started = CFAbsoluteTimeGetCurrent()
            let count = 20
            for _ in 0..<count { _ = renderer.cgImage(for: scene, source: source) }
            let ms = (CFAbsoluteTimeGetCurrent() - started) / Double(count) * 1000
            print(String(format: "%-34@ %6.1f ms   (%.0f × %.0f, zoom %.2f)", label as NSString, ms,
                         scene.outputSize.width, scene.outputSize.height, scene.zoom))
        }
        let frames = try? await FrameSource(url: package.url.appendingPathComponent("media/screen.mov"))
        await frames?.setQuality(.preview(size))
        for (name, at) in [("zoomed", zoomedAt), ("not zoomed", flatAt)] {
            let scene = builder.descriptor(for: timeline, at: CMTime(seconds: at, preferredTimescale: 600), cursor: cursor)
                .scaled(by: fidelity)
            time(scene, name)
            print("    frame \(scene.transformedVideoFrame) of \(scene.outputSize), corner \(scene.cornerRadius), follows \(scene.frameFollowsCamera)")
            if let real = await frames?.frame(at: scene.sourceTime) {
                _ = renderer.cgImage(for: scene, source: real)
                let started = CFAbsoluteTimeGetCurrent()
                for _ in 0..<20 { _ = renderer.cgImage(for: scene, source: real) }
                print(String(format: "  %@ with the real picture  %6.1f ms   (picture %.0f × %.0f)", name as NSString,
                             (CFAbsoluteTimeGetCurrent() - started) / 20 * 1000, real.extent.width, real.extent.height))
            }
            var noShadow = scene; noShadow.shadowOpacity = 0
            time(noShadow, "  \(name), no shadow")
            var noCorners = scene; noCorners.cornerRadius = 0
            time(noCorners, "  \(name), no corners")
            var still = scene; still.cameraMotion = nil
            time(still, "  \(name), no motion blur")
        }
        // The same zoomed frame two ways: copied back as a CGImage, as the preview does now,
        // and rendered straight into a GPU-shareable buffer.
        let scene = builder.descriptor(for: timeline, at: CMTime(seconds: zoomedAt, preferredTimescale: 600), cursor: cursor)
            .scaled(by: fidelity)
        let real = await frames?.frame(at: scene.sourceTime) ?? source
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(scene.outputSize.width), Int(scene.outputSize.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                             kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &buffer)
        for (label, work) in [("as a CGImage", { _ = renderer.cgImage(for: scene, source: real) }),
                              ("into a GPU buffer", { renderer.render(scene, source: real, to: buffer!) })] as [(String, () -> Void)] {
            work()
            let started = CFAbsoluteTimeGetCurrent()
            for _ in 0..<20 { work() }
            print(String(format: "zoomed frame %@: %.1f ms", label as NSString, (CFAbsoluteTimeGetCurrent() - started) / 20 * 1000))
        }
        return 0
    }
}
