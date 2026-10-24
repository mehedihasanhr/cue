import AppKit
import CoreVideo
import QuartzCore
import SwiftUI

/// Where a playing frame goes: straight onto a layer, without SwiftUI.
///
/// The preview was an `Image` of an `NSImage`, which is right for a still frame and wrong
/// for thirty a second. Every new frame was a change SwiftUI had to carry through the
/// whole preview pane, and the picture — tens of megabytes of a Retina frame — was copied
/// on the main thread on its way to the screen. That, not drawing the frame, was most of
/// what each playing frame cost, and it came out as a stutter. Here the frame is drawn
/// into a buffer the window server can show as it is, and handed to a layer directly.
@MainActor
final class LiveFrameSink {
    fileprivate weak var layer: CALayer?
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    /// The frames lately handed over, kept alive while the screen may still be showing
    /// them, so the pool does not hand one back to be drawn over mid-display.
    private var recent: [CVPixelBuffer] = []

    /// A buffer to draw the next frame into, `size` pixels.
    func buffer(size: CGSize, colorSpace: CGColorSpace) -> CVPixelBuffer? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        if pool == nil || poolSize != CGSize(width: width, height: height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                    attributes as CFDictionary, &pool)
            poolSize = CGSize(width: width, height: height)
            recent.removeAll()
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        return buffer
    }

    /// Puts a drawn frame on screen.
    func show(_ buffer: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
        recent.append(buffer)
        if recent.count > 3 { recent.removeFirst() }
    }

    /// Lets go of the buffers once playback is over.
    func clear() {
        layer?.contents = nil
        recent.removeAll()
    }
}

/// A buffer handed to the drawing thread and back. Drawn into there and only shown here
/// afterwards, never touched by both at once.
nonisolated struct LiveFrameBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// The layer a `LiveFrameSink` draws on.
struct LiveFrameView: NSViewRepresentable {
    let sink: LiveFrameSink

    func makeNSView(context: Context) -> HostingView {
        let view = HostingView()
        sink.layer = view.hosted
        return view
    }

    func updateNSView(_ view: HostingView, context: Context) {
        sink.layer = view.hosted
    }

    /// A view that hosts its layer rather than being backed by one.
    ///
    /// The order is the whole point: the layer is given to the view *before* it is told to
    /// want one. The other way round makes a layer-backed view, whose layer AppKit owns and
    /// may swap for one of its own — and it did, a second or so into playback, which freed
    /// this layer (the sink holds it weakly) and left every frame after it drawn into
    /// nothing: the editor played black. A hosted layer is left alone, and kept here.
    final class HostingView: NSView {
        let hosted: CALayer = {
            let layer = CALayer()
            layer.contentsGravity = .resize
            layer.minificationFilter = .trilinear
            layer.magnificationFilter = .linear
            return layer
        }()

        init() {
            super.init(frame: .zero)
            layer = hosted
            wantsLayer = true
            layerContentsRedrawPolicy = .never
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
