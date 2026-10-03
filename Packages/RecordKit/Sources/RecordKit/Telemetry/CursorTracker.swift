import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import os

/// Where a point on screen lands inside what is being recorded.
///
/// Global screen coordinates are not what the editor wants: it draws on top of a frame
/// whose origin is the top-left of the recorded area. Translating once, here, means
/// every sample on disk is already in the frame's space.
///
/// The origin has to be in the same space the pointer is read in, which is `CGEvent`'s:
/// points, y downwards, with the *main* display's top-left at zero. This used to be taken
/// from `SCContentFilter.contentRect`, whose origin is zero for a display and for a window
/// — it describes the size of the content, not where on the desk it sits. So the
/// translation was a no-op, and every sample was a global screen position written down as
/// though it were a position inside the frame. On one built-in display that is the same
/// number and nobody noticed. Record the second display and every position is out by the
/// first display's width; record a window and every position is out by wherever that
/// window happens to be.
///
/// A class rather than a value, and it moves: a window being recorded can be dragged
/// across the screen while the recording runs. The picture does not move — ScreenCaptureKit
/// follows the window — but the pointer's global position does, so an origin fixed at the
/// start would put the drawn pointer further from the truth with every inch of the drag.
/// `refresh()` re-reads it; the caller decides how often.
public final class CursorMapper: @unchecked Sendable {
    /// How a point on the desk becomes a point in the frame: take the recorded corner
    /// away, scale by however much the picture was scaled on its way into the file, and
    /// add wherever in the file the picture was put.
    ///
    /// Scale and offset are one and zero for a display and an area, where the picture fills
    /// the file point for point. A window is where they stop being: the file's size is
    /// fixed when the take starts, and a window that is bigger than that by the time frames
    /// arrive — resized, gone full screen, or simply reported smaller than it was — is
    /// shrunk to fit. The pointer used to be written down as though it had not been, so
    /// every sample landed further from the truth the further it was from the corner.
    struct Placement: Equatable {
        var origin: CGPoint
        var scale: CGFloat = 1
        var offset: CGPoint = .zero
        /// Set once a frame has said where the window is. From then on the frames are the
        /// authority and the window server's answer is no longer asked for.
        var isFromFrames = false
    }

    /// The window being followed, when the recording is of a window.
    private let window: CGWindowID?
    /// Pixels in the file per point of the frame the editor draws on — the recording's
    /// `displayScale`. What a frame reports is in pixels; what the samples are in is points.
    private let outputScale: CGFloat
    private let state: OSAllocatedUnfairLock<Placement>

    public init(origin: CGPoint, following window: CGWindowID? = nil, outputScale: CGFloat = 1) {
        self.window = window
        self.outputScale = max(outputScale, 0.01)
        state = OSAllocatedUnfairLock(initialState: Placement(origin: origin))
    }

    /// The recorded area's origin in global screen points, top-left.
    public var origin: CGPoint { state.withLock { $0.origin } }

    var placement: Placement { state.withLock { $0 } }

    public func map(_ point: CGPoint) -> CGPoint {
        let placed = placement
        return CGPoint(x: (point.x - placed.origin.x) * placed.scale + placed.offset.x,
                       y: (point.y - placed.origin.y) * placed.scale + placed.offset.y)
    }

    /// A rectangle on the desk as a rectangle in the frame — its size scaled with the
    /// picture, not only its corner moved.
    public func map(_ rect: CGRect) -> CGRect {
        let scale = placement.scale
        return CGRect(origin: map(rect.origin),
                      size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    /// Re-reads where the recorded window is now. Nothing to do for a display or an area:
    /// a display does not move, and an area is a rectangle of one.
    ///
    /// Cheap enough to call at the rate a pointer changes shape — one window's entry from
    /// the window server — and deliberately not called per sample, which is 120 times a
    /// second for something that moves at the speed of a hand.
    ///
    /// Only until the first frame arrives. After that each frame says where the window is,
    /// which is better than asking: the window server's answer for a window that has gone
    /// full screen on its own Space can be the frame it had before, and trusting it put
    /// every pointer a title bar's height and more away from where it was.
    public func refresh() {
        guard let window, !placement.isFromFrames else { return }
        Self.frame(of: window).map { move(to: $0.origin) }
    }

    /// Puts the recorded corner somewhere else. Separate from `refresh()` so the
    /// translation can be checked without a window server.
    func move(to origin: CGPoint) {
        state.withLock { $0.origin = origin }
    }

    /// Where a captured frame says the window was, and what was done to it on its way in.
    ///
    /// Frames are the one source that cannot disagree with the picture, because they are
    /// the picture. Called from the capture queue for every complete frame; a frame that
    /// does not say where it is leaves the last answer in place.
    public func place(_ frame: FrameGeometry) {
        guard let placed = Self.placement(for: frame, outputScale: outputScale) else { return }
        let previous = state.withLock { current in
            defer { current = placed }
            return current
        }
        // Said once per change rather than per frame: this is the number every pointer in
        // the take is measured from, and when it is wrong the log is the only place that
        // can show by how much without a screen recording of the screen recording.
        guard previous.isFromFrames == false
                || abs(previous.origin.x - placed.origin.x) > 0.5
                || abs(previous.origin.y - placed.origin.y) > 0.5
                || abs(previous.scale - placed.scale) > 0.001 else { return }
        Self.log.notice("""
            Pointer placed from frames: window at \(frame.screenRect.debugDescription, privacy: .public), \
            content \(frame.contentRect.debugDescription, privacy: .public) × \(frame.contentScale, privacy: .public) \
            @\(frame.scaleFactor, privacy: .public)x; was origin \(previous.origin.debugDescription, privacy: .public) \
            scale \(previous.scale, privacy: .public)
            """)
    }

    private static let log = Logger(subsystem: "com.stackrover.klik.recordkit", category: "cursor")

    /// The arithmetic of `place(_:)`, on its own so it can be checked without a stream.
    ///
    /// `contentScale × scaleFactor` is pixels in the file per point of the window (it is
    /// what Apple's own capture sample sets as the layer's `contentsScale`); dividing by
    /// the file's own scale turns that into points of the frame. The content rect is in
    /// the surface's points, so its corner goes through the same scale factor.
    static func placement(for frame: FrameGeometry, outputScale: CGFloat) -> Placement? {
        guard frame.screenRect.width > 1, frame.screenRect.height > 1,
              frame.contentScale > 0, frame.scaleFactor > 0 else { return nil }
        let scale = frame.contentScale * frame.scaleFactor / outputScale
        let offset = CGPoint(x: frame.contentRect.origin.x * frame.scaleFactor / outputScale,
                             y: frame.contentRect.origin.y * frame.scaleFactor / outputScale)
        // The picture can be taller than the window that was picked. A full-screen Chrome is
        // three windows — the page, and the tab strip and toolbar stacked above it — and the
        // capture takes all three while the picked one is only the page. When the content is
        // taller than the rectangle the frame reports, what is missing is what is attached
        // above, so the picture starts that much higher. Nothing changes when the rectangle
        // already covers the whole picture.
        let contentHeight = frame.contentRect.height / frame.contentScale
        var origin = frame.screenRect.origin
        // Bounded: a toolbar is a fraction of a window. Content twice the window's height
        // is a number read in the wrong unit, not a window with another stacked on it.
        if contentHeight > frame.screenRect.height + 2, contentHeight < frame.screenRect.height * 1.5 {
            origin.y = frame.screenRect.maxY - contentHeight
        }
        return Placement(origin: origin, scale: scale, offset: offset, isFromFrames: true)
    }

    /// Where a window is now, according to the window server.
    private static func frame(of window: CGWindowID) -> CGRect? {
        guard let listing = CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]],
              let bounds = listing.first?[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        // A window that has closed leaves the last known origin in place rather than
        // snapping every later sample to the corner of the screen.
        else { return nil }
        return rect
    }
}

/// What ScreenCaptureKit says about where one frame's picture came from and where it put it.
///
/// Read off the frame's attachments. A value of its own so the mapper can be given one
/// without a sample buffer, which a test cannot make.
public struct FrameGeometry: Sendable, Equatable {
    /// Where the captured content was on the desk, in global points.
    public var screenRect: CGRect
    /// Where the content sits in the frame, in the frame's points.
    public var contentRect: CGRect
    /// How much the content was scaled to fit the frame. Below one when it was shrunk.
    public var contentScale: CGFloat
    /// Pixels per point of the display the content was on.
    public var scaleFactor: CGFloat

    public init(screenRect: CGRect, contentRect: CGRect, contentScale: CGFloat, scaleFactor: CGFloat) {
        self.screenRect = screenRect
        self.contentRect = contentRect
        self.contentScale = contentScale
        self.scaleFactor = scaleFactor
    }
}

/// Records where the pointer went and what it did, as data beside the video.
///
/// This is the file that makes everything afterwards possible: auto-zoom follows it,
/// the rendered cursor is drawn from it, click bounce comes from the button events. None
/// of that can be recovered from pixels, which is why the video is recorded without a
/// cursor in it at all.
///
/// Positions are sampled with `CGEvent`, which is safe to read from any thread, on the
/// same queue the encoder runs on. The *shape* is AppKit's and main-thread-only, so it
/// is polled more slowly on the main actor and read back under a lock — a pointer that
/// changes shape 20 times a second is already an unusual second.
public final class CursorTracker: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.stackrover.klik.recordkit", category: "cursor")

    private let queue: DispatchQueue
    private let cursorWriter: JSONLWriter
    private let inputWriter: JSONLWriter?
    private let clock: RecordingClock
    private let mapper: CursorMapper
    private let sampleRate: Int
    /// How long after the pointer is somewhere the screen shows it there.
    ///
    /// Added to every time written here, so a sample says when the pointer was *seen* at
    /// a place rather than when the system knew it was going to be. See
    /// `PointerLatency`.
    private let latency: CMTime

    /// Saves what each pointer actually looked like. `nil` when this take is not keeping
    /// the real artwork.
    private let artwork: CursorArtworkWriter?

    private var positionTimer: DispatchSourceTimer?
    private var shapeTimer: Timer?
    private var clickMonitor: Any?
    private let shape = OSAllocatedUnfairLock(initialState: CursorShape.arrow)
    /// For a window recording: whether the window is in front, and the frame's size in
    /// points. A click is only the recording's when it was made in the window while the
    /// window was in front — a click in another app is somewhere the picture is not.
    private let presence: WindowPresence?
    private let frameSize: CGSize?
    /// The buttons whose press was kept, so a release is kept exactly when its press was.
    private let keptPresses = OSAllocatedUnfairLock(initialState: Set<Int>())

    public init(cursorWriter: JSONLWriter,
                inputWriter: JSONLWriter?,
                queue: DispatchQueue,
                clock: RecordingClock,
                mapper: CursorMapper,
                sampleRate: Int,
                latency: Double = 0,
                artwork: CursorArtworkWriter? = nil,
                presence: WindowPresence? = nil,
                frameSize: CGSize? = nil) {
        self.presence = presence
        self.frameSize = frameSize
        self.latency = CMTime(seconds: max(0, min(latency, 0.05)), preferredTimescale: 1_000_000_000)
        self.artwork = artwork
        self.cursorWriter = cursorWriter
        self.inputWriter = inputWriter
        self.queue = queue
        self.clock = clock
        self.mapper = mapper
        self.sampleRate = max(1, sampleRate)
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(sampleRate)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sample() }
        positionTimer = timer
        timer.resume()

        MainActor.assumeIsolated { startMainThreadWatchers() }
    }

    public func stop() {
        positionTimer?.cancel()
        positionTimer = nil
        MainActor.assumeIsolated { stopMainThreadWatchers() }
    }

    /// One position sample. Runs on the capture queue.
    private func sample() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let point = mapper.map(location)
        cursorWriter.append(CursorSample(t: clock.elapsed(at: RecordingClock.now + latency),
                                         x: Double(point.x),
                                         y: Double(point.y),
                                         shape: shape.withLock { $0 }))
    }

    // MARK: - Main thread

    @MainActor
    private func startMainThreadWatchers() {
        // Mouse events, unlike key events, need no Accessibility grant. The keys are
        // `KeyTracker`'s, which is where the grant is checked and the privacy rule lives.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp,
                                                                    .rightMouseDown, .rightMouseUp,
                                                                    .otherMouseDown, .otherMouseUp,
                                                                    .scrollWheel]) { [weak self] event in
            self?.record(event)
        }

        let pacing = ShapePacing()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // `currentSystem` is nil when the pointer is over another app's window
                // that hides it; the last known shape is a better answer than `.arrow`.
                guard let self else { return }
                // Where the recorded window is now, on the same slow timer as the shape:
                // both are things that change at the speed of a hand, and neither is worth
                // asking about 120 times a second.
                self.mapper.refresh()
                // The shape is asked for only when it can have changed. `currentSystem`
                // copies the cursor's images out of the window server, and recognising them
                // compares pixels — twenty times a second for the whole take, pointer still
                // or not, it was the largest thing the recorder did on the main thread, and
                // a share of the window server's own load besides. A shape changes as the
                // pointer moves over something; the few that change by themselves — a
                // spinner, a text cursor appearing — are caught by the half-second look.
                let pointer = NSEvent.mouseLocation
                let now = CACurrentMediaTime()
                let moved = pointer != pacing.pointer
                guard (moved && now - pacing.checked >= 0.1) || now - pacing.checked >= 0.5 else { return }
                pacing.pointer = pointer
                pacing.checked = now
                guard let cursor = NSCursor.currentSystem else { return }
                let current = CursorShape(cursor)
                self.shape.withLock { $0 = current }
                // The first time each shape appears, and never again — see
                // `CursorArtworkWriter`. This is the only moment the real pointer can be
                // read: afterwards there is a recording and no cursor.
                self.artwork?.capture(current, from: cursor)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shapeTimer = timer
    }

    /// When the shape was last asked for, and where the pointer was. Read and written only
    /// on the main thread, by the shape timer.
    private final class ShapePacing: @unchecked Sendable {
        var pointer: CGPoint?
        var checked: CFTimeInterval = 0
    }

    @MainActor
    private func stopMainThreadWatchers() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        shapeTimer?.invalidate()
        shapeTimer = nil
    }

    @MainActor
    private func record(_ event: NSEvent) {
        guard let inputWriter else { return }
        // When and where it *happened*, not when and where this was told about it.
        //
        // A global monitor is called on the main thread some time after the event, and the
        // main thread of a recorder is a busy place. Reading the clock and the pointer
        // here used to stamp a click with the moment the callback ran and the place the
        // pointer had got to by then — so a click made on the way somewhere landed further
        // along the way, and the ring was drawn beside the thing that was pressed.
        let t = clock.elapsed(at: Self.hostTime(of: event) + latency)
        let location = mapper.map(Self.location(of: event))

        let counts = Self.counts(location, isInFront: presence?.isInFront ?? true, frameSize: frameSize)
        let button = event.buttonNumber
        let sample: InputSample?
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard counts else { return }
            keptPresses.withLock { _ = $0.insert(button) }
            sample = .mouseDown(t: t, button: button, x: Double(location.x), y: Double(location.y))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard keptPresses.withLock({ $0.remove(button) != nil }) else { return }
            sample = .mouseUp(t: t, button: button, x: Double(location.x), y: Double(location.y))
        case .scrollWheel:
            guard counts else { return }
            sample = .scroll(t: t, dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY))
        default:
            sample = nil
        }
        guard let sample else { return }
        queue.async { inputWriter.append(sample) }
    }

    /// Whether a click or scroll at a point in the frame is the recording's: always, for a
    /// display or an area; for a window, only inside it and only while it is in front.
    static func counts(_ point: CGPoint, isInFront: Bool, frameSize: CGSize?) -> Bool {
        guard isInFront else { return false }
        guard let frameSize, frameSize.width > 0, frameSize.height > 0 else { return true }
        return point.x >= 0 && point.y >= 0 && point.x <= frameSize.width && point.y <= frameSize.height
    }

    /// The moment an event happened, on the clock the frames are stamped in.
    ///
    /// `NSEvent.timestamp` counts seconds since the machine started, which is what the
    /// host clock counts too. An event that claims to be from the future, or from more
    /// than a second ago, is one whose timestamp cannot be trusted, and "now" is the
    /// better answer.
    static func hostTime(of event: NSEvent, now: CMTime = RecordingClock.now) -> CMTime {
        hostTime(forEventTimestamp: event.timestamp, now: now)
    }

    static func hostTime(forEventTimestamp timestamp: TimeInterval, now: CMTime) -> CMTime {
        let stamped = CMTime(seconds: timestamp, preferredTimescale: 1_000_000_000)
        let age = (now - stamped).seconds
        guard stamped.isValid, age >= -0.005, age < 1 else { return now }
        return min(stamped, now)
    }

    /// Where an event happened, in the space the pointer is sampled in: global points,
    /// y downwards, the main display's top-left at zero.
    @MainActor
    static func location(of event: NSEvent) -> CGPoint {
        if let location = event.cgEvent?.location { return location }
        return CGEvent(source: nil)?.location ?? .zero
    }
}

extension CursorShape {
    /// Names the system cursor.
    ///
    /// Identity first, because it is free and right for Klik's own windows. It is almost
    /// never the answer while recording, though: the pointer over another app's window —
    /// the browser being recorded — comes back from `currentSystem` as a fresh `NSCursor`
    /// every time, never `===` to `NSCursor.pointingHand` even when it is that hand. So
    /// every pointer in a recording of Chrome used to be `.other`, and `.other` kept the
    /// first picture it saw — an arrow — for the rest of the take: a hand over every link
    /// drawn as an arrow.
    ///
    /// The picture is the answer instead. See `CursorFingerprint`.
    @MainActor
    init(_ cursor: NSCursor) {
        if let known = Self.byIdentity(cursor) {
            self = known
        } else {
            self = CursorFingerprint.recognise(cursor) ?? .other
        }
    }

    @MainActor
    private static func byIdentity(_ cursor: NSCursor) -> CursorShape? {
        switch cursor {
        case NSCursor.arrow: .arrow
        case NSCursor.iBeam, NSCursor.iBeamCursorForVerticalLayout: .iBeam
        case NSCursor.pointingHand: .pointingHand
        case NSCursor.openHand: .openHand
        case NSCursor.closedHand: .closedHand
        case NSCursor.crosshair: .crosshair
        case NSCursor.resizeLeftRight, NSCursor.resizeLeft, NSCursor.resizeRight: .resizeLeftRight
        case NSCursor.resizeUpDown, NSCursor.resizeUp, NSCursor.resizeDown: .resizeUpDown
        case NSCursor.disappearingItem: .disappearingItem
        case NSCursor.operationNotAllowed: .operationNotAllowed
        case NSCursor.dragCopy: .dragCopy
        case NSCursor.dragLink: .dragLink
        case NSCursor.contextualMenu: .contextualMenu
        default: nil
        }
    }
}

/// A cursor, reduced to something two cursors can be compared by.
///
/// Size and hotspot are not enough: the arrow, "not allowed", "copy", "contextual menu"
/// and "disappearing item" are all 28 × 40 with the point at (5, 5) — they are the arrow
/// with a badge. So the picture itself is compared, drawn down to a small grid. The grid is
/// the same whatever size the cursor is, which keeps a pointer that has been made larger in
/// Accessibility settings recognisable as the shape it is.
struct CursorFingerprint {
    static let side = 24

    /// The hotspot as a fraction of the image.
    let hotspot: CGPoint
    /// Width over height.
    let aspect: CGFloat
    /// Alpha and luminance per cell, `side × side × 2`.
    let cells: [UInt8]

    @MainActor
    init?(_ cursor: NSCursor) {
        let image = cursor.image
        let size = image.size
        guard size.width > 0, size.height > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        hotspot = CGPoint(x: cursor.hotSpot.x / size.width, y: cursor.hotSpot.y / size.height)
        aspect = size.width / size.height

        let side = Self.side
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var cells = [UInt8](repeating: 0, count: side * side * 2)
        for index in 0..<(side * side) {
            let r = Int(rgba[index * 4]), g = Int(rgba[index * 4 + 1]), b = Int(rgba[index * 4 + 2])
            cells[index * 2] = rgba[index * 4 + 3]
            cells[index * 2 + 1] = UInt8((r * 299 + g * 587 + b * 114) / 1000)
        }
        self.cells = cells
    }

    /// How far apart two cursors are: zero for the same picture, one for nothing alike.
    /// `nil` when their shape or point alone rules them out.
    func distance(to other: CursorFingerprint) -> Double? {
        guard abs(aspect - other.aspect) < 0.06,
              abs(hotspot.x - other.hotspot.x) < 0.06,
              abs(hotspot.y - other.hotspot.y) < 0.06 else { return nil }
        var total = 0
        for index in cells.indices {
            total += abs(Int(cells[index]) - Int(other.cells[index]))
        }
        return Double(total) / Double(cells.count * 255)
    }

    /// Close enough to be the same cursor redrawn — scaled, or on another display — and
    /// far enough from the arrow that the arrow with a small badge on it is still told apart.
    static let threshold = 0.04

    /// Which standard cursor this is, or `nil` for one that is none of them.
    @MainActor
    static func recognise(_ cursor: NSCursor) -> CursorShape? {
        guard let print = CursorFingerprint(cursor) else { return nil }
        var best: (shape: CursorShape, distance: Double)?
        for (shape, known) in standard {
            guard let distance = print.distance(to: known), distance < threshold else { continue }
            if best == nil || distance < best!.distance { best = (shape, distance) }
        }
        return best?.shape
    }

    /// The system's own cursors, drawn once. Built lazily and on the main actor, where
    /// `NSCursor`'s images can be read; a cursor that has no picture to read is left out
    /// rather than matched against nothing.
    @MainActor
    static let standard: [(CursorShape, CursorFingerprint)] = {
        let cursors: [(CursorShape, NSCursor)] = [
            (.arrow, .arrow), (.iBeam, .iBeam), (.iBeam, .iBeamCursorForVerticalLayout),
            (.pointingHand, .pointingHand), (.openHand, .openHand), (.closedHand, .closedHand),
            (.crosshair, .crosshair),
            (.resizeLeftRight, .resizeLeftRight), (.resizeLeftRight, .resizeLeft), (.resizeLeftRight, .resizeRight),
            (.resizeUpDown, .resizeUpDown), (.resizeUpDown, .resizeUp), (.resizeUpDown, .resizeDown),
            (.disappearingItem, .disappearingItem), (.operationNotAllowed, .operationNotAllowed),
            (.dragCopy, .dragCopy), (.dragLink, .dragLink), (.contextualMenu, .contextualMenu),
        ]
        return cursors.compactMap { shape, cursor in
            CursorFingerprint(cursor).map { (shape, $0) }
        }
    }()
}
