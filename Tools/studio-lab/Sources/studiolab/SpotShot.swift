import CoreImage
import CoreMedia
import Foundation
import ImageIO
import RecordKit
import RenderKit
import TimelineKit
import UniformTypeIdentifiers

/// `studiolab spotshot <recording.klikrec> <second> <out.png>` — one frame of a recording
/// with the pointer spotlight on, written out, and the brightness across its edge printed.
@MainActor
enum SpotShot {
    static func run(_ arguments: [String]) async -> Int32 {
        guard arguments.count >= 3, let at = Double(arguments[1]) else {
            print("usage: studiolab spotshot <recording.klikrec> <second> <out.png>")
            return 2
        }
        let package = RecordingPackage(url: URL(fileURLWithPath: arguments[0]))
        guard let document = try? EditorDocument(package: package) else { print("could not open"); return 1 }
        var timeline = document.timeline
        timeline.cursor.spotlight = PointerSpotlight(isEnabled: true, radius: 0.2, dimming: 0.8)
        let size = document.manifest.track(.screen)?.pixelSize ?? CGSize(width: 1_920, height: 1_080)
        let builder = SceneBuilder(videoSize: size, displayScale: document.manifest.displayScale,
                                   packageURL: package.url, cursorArtwork: document.cursorArtwork,
                                   picture: document.pictureTrack)
        let scene = builder.descriptor(for: timeline, at: CMTime(seconds: at, preferredTimescale: 600),
                                       cursor: document.cursorTrack.smoothed(timeline.cursor.smoothing))
            .scaled(by: 0.5)
        let frames = try? await FrameSource(url: package.url.appendingPathComponent("media/screen.mov"))
        guard let source = await frames?.frame(at: scene.sourceTime),
              let image = SceneRenderer().cgImage(for: scene, source: source) else { print("no frame"); return 1 }
        let url = URL(fileURLWithPath: arguments[2])
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return 1 }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("wrote \(url.path), spotlight at \(scene.pointerSpotlight.map { "\($0.center)" } ?? "none")")
        return 0
    }
}
