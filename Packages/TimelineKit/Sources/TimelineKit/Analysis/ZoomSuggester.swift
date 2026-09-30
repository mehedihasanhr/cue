import CoreGraphics
import CoreMedia
import Foundation
import RecordKit

/// Works out where a recording wants to zoom in, from where the pointer went and what
/// had focus.
///
/// Every tool in this space offers this and none of them document how it works, so the
/// rules here are written down:
///
/// 1. **People click where they want you to look.** A cluster of clicks close together
///    in time and space is a moment worth being close to.
/// 2. **People look at what they just brought forward.** A window coming to the front, a
///    sheet opening, a text field taking the caret — each is someone saying "this bit
///    now", and each comes with a *rectangle*, which says how far in to go as well as
///    where.
///
/// A click knows a point; focus knows a shape. That is why both exist: clicks alone
/// cannot tell a zoom into a small toolbar from a zoom into a full-screen window, and
/// focus alone misses everything done inside a window that never changes.
///
/// A pure function over the sidecars, so it can be re-run with different settings,
/// tested against a recorded take, and tuned without touching the editor.
public struct ZoomSuggester: Sendable {
    public struct Tuning: Sendable {
        /// Clicks closer together than this belong to the same moment.
        public var clusterGap: Double
        /// How long before the first click the zoom starts, so the move is finished by
        /// the time the thing happens.
        public var leadIn: Double
        /// How long after the last click it holds.
        public var holdAfter: Double
        public var minimumDuration: Double
        public var maximumDuration: Double
        /// How long each zoom takes to go in and to come out — the project's zoom speed.
        public var transition: Double
        /// How far in to go for a click. Bigger than 2 starts to look like a magnifying
        /// glass.
        public var scale: Double
        /// Points of pointer travel inside a cluster before it is treated as movement
        /// across the screen rather than work in one place.
        public var spreadLimit: Double

        /// Let focus events propose zooms at all.
        public var followsFocus: Bool
        /// Shorter than the click lead-in: focus is the moment itself, not a warning
        /// that one is coming, so the camera has less time to be early and a long
        /// lead-in would start the move before the window it is moving to exists.
        public var focusLeadIn: Double
        /// How long a focus zoom holds when nothing follows it.
        public var focusHold: Double
        /// How much of the frame the focused thing should fill once the camera arrives.
        /// Not 1: something framed edge to edge reads as a crop, not as attention.
        public var focusFill: Double
        /// A focused rectangle already covering more of the frame than this is the
        /// picture. Zooming to it would be a nudge nobody asked for.
        public var focusCoverageLimit: Double
        /// Below this, a focus zoom is not worth the movement.
        public var minimumFocusScale: Double
        /// How long focus has to stay somewhere before it is worth going there.
        ///
        /// Tabbing through four fields to reach the fifth is one moment, not five, and
        /// a camera that visited each on the way would be unwatchable.
        public var minimumFocusDwell: Double
        /// The ceiling on a scale worked out from a rectangle — a focused search field
        /// is small enough to ask for 12x, which is a microscope.
        public var maximumFocusScale: Double
        /// Whether bringing a whole window forward is a reason to zoom. Off: in a
        /// recording of one app it fires on every switch back, and the window usually
        /// fills the screen anyway.
        public var followsWindows: Bool
        /// Keystrokes closer together than this are one piece of typing.
        public var typingGap: Double
        /// Fewer keys than this is a shortcut, not typing.
        public var minimumKeystrokes: Int

        public init(clusterGap: Double = 2.5,
                    leadIn: Double = 0.7,
                    holdAfter: Double = 1.2,
                    minimumDuration: Double = 1.5,
                    maximumDuration: Double = 12,
                    transition: Double = ZoomRegion.defaultTransition.seconds,
                    scale: Double = 1.8,
                    spreadLimit: Double = 900,
                    followsFocus: Bool = true,
                    focusLeadIn: Double = 0.25,
                    focusHold: Double = 2.5,
                    focusFill: Double = 0.6,
                    focusCoverageLimit: Double = 0.75,
                    minimumFocusScale: Double = 1.25,
                    minimumFocusDwell: Double = 1,
                    maximumFocusScale: Double = 3,
                    followsWindows: Bool = false,
                    typingGap: Double = 1.5,
                    minimumKeystrokes: Int = 4) {
            self.clusterGap = clusterGap
            self.leadIn = leadIn
            self.holdAfter = holdAfter
            self.minimumDuration = minimumDuration
            self.maximumDuration = maximumDuration
            self.transition = max(0, transition)
            self.scale = scale
            self.spreadLimit = spreadLimit
            self.followsFocus = followsFocus
            self.focusLeadIn = focusLeadIn
            self.focusHold = focusHold
            self.focusFill = focusFill
            self.focusCoverageLimit = focusCoverageLimit
            self.minimumFocusScale = minimumFocusScale
            self.minimumFocusDwell = minimumFocusDwell
            self.maximumFocusScale = maximumFocusScale
            self.followsWindows = followsWindows
            self.typingGap = typingGap
            self.minimumKeystrokes = minimumKeystrokes
        }
    }

    public var tuning: Tuning
    /// The recorded frame in points, so a click position becomes a normalised centre.
    public var frameSize: CGSize
    /// The part of the recording the picture shows, as a fraction of it. The whole of it
    /// unless the project has been cropped.
    ///
    /// A zoom's centre is a fraction of the *picture*, which is what the renderer reads it
    /// as. Suggestions used to be worked out against the whole recording regardless, so on
    /// a cropped project every one of them was aimed beside the click it came from — and
    /// clicks in the part that had been cropped away still produced zooms.
    public var crop: CGRect
    /// Where a resized window's picture sat inside the frame — see `PictureTrack`.
    ///
    /// The renderer crops the black round a shrunk picture away and scales what is left up
    /// to fill the frame, so a click is not drawn where it was recorded but where that
    /// scaling puts it. Every click and focus rectangle goes through the same placement
    /// before it becomes a centre, or a zoom suggested during a resized stretch would be
    /// aimed at where the thing clicked *would* have been had the window not changed.
    /// Empty, it places nothing anywhere, which is every recording but those.
    public var picture: PictureTrack

    public init(frameSize: CGSize,
                crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                picture: PictureTrack = PictureTrack(),
                tuning: Tuning = Tuning()) {
        self.frameSize = frameSize
        self.picture = picture
        self.crop = crop.width > 0 && crop.height > 0 ? crop : CGRect(x: 0, y: 0, width: 1, height: 1)
        self.tuning = tuning
    }

    /// What the viewer will see, as a rectangle in the same points the sidecars hold.
    /// Everything outside it happened, but is not in the picture.
    private var recorded: CGRect {
        CGRect(x: crop.minX * frameSize.width,
               y: crop.minY * frameSize.height,
               width: crop.width * frameSize.width,
               height: crop.height * frameSize.height)
    }

    /// A place in the recording as a fraction of the picture.
    private func centre(of point: CGPoint) -> CGPoint {
        let shown = recorded
        return CGPoint(x: (point.x - shown.minX) / shown.width,
                       y: (point.y - shown.minY) / shown.height)
    }

    /// Zoom regions for a recording, in order, none overlapping.
    public func suggestions(cursor: [CursorSample],
                            input: [InputSample],
                            duration: CMTime) -> [ZoomRegion] {
        suggestions(cursor: cursor, input: input, focus: [], duration: duration)
    }

    /// Zoom regions from the clicks *and* the focus track.
    ///
    /// The two are worked out separately and reconciled at the end, rather than
    /// interleaved: a click inside a window that was just brought forward should produce
    /// one zoom aimed at the click, not two zooms arguing, and that is a decision about
    /// the finished list rather than about the order events arrived in.
    public func suggestions(cursor: [CursorSample],
                            input: [InputSample],
                            focus: [FocusSample],
                            duration: CMTime) -> [ZoomRegion] {
        guard frameSize.width > 0, frameSize.height > 0, duration.seconds > 0 else { return [] }

        var regions = clickRegions(input: input, duration: duration)
        if tuning.followsFocus {
            regions += focusRegions(focus: focus, input: input, duration: duration)
        }
        guard !regions.isEmpty else { return [] }
        return merged(regions, duration: duration)
    }

    // MARK: - Clicks

    private func clickRegions(input: [InputSample], duration: CMTime) -> [ZoomRegion] {
        let clicks: [(t: Double, point: CGPoint)] = input.compactMap { sample in
            guard case .mouseDown(let t, _, let x, let y) = sample else { return nil }
            let point = picture.place(CGPoint(x: x, y: y), at: t, in: frameSize)
            // Only what happened inside the recording.
            //
            // The pointer is watched wherever it goes, because it has to be: a recording of
            // one window still needs the pointer's path to draw it, and a click on the menu
            // bar or on a window beside the one being recorded is part of what the person
            // did. It is not part of what the *viewer* will see. Turning it into a zoom
            // aimed a hundred points off the left edge — which the framing clamp then pulls
            // to the edge, because it has to point somewhere — produces a shot of a corner
            // nothing happened in.
            guard recorded.contains(point) else { return nil }
            return (t, point)
        }
        guard !clicks.isEmpty else { return [] }

        var regions: [ZoomRegion] = []
        var cluster: [(t: Double, point: CGPoint)] = []

        func flush() {
            defer { cluster.removeAll() }
            guard let first = cluster.first, let last = cluster.last else { return }

            let xs = cluster.map(\.point.x)
            let ys = cluster.map(\.point.y)

            // Started early enough that the zoom has all but arrived when the click
            // happens, and long enough to go in, be seen, and come out: a zoom that is two
            // ramps and nothing between them is a flick, not a shot.
            let start = max(0, first.t - max(tuning.leadIn, tuning.transition * 0.9))
            let end = min(duration.seconds, last.t + tuning.holdAfter)
            let shortest = max(tuning.minimumDuration, tuning.transition * 2 + 0.8)
            let length = min(max(end - start, shortest), tuning.maximumDuration)
            guard length > 0, start < duration.seconds else { return }

            let centre = centre(of: CGPoint(x: xs.reduce(0, +) / Double(xs.count),
                                            y: ys.reduce(0, +) / Double(ys.count)))

            regions.append(ZoomRegion(start: CMTime(seconds: start, preferredTimescale: 600),
                                      duration: CMTime(seconds: min(length, duration.seconds - start),
                                                       preferredTimescale: 600),
                                      scale: tuning.scale,
                                      center: clamped(centre, forScale: tuning.scale),
                                      transition: CMTime(seconds: tuning.transition, preferredTimescale: 600),
                                      source: .click))
        }

        /// Whether a click belongs with what is already in the cluster.
        ///
        /// Time **and** place, and that pairing is the fix for a real hole. Clustering by
        /// time alone gathered a click on the left of the screen and one on the right two
        /// seconds later into a single moment, and the spread test then threw that whole
        /// cluster away — so two perfectly good clicks produced no zoom at all, and the
        /// wider apart they were the more certain it was that neither would be seen.
        ///
        /// Work spread across the screen is not "no moment", it is *several*. So a click
        /// that would stretch the cluster past the spread limit starts a new one instead of
        /// poisoning the old one, and the spread guard that used to drop clusters is now an
        /// invariant that cannot fire.
        func belongs(_ click: (t: Double, point: CGPoint)) -> Bool {
            guard let previous = cluster.last else { return true }
            guard click.t - previous.t <= tuning.clusterGap else { return false }
            let xs = cluster.map(\.point.x) + [click.point.x]
            let ys = cluster.map(\.point.y) + [click.point.y]
            let spread = max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
            return spread <= tuning.spreadLimit
        }

        for click in clicks.sorted(by: { $0.t < $1.t }) {
            if !belongs(click) { flush() }
            cluster.append(click)
        }
        flush()

        return regions
    }

    // MARK: - Focus

    /// Zooms proposed by what had focus.
    ///
    /// A focus event holds until the next one: someone who tabs into a field and types
    /// for twenty seconds wants the camera there for twenty seconds, not for the two and
    /// a half the default hold would give. The hold is only the floor, and the cap keeps
    /// a window left focused for an hour from becoming an hour-long zoom.
    private func focusRegions(focus: [FocusSample],
                              input: [InputSample],
                              duration: CMTime) -> [ZoomRegion] {
        let events = focus.filter { sample in
            switch sample.kind {
            case .field: true
            case .window, .application: tuning.followsWindows
            }
        }.sorted { $0.t < $1.t }
        guard !events.isEmpty else { return [] }

        // Every change of focus, whether or not it is worth a zoom of its own. Another
        // app coming forward is not a place to zoom to, but it is the end of the field
        // that had the caret: what is typed after it is typed somewhere else, and a
        // camera left on the field would be watching an empty box. So focus changes of
        // every kind end a hold, and cut the typing.
        let changes = focus.map(\.t).sorted()
        let typing = typingRuns(input: input, splitAt: changes)
        var regions: [ZoomRegion] = []

        for (index, event) in events.enumerated() {
            // The part of it that is in the recording, for the same reason clicks are
            // filtered. A window recording watches the frontmost window, which is not
            // always the window being recorded: focus landing in another app reports a
            // rectangle somewhere else entirely, and aiming at it frames nothing.
            let visible = picture.place(event.rect, at: event.t, in: frameSize).intersection(recorded)
            guard !visible.isNull, visible.width > 1, visible.height > 1,
                  let scale = scale(toFit: visible) else { continue }

            let start = max(0, event.t - tuning.focusLeadIn)
            guard start < duration.seconds else { continue }

            // However long focus stayed here, bounded by the next event — and by the
            // next event's own lead-in, so one focus zoom never runs into the start of
            // the next. Two of them overlapping would be merged into a single zoom
            // aimed between the two things, which is a zoom onto neither.
            let nextEvent = changes.first { $0 > event.t } ?? duration.seconds
            let nextStart = min(nextEvent,
                                index + 1 < events.count ? events[index + 1].t - tuning.focusLeadIn : duration.seconds)
            // Typing that started while this had focus keeps the camera until it stops.
            let typedUntil = typing
                .filter { $0.start >= event.t && $0.start < nextEvent }
                .map(\.end)
                .max()

            let held = max(event.t + tuning.focusHold, typedUntil.map { $0 + tuning.holdAfter } ?? 0)
            let end = min(duration.seconds, min(held, nextStart))
            let length = min(end - start, tuning.maximumDuration)
            // Short because focus moved on, or because the recording ended: either way
            // this is somewhere focus passed through rather than somewhere it went.
            guard length >= tuning.minimumFocusDwell else { continue }

            let centre = centre(of: CGPoint(x: visible.midX, y: visible.midY))
            let source: ZoomRegion.Source = switch event.kind {
            case .field: typedUntil != nil ? .typing : .field
            case .window: .window
            case .application: .application
            }

            regions.append(ZoomRegion(start: CMTime(seconds: start, preferredTimescale: 600),
                                      duration: CMTime(seconds: min(length, duration.seconds - start),
                                                       preferredTimescale: 600),
                                      scale: scale,
                                      center: clamped(centre, forScale: scale),
                                      transition: CMTime(seconds: tuning.transition, preferredTimescale: 600),
                                      // A field does not move while it has focus, and a
                                      // camera drifting after the pointer while someone
                                      // types is seasickness.
                                      followsCursor: false,
                                      source: source))
        }
        return regions
    }

    /// How far in to go so a rectangle fills `focusFill` of the frame.
    ///
    /// The smaller of the two axes wins: fitting a wide, short text field by its height
    /// would ask for twenty times magnification and show four characters of it.
    /// `nil` when the thing is already most of the picture, or when the move would be
    /// too small to be worth making.
    private func scale(toFit rect: CGRect) -> Double? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        let shown = recorded.size
        let coverage = max(rect.width / shown.width, rect.height / shown.height)
        guard coverage <= tuning.focusCoverageLimit else { return nil }

        let fit = min((shown.width * tuning.focusFill) / rect.width,
                      (shown.height * tuning.focusFill) / rect.height)
        let scale = min(fit, tuning.maximumFocusScale)
        return scale >= tuning.minimumFocusScale ? scale : nil
    }

    /// Stretches of continuous typing, as start and end times.
    ///
    /// `Typing.bursts` is the rule; this only puts it in the suggester's units. Read from
    /// the identity-less presses, which is all that typing ever is in a recording — a
    /// shortcut is someone operating the app, not writing in it.
    private func typingRuns(input: [InputSample], splitAt boundaries: [Double] = []) -> [(start: Double, end: Double)] {
        Typing.bursts(in: input,
                      gap: tuning.typingGap,
                      minimumPresses: tuning.minimumKeystrokes,
                      splitAt: boundaries)
            .map { ($0.start, $0.end) }
    }

    // MARK: - Reconciling

    /// A centre a zoom of this depth can actually be pointed at.
    ///
    /// Edge-aware framing, and it used to be missing. A click near the top of the screen
    /// gave a centre near the top of the frame, and a 1.8× shot around it reaches a quarter
    /// of the frame's height above the picture — so the zoom was aimed partly at nothing.
    /// The renderer refused to go there, clamping the camera at the last moment, but the
    /// zoom on the timeline still *said* it pointed off the edge: the inspector showed that
    /// centre, the framing box on the preview was drawn there, and aiming one by hand
    /// started from a rectangle hanging off the picture.
    ///
    /// Clamping here instead means what is stored is what will be shown. A click in the
    /// corner becomes a shot of the corner — the whole corner, pulled inside the frame —
    /// rather than a shot half off it.
    private func clamped(_ point: CGPoint, forScale scale: Double) -> CGPoint {
        ZoomFraming.honoured(center: point, scale: scale)
    }

    /// Two suggestions that overlap are one suggestion.
    ///
    /// Overlapping zooms would fight over the camera, and the second would start from
    /// wherever the first had got to — which looks like a mistake, because it is one.
    ///
    /// Where the two disagree about *what* to look at, the more specific one wins
    /// outright rather than being averaged with the other: the midpoint of a text field
    /// and the window around it is a point on neither. Two of equal specificity — two
    /// click clusters, say — are averaged, because then the midpoint really is the
    /// middle of the work.
    /// Whether two regions are about places far enough apart that averaging them would
    /// point at neither.
    ///
    /// Asked geometrically — is one's aim outside the other's shot? — rather than as a
    /// distance in points. A fixed distance cannot answer it: the same gap is two separate
    /// moments at 3× and comfortably one shot at 1.2×, and it is measured on centres that
    /// have already been pulled inside the picture by `clamped(_:forScale:)`, so two clicks
    /// at opposite edges of the screen end up closer together than they were clicked.
    ///
    /// The shot each one would actually show is the thing that decides it, which is the
    /// question that was being asked all along.
    private func apart(_ a: ZoomRegion, _ b: ZoomRegion) -> Bool {
        guard (a.source ?? .manual).specificity == (b.source ?? .manual).specificity else { return false }
        let reach = min(0.5 / max(1, a.scale), 0.5 / max(1, b.scale))
        return abs(a.center.x - b.center.x) > reach || abs(a.center.y - b.center.y) > reach
    }

    /// The earlier region, ending where the later one begins — or `nil` when that would
    /// leave too little of it to be worth going to.
    ///
    /// "Worth going to" is a zoom long enough to arrive: its ramp in and a moment held. A
    /// region shorter than that spends the whole of itself moving and never reaches the
    /// thing it was pointed at, so the camera would visit a place it never actually
    /// showed. That is the difference between two moments and a flail — clicks half a
    /// second apart at opposite corners cannot be split into anything watchable, and a
    /// camera that visits three places in a second is worse than one that visits none.
    /// Below the floor they merge instead.
    ///
    /// One ramp and a moment held, not two ramps: the zoom it is trimmed against starts
    /// straight after, and the camera glides on to it rather than pulling all the way out.
    /// Counted as two ramps it grew with the zoom speed until clicks two seconds apart at
    /// opposite ends of the screen merged into one shot of neither.
    private var shortestWorthGoingTo: Double { tuning.transition + 0.8 }

    private func abutted(_ region: ZoomRegion, before next: ZoomRegion) -> ZoomRegion? {
        var trimmed = region
        trimmed.duration = next.start - region.start
        guard trimmed.duration.seconds >= shortestWorthGoingTo else { return nil }
        return trimmed
    }

    private func merged(_ regions: [ZoomRegion], duration: CMTime) -> [ZoomRegion] {
        var result: [ZoomRegion] = []
        for region in regions.sorted(by: { $0.start < $1.start }) {
            guard var last = result.last, region.start < last.end else {
                result.append(region)
                continue
            }

            // Two moments in two different places stay two moments.
            //
            // Overlapping regions of equal standing used to be merged and their centres
            // averaged, which is right for two clicks on the same button and wrong for two
            // clicks at opposite ends of the screen: the average is a point nobody clicked,
            // so the camera frames neither of them. Where the two are further apart than a
            // single moment is allowed to be, the earlier one gives way at the later one's
            // start instead — both survive, each pointed at what it was about.
            if apart(last, region), let trimmed = abutted(last, before: region) {
                result[result.count - 1] = trimmed
                result.append(region)
                continue
            }

            let end = max(last.end, region.end)
            last.duration = min(end, duration) - last.start

            let mine = (last.source ?? .manual).specificity
            let theirs = (region.source ?? .manual).specificity
            if theirs > mine {
                last.center = region.center
                last.scale = region.scale
                last.followsCursor = region.followsCursor
                last.source = region.source
            } else if theirs == mine {
                // Averaged when the two are about the same place, which is what makes a
                // cluster a cluster. Where they are far apart — the flail that could not be
                // split because the pieces would have been too short — the *later* one
                // wins: the midpoint of two corners is a point nobody clicked, and where
                // somebody ended up is a better guess than where nobody went.
                if apart(last, region) {
                    last.center = region.center
                    last.scale = region.scale
                    last.followsCursor = region.followsCursor
                } else {
                    last.center = CGPoint(x: (last.center.x + region.center.x) / 2,
                                          y: (last.center.y + region.center.y) / 2)
                }
            }
            result[result.count - 1] = last
        }
        return result
    }
}

public extension Timeline {
    /// Suggested zooms, read off the recording, put where their moments now are in the edit.
    ///
    /// The suggester reads the recording, so what it proposes is in the recording's time.
    /// Placed as it came, every zoom after a cut, a speed change, a freeze frame or a title
    /// landed on the wrong moment. Each goes to the longest piece of footage that shows its
    /// moment — one zoom per moment, as the suggester meant, even where footage is shown
    /// twice or a cut splits it — and one whose moment was cut down to a sliver goes.
    func placedOnTimeline(_ zooms: [ZoomRegion], shortest: Double = 0.5) -> [ZoomRegion] {
        zooms.compactMap { zoom in
            let pieces = timelineRanges(ofSource: zoom.start.seconds...zoom.end.seconds)
            guard let piece = pieces.max(by: { $0.duration < $1.duration }),
                  piece.duration.seconds >= shortest else { return nil }
            var placed = zoom
            placed.start = piece.start
            placed.duration = piece.duration
            return placed
        }
    }
}
