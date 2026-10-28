import AVFoundation
import SwiftUI
import TimelineKit

/// The frame under the playhead, rendered exactly as it will be exported.
///
/// Also the canvas: a tool that works by direct manipulation — crop today, blur and
/// annotation later — draws its handles here, over the stage rect rather than over the
/// laid-out image.
struct PreviewPane: View {
    let model: EditorModel

    /// Room around the picture. None: the picture fills the pane, with nothing framed
    /// round it — except while cropping, where a handle at the very edge has to stay
    /// grabbable.
    private var inset: CGFloat { model.tool == .crop ? 22 : 0 }
    /// The floating tool bar sits over the picture rather than taking a strip of its own;
    /// it fades away while the edit plays, so it never covers the thing being watched.
    private let toolBarRoom: CGFloat = 0
    /// The pane's corner, which the picture takes when it fills the pane.
    private static let cornerRadius: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // The same surface as the panels and the timeline around it. The stage
                // used to be a grey gradient of its own, which made the middle of the
                // window a third colour competing with the frame standing on it — and
                // the frame carries its own background, which is the thing that is
                // supposed to be judged here.
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(StudioTheme.Surface.canvas)
                    // A click on nothing — the picture, or the space round it — lets go of
                    // the label or mask that was picked, and its frame goes with it. A click
                    // on the label brings it back. Every layout tool does this.
                    .contentShape(Rectangle())
                    .onTapGesture { model.deselectOnCanvas() }

                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
                        // The frame is composed at export size and shown at about a
                        // third of it. Said out loud rather than left to a default,
                        // because this is the scale the rounded corners are judged at.
                        .interpolation(.high)
                        .antialiased(true)
                        // Under the live layer while playing, and hidden so a see-through
                        // background does not show the last still frame through it.
                        .opacity(model.showsLive ? 0 : 1)
                        // Playing frames go straight onto a layer, not through this image:
                        // see `LiveFrameSink`.
                        .overlay { LiveFrameView(sink: model.liveSink).opacity(model.showsLive ? 1 : 0) }
                        // Clicks go through to the stage under it: the picture is looked at,
                        // and a click on it is a click on nothing in particular.
                        .allowsHitTesting(false)
                        .aspectRatio(contentMode: .fit)
                        // Behind the frame, not in it: with a transparent background the
                        // rendered frame really is see-through there — that is what the
                        // export writes — and the squares are how the stage says so.
                        .background {
                            if model.hasTransparentBackground {
                                Checkerboard()
                            }
                        }
                        // Flat on the pane: no lift, no shadow, no corner of its own — the
                        // picture is the canvas, not a card laid on one.
                        .clipShape(RoundedRectangle(cornerRadius: inset == 0 ? Self.cornerRadius : 0, style: .continuous))
                        .padding(.horizontal, inset)
                        .padding(.top, inset)
                        .padding(.bottom, toolBarRoom)
                        .transition(.opacity)
                } else {
                    ProgressView().controlSize(.large)
                }

                switch model.tool {
                case .crop:
                    CropOverlay(model: model, stage: stage(in: proxy.size))
                case .blur, .annotate:
                    RegionCanvas(model: model, stage: stage(in: proxy.size))
                case .webcam:
                    // Drawn over the preview without being an `isCanvasTool`: that flag says
                    // the tool's *inspector* is a selection rather than settings, and the
                    // webcam panel is settings. What it needs here is a handle on the picture.
                    WebcamBubbleOverlay(model: model, stage: stage(in: proxy.size))
                default:
                    // The labels on the picture can be picked up whatever tool is chosen, the
                    // way every layout tool's selection arrow moves any layer: selecting one
                    // and then finding it would not move until the Annotate tool was chosen
                    // read as a broken drag. Nothing new is drawn from here — see `drawsNew`.
                    if !model.annotationsAtPlayhead.isEmpty {
                        RegionCanvas(model: model, stage: stage(in: proxy.size), drawsNew: false)
                    }
                    // Not a tool, and no mode to enter: selecting a zoom on the timeline is
                    // already an unambiguous statement about which zoom you mean, so its
                    // framing box is simply here. See `EditorModel.framedZoom`.
                    if model.isFramingZoom {
                        ZoomFramingOverlay(model: model, stage: stage(in: proxy.size))
                        ZoomFramingHint(model: model,
                                        bottom: toolBarBottom(in: proxy.size) + CanvasToolBar.height + 8)
                    }
                }

                // Where a vertical-video app's buttons will sit. Over the picture and never in
                // it: see `SafeZoneOverlay`.
                if SafeZonePreference.shared.isShown, model.preview != nil {
                    SafeZoneOverlay(model: model, stage: stage(in: proxy.size))
                }

                // The one control that says which question this surface is answering. It
                // sits on the picture rather than in the inspector because it is about the
                // picture, and it is the last thing in the stack so the framing handles
                // never end up underneath it.
                // Inside the picture, a little above its bottom edge, rather than across it.
                CanvasToolBar(model: model)
                    .padding(.bottom, toolBarBottom(in: proxy.size))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            // How big the picture is allowed to be, told to the thing that renders it.
            //
            // While playing, the model composites at the pane's size rather than at the
            // project's: a 4K frame filling a pane this size is seven eighths of its pixels
            // thrown away by the window server. Reported from here because this is the only
            // place that knows the answer, and reported as the *stage* rather than the whole
            // pane so the inset and the aspect fit are already accounted for.
            //
            // `onChange` rather than `onGeometryChange`, which wants macOS 15 and this app
            // ships to 14 — and there is no need for it here, since the enclosing
            // `GeometryReader` has already measured the pane. `initial: true` so the first
            // playback after a window opens is not rendered against a pane size of zero.
            .onChange(of: stage(in: proxy.size).size, initial: true) { _, size in
                model.previewPaneResized(to: size)
            }
        }
    }

    /// How far above the pane's bottom edge the canvas bar sits: inside the picture, a
    /// little above its bottom edge.
    private func toolBarBottom(in size: CGSize) -> CGFloat {
        max(9, size.height - stage(in: size).maxY + 14)
    }

    /// Where the picture actually lands.
    ///
    /// Computed from the aspect ratio rather than measured off the laid-out `Image`,
    /// because the overlay's arithmetic has to be exact and because `NSImage` is being
    /// given a pixel size as a point size — true enough for `.resizable()`, which only
    /// needs the ratio, but not something to build a coordinate mapping on.
    private func stage(in size: CGSize) -> CGRect {
        let available = CGRect(x: inset, y: inset,
                               width: size.width - inset * 2,
                               height: size.height - inset - toolBarRoom)
        guard available.width > 0, available.height > 0 else { return available }
        let ratio = model.previewSize
        guard ratio.width > 0, ratio.height > 0 else { return available }
        return AVMakeRect(aspectRatio: ratio, insideRect: available)
    }
}

/// The bar floating under the picture: what you can do to the picture *now*.
///
/// It changes with the job in hand rather than listing every tool all the time:
/// - **Nothing in particular** — the four tools that work on the picture, and Add.
/// - **Cropping** — reset the crop, and Done.
/// - **Masking** — which kind the next drag draws, Add one in the middle, and Done.
/// - **Annotating** — one press for each common kind, and Done.
/// - **Framing a zoom** — whether the picture shows the framing box or the result, and
///   Done to put the zoom down.
///
/// It steps out of the way while the edit plays: a bar of tools over a picture you are
/// watching is something in front of the picture.
struct CanvasToolBar: View {
    let model: EditorModel
    /// How tall the bar is: a row of 28-point controls in a 3-point frame.
    static let height: CGFloat = 34
    @State private var isAdding = false
    /// Whether the bar of shapes is open above the Annotate bar.
    @State private var showsShapes = false
    /// The shape the shapes button shows: the one last chosen, so drawing the same kind
    /// again is one click.
    @State private var lastShape: EditorModel.NewAnnotation = .box

    private enum Mode: Equatable { case tools, crop, mask, annotate, zoom }

    private var mode: Mode {
        if model.canChooseZoomPreview { return .zoom }
        switch model.tool {
        case .crop: return .crop
        case .blur: return .mask
        case .annotate: return .annotate
        default: return .tools
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            if mode == .annotate, showsShapes {
                shapesBar
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            mainBar
        }
        .animation(StudioMotion.state, value: showsShapes)
        .onChange(of: mode) { _, mode in if mode != .annotate { showsShapes = false } }
    }

    /// Every shape, in a bar of its own over the Annotate bar.
    private var shapesBar: some View {
        HStack(spacing: 1) {
            ForEach(EditorModel.NewAnnotation.shapes) { kind in
                choice(kind.symbol, name: "Draw \(kind.menuTitle.lowercased())",
                       isOn: model.drawingAnnotation == kind) {
                    lastShape = kind
                    showsShapes = false
                    model.armAnnotation(kind)
                }
            }
        }
        .padding(3)
        .background(StudioTheme.Surface.floating, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(StudioTheme.Surface.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shapes")
    }

    private var mainBar: some View {
        HStack(spacing: 1) {
            switch mode {
            case .tools: tools
            case .crop: crop
            case .mask: mask
            case .annotate: annotate
            case .zoom: zoom
            }
        }
        .padding(3)
        // Floating over the picture: its own surface, a hairline edge and a soft shadow
        // under it, so it reads against whatever the frame is showing.
        .background(StudioTheme.Surface.floating, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(StudioTheme.Surface.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .opacity(model.isPlaying ? 0 : 1)
        .allowsHitTesting(!model.isPlaying)
        .animation(StudioMotion.state, value: mode)
        .animation(StudioMotion.state, value: model.isPlaying)
        .animation(StudioMotion.selection, value: model.tool)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Canvas tools")
    }

    // MARK: - The modes

    @ViewBuilder
    private var tools: some View {
        toolButton(.frame, symbol: "cursorarrow", name: "Select")
        toolButton(.crop, symbol: "crop", name: "Crop")
        toolButton(.blur, symbol: "drop.halffull", name: "Mask")
        toolButton(.annotate, symbol: "textformat", name: "Annotate")
        separator
        Button { isAdding.toggle() } label: {
            Label("Add", systemImage: "plus")
        }
        .buttonStyle(CanvasAddButtonStyle())
        .popover(isPresented: $isAdding, arrowEdge: .top) {
            StudioMenuList(sections: additions.map { group in
                .init(title: nil, rows: group.map { item in
                    .init(title: item.title, systemImage: item.symbol, thumbnail: nil,
                          isChecked: false, isEnabled: true, action: item.perform)
                })
            }, showsChecks: false)
        }
        .help("Put a label, a shape, a step, a callout, a picture or a logo on the picture")
    }

    @ViewBuilder
    private var crop: some View {
        caption("Crop", symbol: "crop")
        iconButton("arrow.counterclockwise", name: "Show the whole recording again") {
            model.setCrop(nil)
        }
        .disabled(model.timeline.style.crop == nil)
        separator
        done { model.choose(.frame) }
    }

    @ViewBuilder
    private var mask: some View {
        ForEach(BlurRegion.Style.allCases, id: \.self) { style in
            choice(style.symbol, name: style.title, isOn: model.newMaskStyle == style) {
                model.newMaskStyle = style
            }
        }
        separator
        Button { model.addMask(model.newMaskStyle) } label: {
            Label("Add", systemImage: "plus")
        }
        .buttonStyle(CanvasAddButtonStyle())
        .help("Put a \(model.newMaskStyle.title.lowercased()) in the middle of the picture, or drag over the picture to draw one")
        done(isPrimary: false) { model.choose(.frame) }
    }

    @ViewBuilder
    private var annotate: some View {
        annotationChoice(.text)
        annotationChoice(.arrow)
        // The shapes, behind one button that opens their bar. It shows the last one chosen,
        // and is lit while any of them is ready to draw.
        choice(lastShape.symbol, name: "Shapes",
               isOn: showsShapes || EditorModel.NewAnnotation.shapes.contains { $0 == model.drawingAnnotation }) {
            showsShapes.toggle()
        }
        annotationChoice(.step)
        annotationChoice(.callout)
        separator
        done { model.choose(.frame) }
    }

    /// A shape is chosen and then drawn on the picture; a label is added and typed into.
    private func annotationChoice(_ kind: EditorModel.NewAnnotation) -> some View {
        choice(kind.symbol, name: kind == .text ? "Add text" : "Draw \(kind.menuTitle.lowercased())",
               isOn: model.drawingAnnotation == kind) {
            showsShapes = false
            model.armAnnotation(kind)
        }
    }

    @ViewBuilder
    private var zoom: some View {
        ForEach(EditorModel.ZoomPreview.allCases) { preview in
            Button {
                if preview == .framing { model.frameSelectedZoom() } else { model.previewZoomResult() }
            } label: {
                Label(preview.title, systemImage: preview.symbol)
            }
            .buttonStyle(CanvasSegmentStyle(isOn: model.zoomPreview == preview))
            .help(preview == .framing
                  ? "Show the whole recording with this zoom's framing box on it"
                  : "Show this zoom as it will play and as it will export")
        }
        separator
        done { model.clearSelection() }
    }

    // MARK: - Pieces

    /// What the Add button offers: the annotation kinds, then pictures.
    private var additions: [[(title: String, symbol: String, perform: () -> Void)]] {
        [
            EditorModel.NewAnnotation.allCases.map { kind in
                (kind.menuTitle, kind.symbol, { model.armAnnotation(kind) })
            },
            [
                ("Picture", "photo", { model.addPicture(asLogo: false) }),
                ("Logo", "seal", { model.addPicture(asLogo: true) }),
            ],
        ]
    }

    private var separator: some View {
        Rectangle()
            .fill(StudioTheme.Surface.hairline)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }

    /// The mode's name, so the bar says what it is for while its buttons change.
    private func caption(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(StudioTheme.Surface.value)
            .padding(.horizontal, 8)
            .frame(height: 28)
    }

    private func done(isPrimary: Bool = true, action: @escaping () -> Void) -> some View {
        Group {
            if isPrimary {
                Button("Done", action: action).buttonStyle(CanvasAddButtonStyle())
            } else {
                Button("Done", action: action).buttonStyle(CanvasSegmentStyle(isOn: false))
            }
        }
        .help("Finish, and go back to selecting")
    }

    private func toolButton(_ tool: VideoEditorTool, symbol: String, name: String) -> some View {
        choice(symbol, name: name, isOn: model.tool == tool) { model.choose(tool) }
    }

    private func choice(_ symbol: String, name: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? StudioTheme.Surface.ink : StudioTheme.Surface.value)
                .frame(width: 28, height: 28)
                .background(isOn ? StudioTheme.Surface.fieldHover : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressStyle())
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func iconButton(_ symbol: String, name: String, action: @escaping () -> Void) -> some View {
        choice(symbol, name: name, isOn: false, action: action)
    }
}

/// A word on the canvas bar that is one of a pair — Framing or Result.
private struct CanvasSegmentStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(isOn ? StudioTheme.Surface.ink : StudioTheme.Surface.value)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(isOn ? StudioTheme.Surface.fieldHover : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

/// The canvas bar's one light button.
private struct CanvasAddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(StudioTheme.Surface.onPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(StudioTheme.Surface.primaryButton.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
    }
}
