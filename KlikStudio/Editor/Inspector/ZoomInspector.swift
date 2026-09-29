import CoreMedia
import SwiftUI
import TimelineKit

/// Everything about the selected zoom, with the six things people actually change in front
/// and the rest behind one disclosure.
///
/// The panel used to be a single column of fourteen controls — scale, ramp, easing, follow,
/// two timing rows, two placement buttons, provenance, a lock, split, merge, aim, reset,
/// then three camera sliders under a second heading — with no ordering to it beyond the
/// sequence they were written in. Most of a session touches four of those, and hunting for
/// Scale in a list that long is the kind of friction that makes people stop adjusting zooms
/// at all.
///
/// So: **Scale, Duration, Smoothness, Follow, on/off, Reset framing**, and an Advanced
/// section holding the ones that answer a question you had to already have. A disclosure
/// rather than tabs, because tabs are a second navigation system inside a panel that is
/// already reached by selecting something — and because an expandable section leaves the
/// common case as one uninterrupted column.
///
/// Framing itself is not in here at all. It is a rectangle on the picture, because that is
/// what it is — see `ZoomFramingOverlay`. What this panel owes that box is agreement in both
/// directions: the Scale slider writes the same `scale` the box's width stands for, so
/// dragging either moves the other with no third copy of the number in between.
struct ZoomInspector: View {
    let model: EditorModel
    let index: Int

    /// Kept on the model rather than here, so opening Advanced for one zoom and clicking
    /// the next chip does not fold it shut again. It is a way of looking, not a property of
    /// the zoom.
    private var isAdvancedOpen: Binding<Bool> {
        Binding { model.isZoomAdvancedOpen } set: { model.isZoomAdvancedOpen = $0 }
    }

    private var zoom: ZoomRegion? {
        model.timeline.zooms.indices.contains(index) ? model.timeline.zooms[index] : nil
    }

    var body: some View {
        if let zoom {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                basics(zoom)
                Divider()
                advanced(zoom)
            }
            .inspectorSection("Zoom", systemImage: "plus.magnifyingglass")
        }
    }

    // MARK: - The six

    @ViewBuilder
    private func basics(_ zoom: ZoomRegion) -> some View {
        // First, because it decides whether anything below it is doing anything. Switching
        // a zoom off keeps its framing and its place on the lane, which is what makes a run
        // of suggestions something you can audition rather than something you have to
        // accept or destroy.
        Toggle(model.hasMultipleSelected ? "Zooms on" : "Zoom on", isOn: Binding(
            get: { zoom.isEnabled },
            set: { model.setZoomsEnabled($0) }
        ))
        .help("Keeps its framing and its timing, and takes it out of the picture")

        InspectorSlider(model: model, "Scale", systemImage: "plus.magnifyingglass",
                        value: scale, range: 1...ZoomRegion.maximumScale,
                        format: { String(format: "%.1f×", $0) })

        InspectorSlider(model: model, "Duration", systemImage: "ruler",
                        value: duration(zoom), range: 0.3...12,
                        format: { String(format: "%.1fs", $0) })

        // "Smoothness" rather than "Ramp": the thing being set is how gently the camera
        // arrives, and a ramp is the mechanism rather than the effect. The number stays in
        // seconds because that is what it is, and because it has to be readable against the
        // duration above it.
        InspectorSlider(model: model, "Smoothness", systemImage: "timelapse",
                        value: smoothness(zoom), range: 0...2,
                        format: { String(format: "%.2fs", $0) })

        Toggle("Follow the pointer", isOn: Binding(
            get: { zoom.followsCursor },
            set: { follows in change("Follow Cursor") { $0.zooms[index].followsCursor = follows } }
        ))
        .help("The camera tracks the pointer while this zoom holds. Framing it by hand turns this off.")

        HStack(spacing: 6) {
            Button("Frame on the Picture") { model.frameSelectedZoom() }
                .help("Show the whole recording with this zoom's framing box on it")
            Button("Reset Framing") { model.resetZoomFraming() }
                .help("Back to the middle of the picture at \(ZoomRegion.defaultScale, format: .number.precision(.fractionLength(0...1)))×, following the pointer again")
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    // MARK: - The rest

    @ViewBuilder
    private func advanced(_ zoom: ZoomRegion) -> some View {
        DisclosureGroup(isExpanded: isAdvancedOpen) {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                InspectorField(title: "Easing") {
                    InspectorPicker(selection: Binding(
                        get: { zoom.easing },
                        set: { easing in change("Zoom Easing") { $0.zooms[index].easing = easing } }
                    ), options: Easing.allCases) { $0.rawValue.capitalized }
                }

                // Placed and timed here as well as by dragging the chip. A zoom that should
                // begin a quarter-second earlier is a correction you make after watching it,
                // and hunting for a few pixels on a zoomed-out timeline is the wrong way to
                // ask for it.
                timing(title: "Starts", value: Timecode.short(zoom.start)) { delta in
                    model.nudgeZoom(zoom.id, start: delta)
                }
                HStack(spacing: 6) {
                    Button("Start Here") { model.moveZoom(zoom.id, toStartAt: model.playhead) }
                        .help("Begin this zoom at the playhead, keeping its length")
                    Button("End Here") { model.moveZoom(zoom.id, toEndAt: model.playhead) }
                        .help("End this zoom at the playhead, keeping where it starts")
                    Spacer(minLength: 0)
                }
                .controlSize(.small)

                provenance(zoom)

                Divider()
                verbs(zoom)

                Divider()
                // How the camera moves, under the zoom whose movement it governs. One set
                // of values for the whole project, said so in the section's own caption —
                // it is here because this is where somebody notices the movement is wrong.
                CameraControls(model: model, isFollowing: zoom.followsCursor)
            }
            .padding(.top, SidebarSpacing.betweenControls)
        } label: {
            Text("Advanced")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .disclosureGroupStyle(.automatic)
        .accessibilityHint("Easing, timing, splitting, locking and camera motion")
    }

    /// Why this zoom is here, and whether it will survive the next auto-zoom run.
    ///
    /// A suggestion somebody can see the reason for is one they adjust; one that appeared
    /// from nowhere is one they delete. The second line matters more than it looks: the
    /// rule it describes — that framing a suggestion by hand makes it yours — is invisible
    /// otherwise, and the failure it prevents is a run silently undoing somebody's work.
    @ViewBuilder
    private func provenance(_ zoom: ZoomRegion) -> some View {
        if let source = zoom.source, source != .manual {
            InspectorRow(title: "Suggested by", value: source.title)
                .foregroundStyle(.secondary)
            if zoom.isEdited {
                Label("Framed by you — auto-zoom will leave it alone.", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The things that change how many zooms there are, and which ones may be touched.
    ///
    /// Each one says why it is off when it is off, in the help text rather than in a dialog.
    /// A disabled button with no explanation is the single most common way an editor makes
    /// someone feel they have done something wrong.
    @ViewBuilder
    private func verbs(_ zoom: ZoomRegion) -> some View {
        Toggle("Lock it", isOn: Binding(
            get: { zoom.isLocked },
            set: { _ in model.toggleZoomLock() }
        ))
        .help("A locked zoom cannot be dragged or resized on the timeline, and the next auto-zoom run leaves it alone. You can still change it here, and still delete it.")

        // One ramp at one end and nothing at the other: this is half of a split, and saying
        // so is what stops the Smoothness slider above looking broken.
        if zoom.ramps.in != zoom.ramps.out {
            Label(zoom.ramps.in == .zero
                  ? "Cut from the zoom before it — no ramp at its start."
                  : "Cut from the zoom after it — no ramp at its end.",
                  systemImage: "scissors")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 6) {
            Button("Split at Playhead") { model.splitZoomAtPlayhead() }
                .disabled(!model.canSplitZoom)
                .help(model.canSplitZoom
                      ? "Cut this zoom in two at the playhead, so the halves can be aimed apart. The picture does not move at the cut."
                      : "Move the playhead further inside this zoom — a split too near either end would leave a chip too small to grab.")
            Button("Merge with Next") { model.mergeZoomWithNext() }
                .disabled(model.zoomToMergeInto == nil)
                .help(model.zoomToMergeInto == nil
                      ? "There is no zoom after this one to merge it with."
                      : "Join this zoom and the one after it into a single push-in, keeping the ramp at each outer end.")
        }
        .controlSize(.small)

        HStack(spacing: 6) {
            Button("Reset Scale & Ramp") { model.resetZoom() }
                .help("Scale, ramp and easing back to what a new zoom has. Where it points is left alone.")
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    /// A zoom's start, with a pair of nudges beside it.
    private func timing(title: String, value: String,
                        _ nudge: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .monospacedDigit()
            Spacer(minLength: 4)
            Button { nudge(-0.1) } label: {
                Image(systemName: "minus").font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 16)
            }
            .buttonStyle(.bordered).controlSize(.mini)
            .accessibilityLabel("\(title) a tenth of a second earlier")
            Button { nudge(0.1) } label: {
                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 16)
            }
            .buttonStyle(.bordered).controlSize(.mini)
            .accessibilityLabel("\(title) a tenth of a second later")
        }
    }

    // MARK: - Bindings

    /// The magnification, which is also the framing box's width read the other way round.
    private var scale: Binding<Double> {
        Binding {
            model.timeline.zooms.indices.contains(index) ? model.timeline.zooms[index].scale : 1
        } set: { value in
            model.apply(Commands.Restyle("Zoom Scale") { timeline in
                guard timeline.zooms.indices.contains(index) else { return }
                timeline.zooms[index].scale = value
            })
        }
    }

    /// How long the zoom holds, in seconds.
    ///
    /// Through `MoveRegion` — the command a drag on the lane uses — so the slider and the
    /// chip cannot end up meaning different things, and so the lane's clamping applies to
    /// both.
    private func duration(_ zoom: ZoomRegion) -> Binding<Double> {
        Binding {
            model.timeline.zooms.indices.contains(index)
                ? model.timeline.zooms[index].duration.seconds : 0
        } set: { seconds in
            model.apply(Commands.MoveRegion(id: zoom.id, start: zoom.start,
                                            duration: max(Clip.minimumDuration,
                                                          CMTime(seconds: seconds, preferredTimescale: 600))))
        }
    }

    private func smoothness(_ zoom: ZoomRegion) -> Binding<Double> {
        Binding {
            model.timeline.zooms.indices.contains(index)
                ? model.timeline.zooms[index].transition.seconds : 0
        } set: { seconds in
            change("Zoom Smoothness") {
                $0.zooms[index].transition = CMTime(seconds: seconds, preferredTimescale: 600)
            }
        }
    }

    private func change(_ name: String, _ mutate: @escaping @Sendable (inout Timeline) -> Void) {
        model.apply(Commands.Restyle(name, mutate))
    }
}
