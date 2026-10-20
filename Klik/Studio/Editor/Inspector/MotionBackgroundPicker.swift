import BackgroundKit
import SwiftUI
import TimelineKit

/// A background that moves: three drawn ones, each in any of the gradient palettes and at
/// any pace, or a movie of one's own on a loop.
struct MotionBackgroundPicker: View {
    let model: EditorModel

    /// The kinds, and the movie beside them.
    private enum Kind: String, CaseIterable, Identifiable, Hashable {
        case drift, aurora, grain, video
        var id: String { rawValue }

        var title: String {
            switch self {
            case .drift: "Drift"
            case .aurora: "Aurora"
            case .grain: "Grain"
            case .video: "Video"
            }
        }

        var animation: AnimatedBackground.Kind? {
            switch self {
            case .drift: .drift
            case .aurora: .aurora
            case .grain: .grain
            case .video: nil
            }
        }
    }

    @State private var showsVideo = false

    private var background: FrameStyle.Background { model.timeline.style.background }
    private var animation: AnimatedBackground { background.editableAnimation }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenGroups) {
            InspectorTabs(selection: kind, items: Kind.allCases) { $0.title }
                .accessibilityLabel("Moving background")
            if kind.wrappedValue == .video {
                video
            } else {
                palettes
                InspectorSlider(model: model, "Speed", systemImage: "gauge.with.dots.needle.33percent",
                                value: Binding(get: { animation.speed },
                                               set: { speed in
                                                   var changed = animation
                                                   changed.speed = speed
                                                   model.setAnimatedBackground(changed)
                                               }),
                                range: AnimatedBackground.speedRange,
                                format: { String(format: "%.2g×", $0) })
                    .help("It moves while the video plays, and is the same on every frame of the export as in the preview.")
            }
        }
    }

    private var kind: Binding<Kind> {
        Binding {
            if showsVideo || model.hasVideoBackground { return .video }
            switch animation.kind {
            case .drift: return .drift
            case .aurora: return .aurora
            case .grain: return .grain
            }
        } set: { chosen in
            showsVideo = chosen == .video
            guard let kind = chosen.animation else { return }
            var changed = animation
            changed.kind = kind
            model.setAnimatedBackground(changed)
        }
    }

    // MARK: - Palettes

    private var palettes: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 21, maximum: 22), spacing: 6)],
                  alignment: .leading,
                  spacing: 6) {
            ForEach(GradientPreset.allCases) { preset in
                let colours = preset.colors.map(\.colorValue)
                SwatchTile(isSelected: model.hasMovingBackground && animation.colors == colours,
                           title: preset.title) {
                    var changed = animation
                    changed.colors = colours
                    model.setAnimatedBackground(changed)
                } content: {
                    LinearGradient(colors: colours.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
    }

    // MARK: - Video

    @ViewBuilder
    private var video: some View {
        Group {
            if model.hasVideoBackground {
                HStack(spacing: 8) {
                    Button("Replace…") { model.chooseBackgroundVideo() }
                    Button("Remove") {
                        showsVideo = false
                        model.setAnimatedBackground(AnimatedBackground())
                    }
                }
                .buttonStyle(.studio(.secondary, size: .small))
            } else {
                Button("Choose Video…") { model.chooseBackgroundVideo() }
                    .buttonStyle(.studio(.secondary, size: .small))
            }
        }
        .help("The movie is copied into the recording and loops for as long as the video runs. Its sound is not used.")
    }
}
