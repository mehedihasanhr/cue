import CoreGraphics
import CoreMedia
import Foundation
import TimelineKit

/// `studiolab everything <recording.klikrec> <out.mp4>` — one of every feature at once.
///
/// Each feature was built and tested alone; this is the check that they work together in
/// one edit and one export: clips that are titles and freeze frames with transitions
/// between them, every annotation kind, every mask, captions, the pointer's styles and
/// effects, a window frame on a custom gradient, and the camera's motion — then the
/// ordinary export check on the result.
enum KitchenSink {
    static func apply(to timeline: inout Timeline) {
        func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        let length = timeline.duration.seconds

        // The look.
        timeline.style.background = .customGradient(BackgroundGradient())
        timeline.style.chrome = WindowChrome(kind: .browser, appearance: .dark)
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0.6
        timeline.camera.glidesBetweenZooms = true
        timeline.camera.keepsZoomedInFor = 4
        timeline.camera.motionBlur = true
        timeline.cursor.appearance = .dot
        timeline.cursor.spotlight.isEnabled = true
        timeline.cursor.clickSound = true

        // Clips: a title first, a freeze a third of the way in, and transitions.
        _ = Commands.FreezeFrame(at: t(length / 3)).apply(to: &timeline)
        _ = Commands.AddTitle(at: .zero).apply(to: &timeline)
        ClipSequence.split(&timeline, at: t(length * 0.7))
        let styles: [ClipTransition.Style] = [.crossfade, .dipToBlack, .dipToBackground]
        for (index, clip) in timeline.clips.enumerated().dropFirst() {
            _ = Commands.SetTransition(clipID: clip.id, ClipTransition(styles[index % styles.count]))
                .apply(to: &timeline)
        }

        // Words and marks on the picture.
        let every: [AnnotationItem.Kind] = [
            .text("Every feature"), .callout("A callout", tail: CGPoint(x: 0.5, y: 1.6)),
            .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1, y: 1)),
            .line(from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0)),
            .rectangle, .ellipse, .highlight, .step(1),
        ]
        for (index, kind) in every.enumerated() {
            let column = Double(index % 4), row = Double(index / 4)
            _ = Commands.AddAnnotation(AnnotationItem(start: t(2 + Double(index)), duration: t(6), kind: kind,
                                                      rect: CGRect(x: 0.05 + column * 0.23, y: 0.1 + row * 0.4,
                                                                   width: 0.18, height: 0.12)),
                                       name: "Add").apply(to: &timeline)
        }
        let masks: [BlurRegion.Style] = BlurRegion.Style.allCases
        for (index, style) in masks.enumerated() {
            timeline.blurs.append(BlurRegion(start: t(4 + Double(index) * 3), duration: t(3),
                                             rect: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.2), style: style))
        }
        timeline.captions = stride(from: 1.0, to: length - 1, by: 3).map {
            CaptionCue(start: t($0), duration: t(2.5), text: "Caption at \(Int($0)) seconds")
        }
        timeline.captionStyle.isVisible = true
        timeline.cameraLayouts = [CameraLayoutRegion(start: t(5), duration: t(4), layout: .sideBySide)]
        print("everything: \(timeline.clips.count) clips, \(timeline.annotations.count) annotations, "
              + "\(timeline.blurs.count) masks, \(timeline.captions.count) captions")
    }
}
