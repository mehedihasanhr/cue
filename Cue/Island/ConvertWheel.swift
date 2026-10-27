import AppKit
import SwiftUI

/// What the convert wheel offers, clockwise from the top.
enum WheelFormat: CaseIterable {
    case jpeg, webp, heic, tiff, avif, bmp, pdf, png

    var title: String {
        switch self {
        case .jpeg: "JPG"
        case .webp: "WEBP"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .avif: "AVIF"
        case .bmp: "BMP"
        case .pdf: "PDF"
        case .png: "PNG"
        }
    }

    /// The image format it writes; nil for PDF, which is a page rather than a picture.
    var format: TransformEngine.Format? {
        switch self {
        case .jpeg: .jpeg
        case .webp: .webp
        case .heic: .heic
        case .tiff: .tiff
        case .avif: .avif
        case .bmp: .bmp
        case .png: .png
        case .pdf: nil
        }
    }

    /// The ones this Mac can write.
    static var available: [WheelFormat] {
        allCases.filter { $0.format.map(TransformEngine.Format.available.contains) ?? true }
    }
}

@MainActor @Observable
final class ConvertWheelModel {
    var shown = false
    /// The segment under the dragged file.
    var hovered: WheelFormat?
    var formats: [WheelFormat] = WheelFormat.available
    var file: URL? {
        didSet { if file != oldValue { sizes = [:]; working = [] } }
    }
    /// What each format's copy comes to, worked out as the file is held over it.
    private(set) var sizes: [WheelFormat: Int] = [:]
    private var working: Set<WheelFormat> = []

    var name: String { file?.lastPathComponent ?? "" }

    /// The copy's size for the format held over, else the file's own; nil while it's
    /// still being worked out.
    var size: String? {
        guard let file else { return "" }
        guard let hovered else { return TransformModel.bytes(TransformEngine.fileSize(file)) }
        return sizes[hovered].map(TransformModel.bytes)
    }

    /// Makes the copy in memory, as the drop would (same quality), and keeps its size.
    func measure(_ format: WheelFormat) {
        guard let file, sizes[format] == nil, !working.contains(format) else { return }
        working.insert(format)
        let target = format.format
        Task.detached(priority: .userInitiated) { [weak self] in
            let data = target.map { TransformEngine.converted(file, to: $0, quality: 0.9) } ?? TransformEngine.combined([file])
            await MainActor.run {
                guard let self, self.file == file else { return }
                self.working.remove(format)
                if let data { self.sizes[format] = data.count }
            }
        }
    }
}

/// The ring's measures, shared by the drawing and the drop target.
enum WheelGeometry {
    /// The window: the wheel and room for its shadow.
    static let window = CGSize(width: 340, height: 340)
    static let outer: CGFloat = 150
    static let inner: CGFloat = 64
    /// The glass rim round the segments.
    static let rim: CGFloat = 8
    static let gap: CGFloat = 5

    /// The segment at `point` (from the window's centre, y up), if it's on the ring.
    static func index(at point: CGPoint, count: Int) -> Int? {
        let distance = hypot(point.x, point.y)
        guard distance > inner, distance < outer, count > 0 else { return nil }
        // Clockwise from straight up.
        var angle = atan2(point.x, point.y)
        if angle < 0 { angle += 2 * .pi }
        let step = 2 * .pi / CGFloat(count)
        return Int((angle + step / 2) / step) % count
    }
}

/// A file dragged with Shift held and shaken: a ring of formats round it, the file in
/// the middle its size and name. Dropped on a segment, a copy is made in that
/// format; the original is left as it was.
struct ConvertWheelView: View {
    let model: ConvertWheelModel
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var ink: Color { dark ? .white : Color(light: 0x1C1C1C, dark: 0x1C1C1C) }

    var body: some View {
        let count = model.formats.count
        ZStack {
            // The glass disc the segments sit in.
            Circle()
                .fill(.clear)
                .frame(width: WheelGeometry.outer * 2 + WheelGeometry.rim * 2, height: WheelGeometry.outer * 2 + WheelGeometry.rim * 2)
                .modifier(WheelGlass(dark: dark))
            ForEach(Array(model.formats.enumerated()), id: \.element) { index, format in
                segment(format, index: index, count: count)
            }
            centre
        }
        .frame(width: WheelGeometry.window.width, height: WheelGeometry.window.height)
        .scaleEffect(model.shown ? 1 : 0.6)
        .rotationEffect(.degrees(model.shown ? 0 : -25))
        .opacity(model.shown ? 1 : 0)
        .animation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.7), value: model.shown)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: model.hovered)
    }

    private func segment(_ format: WheelFormat, index: Int, count: Int) -> some View {
        let lit = model.hovered == format
        let step = 360 / Double(count)
        let middle = Angle.degrees(Double(index) * step)
        let shape = RingSegment(start: .degrees(Double(index) * step - step / 2), end: .degrees(Double(index) * step + step / 2),
                                inner: WheelGeometry.inner, outer: WheelGeometry.outer, gap: WheelGeometry.gap, corner: 14)
        // The label sits halfway across the ring, upright.
        let radius = (WheelGeometry.inner + WheelGeometry.outer) / 2 + 4
        let offset = CGSize(width: sin(middle.radians) * radius, height: -cos(middle.radians) * radius)
        return ZStack {
            shape.fill(segmentFill(lit: lit))
            shape.stroke(.white.opacity(dark ? 0.12 : 0.65), lineWidth: 1)
            Text(format.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(ink)
                .offset(offset)
        }
        .frame(width: WheelGeometry.window.width, height: WheelGeometry.window.height)
        .scaleEffect(lit ? 1.04 : 1)
        .shadow(color: .black.opacity(lit ? 0.18 : 0), radius: 8, y: 3)
    }

    private func segmentFill(lit: Bool) -> AnyShapeStyle {
        if dark { return AnyShapeStyle(Color.white.opacity(lit ? 0.26 : 0.1)) }
        return AnyShapeStyle(LinearGradient(colors: [.white.opacity(lit ? 0.95 : 0.62), .white.opacity(lit ? 0.85 : 0.45)],
                                            startPoint: .top, endPoint: .bottom))
    }

    /// The size of the copy for the format held over (the file's own before then), on a
    /// glass pill, the file's name under.
    private var centre: some View {
        let side = (WheelGeometry.inner - 6) * 2
        return ZStack {
            Circle().fill(dark ? Color.white.opacity(0.08) : Color.white.opacity(0.4))
            VStack(spacing: 5) {
                Group {
                    if let size = model.size {
                        Text(size)
                            .contentTransition(.numericText())
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(ink)
                .padding(.horizontal, 12)
                .frame(minWidth: 64)
                .frame(height: 28)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 0.75))
                .animation(.snappy(duration: 0.2), value: model.size)
                Text(model.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Color(red: 0.18, green: 0.42, blue: 0.95)))
                    .frame(maxWidth: side - 14)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(dark ? 0.15 : 0.7), lineWidth: 1))
    }
}

/// The disc behind the segments: Liquid Glass with a soft rim and shadow.
private struct WheelGlass: ViewModifier {
    let dark: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(dark ? .black.opacity(0.3) : .white.opacity(0.25)), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(dark ? 0.15 : 0.7), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(dark ? 0.15 : 0.7), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
    }
}

/// A slice of a ring with rounded corners and a gap either side, centred in its rect.
private struct RingSegment: Shape {
    let start: Angle
    let end: Angle
    let inner: CGFloat
    let outer: CGFloat
    let gap: CGFloat
    let corner: CGFloat

    nonisolated func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        // Inset by the corner radius, then stroked as wide as twice it with round joins:
        // the same slice, its corners rounded.
        let r1 = inner + corner, r2 = outer - corner
        let half = gap / 2 + corner
        // Angles measured clockwise from up; Path wants them from the x axis, y down.
        func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: centre.x + radius * sin(angle), y: centre.y - radius * cos(angle))
        }
        let a1 = start.radians, a2 = end.radians
        let outerStart = a1 + Double(half / r2), outerEnd = a2 - Double(half / r2)
        let innerStart = a1 + Double(half / r1), innerEnd = a2 - Double(half / r1)
        var core = Path()
        core.move(to: point(r2, outerStart))
        core.addArc(center: centre, radius: r2, startAngle: .radians(outerStart - .pi / 2), endAngle: .radians(outerEnd - .pi / 2), clockwise: false)
        core.addLine(to: point(r1, innerEnd))
        core.addArc(center: centre, radius: r1, startAngle: .radians(innerEnd - .pi / 2), endAngle: .radians(innerStart - .pi / 2), clockwise: true)
        core.closeSubpath()
        // One outline (a union), so a translucent fill shows no seams where the two overlap.
        return core.strokedPath(SwiftUI.StrokeStyle(lineWidth: corner * 2, lineJoin: .round)).union(core)
    }
}

/// The wheel's window content: tells which segment the file is over, and takes it.
final class ConvertWheelDropView: NSView {
    var count: () -> Int = { 0 }
    var onHover: ((Int?) -> Void)?
    var onDrop: ((Int, [URL]) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func index(_ sender: any NSDraggingInfo) -> Int? {
        let point = convert(sender.draggingLocation, from: nil)
        return WheelGeometry.index(at: CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY), count: count())
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let index = index(sender)
        onHover?(index)
        return index == nil ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onHover?(nil) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let index = index(sender),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDrop?(index, urls)
        return true
    }
}
