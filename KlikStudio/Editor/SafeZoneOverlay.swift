import Foundation
import Observation
import SwiftUI
import TimelineKit

/// Whether the preview shows where a vertical-video app's own buttons will cover the
/// picture, and for which app.
///
/// The editor's preference rather than the project's: it changes nothing about the video,
/// and whoever makes Shorts wants the guides on every project, not re-enabled in each one.
@MainActor
@Observable
final class SafeZonePreference {
    static let shared = SafeZonePreference()

    private enum Key {
        static let shown = "preview.safeZones.shown"
        static let platform = "preview.safeZones.platform"
    }

    var isShown: Bool {
        didSet { UserDefaults.standard.set(isShown, forKey: Key.shown) }
    }

    var platform: SafeZonePlatform {
        didSet { UserDefaults.standard.set(platform.rawValue, forKey: Key.platform) }
    }

    private init() {
        let defaults = UserDefaults.standard
        isShown = defaults.bool(forKey: Key.shown)
        platform = defaults.string(forKey: Key.platform).flatMap(SafeZonePlatform.init) ?? .tikTok
    }
}

/// The areas an app covers, drawn over the preview.
///
/// A SwiftUI layer over the picture rather than a layer in the scene, so it can never be
/// exported: the renderer does not know it exists.
struct SafeZoneOverlay: View {
    let model: EditorModel
    /// Where the finished frame is drawn in the pane.
    let stage: CGRect

    private var preference: SafeZonePreference { .shared }

    var body: some View {
        if SafeZonePlatform.applies(to: model.previewSize) {
            ZStack(alignment: .topLeading) {
                ForEach(preference.platform.covered, id: \.label) { area in
                    let rect = frame(area.rect)
                    ZStack {
                        Rectangle().fill(Color.red.opacity(0.22))
                        Rectangle().strokeBorder(Color.white.opacity(0.85),
                                                 style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        Text(area.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.7), radius: 1.5)
                            .multilineTextAlignment(.center)
                            .padding(3)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                }
                Text("\(preference.platform.title) safe zones · preview only")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .position(x: stage.midX, y: stage.minY + stage.height * preference.platform.clear.minY + 14)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            Text("Safe zones are for 9 : 16 frames. Choose 9 : 16 under Shape in the Frame tool to see them.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .position(x: stage.midX, y: stage.maxY + 16)
                .allowsHitTesting(false)
        }
    }

    /// A fraction of the finished frame, top-left origin, in the pane's points.
    private func frame(_ rect: CGRect) -> CGRect {
        CGRect(x: stage.minX + rect.minX * stage.width,
               y: stage.minY + rect.minY * stage.height,
               width: rect.width * stage.width,
               height: rect.height * stage.height)
    }
}
