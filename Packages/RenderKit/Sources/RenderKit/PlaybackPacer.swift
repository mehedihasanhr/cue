import Foundation

/// When a playing frame goes on screen, and which moment of the video it shows.
///
/// A camera moving smoothly through the video only looks smooth if each frame on screen is
/// as far along it as the time since the last one says. Frames take a different time to draw
/// and the sound's clock moves in uneven steps, so showing each frame when it was ready, of
/// wherever the clock said, stepped unevenly: measured, 502, then 769, then 517 points a
/// second across a pan that was perfectly even in the model. That is seen as shaking.
///
/// So frames go on a fixed beat, a whole number of screen refreshes apart, slow enough that
/// they are ready in time, and each shows exactly one beat more of the video than the last.
/// The clock is still the authority: any drift from it is worked off a little per frame, and
/// a real jump, a seek or a stall, is simply followed.
public struct PlaybackPacer: Sendable {
    /// The beats on offer, in seconds: 60, 30, 20 and 15 frames a second. Whole numbers of
    /// refreshes of a 60 or 120 Hz screen, so a beat falls at the same point of a refresh.
    static let beats: [Double] = [1.0 / 60, 1.0 / 30, 1.0 / 20, 1.0 / 15]
    /// The furthest ahead a frame is ever aimed: a stall must not have every later frame
    /// drawn for a moment far in the future.
    public static let longestLead = 0.15
    /// Time in hand on top of what frames have been taking, so an ordinary frame is early.
    static let margin = 0.005
    /// How far from the clock is drift to be worked off, rather than a jump to follow.
    static let driftLimit = 0.05
    /// How much of the drift goes per frame: too little to see, soon enough to stay with
    /// the sound.
    static let driftPull = 0.1

    /// How long before it must start a frame may be started: one tick of the player's
    /// clock, or it might miss its beat waiting for the next tick.
    static let startWindow = 1.0 / 60

    private var beatIndex = 0
    private var lastDue: Double?
    private var lastMoment: Double?

    public init() {}

    /// The beat in use, in seconds.
    public var beat: Double { Self.beats[beatIndex] }

    /// Picks the next frame.
    ///
    /// - Parameters:
    ///   - now: the time on the clock `due` is measured on, in seconds.
    ///   - drawCost: how long frames have lately taken to be ready on average, in seconds.
    ///   - slowest: how long the slowest of them took, in seconds. Frames are started this
    ///     long before their beat, so all but the rare one are ready in time.
    ///   - playhead: where the playback clock says the video is now, in seconds.
    ///   - rate: how fast the video is playing: 1 is normal, negative is backwards.
    /// - Returns: when to show the frame and the moment of the video to draw for it, or `nil`
    ///   when it is too soon to start one: it would only sit finished, showing a moment
    ///   decided early. The player asks again on its next tick.
    public mutating func next(now: Double, drawCost: Double, slowest: Double? = nil, playhead: Double,
                              rate: Double) -> (due: Double, moment: Double)? {
        chooseBeat(for: drawCost)
        let wanted = now + min(Self.longestLead, max(drawCost, slowest ?? drawCost) + Self.margin)
        // What it must have to make a beat at all. A frame a little late is shown a little
        // late; missing the beat instead leaves a hole a whole beat long, which is far worse:
        // measured, skipping at the first sign of lateness took playback from 30 frames a
        // second to 21.
        let possible = now + min(Self.longestLead, drawCost) - beat / 2

        var due = wanted
        if let lastDue {
            due = lastDue + beat
            if due < possible { due = lastDue + ((possible - lastDue) / beat).rounded(.up) * beat }
            if due - wanted > Self.startWindow { return nil }
        }

        let ideal = playhead + (due - now) * rate
        var moment = ideal
        if let lastDue, let lastMoment {
            let even = lastMoment + (due - lastDue) * rate
            let drift = ideal - even
            if abs(drift) <= Self.driftLimit { moment = even + drift * Self.driftPull }
        }
        lastDue = due
        lastMoment = moment
        return (due, moment)
    }

    /// The fastest beat frames can keep. Slower at once when they cannot keep it, and
    /// faster only when there is room, so it does not hunt between the two.
    private mutating func chooseBeat(for cost: Double) {
        while beatIndex + 1 < Self.beats.count, cost > beat * 1.15 { beatIndex += 1 }
        while beatIndex > 0, cost < Self.beats[beatIndex - 1] * 0.9 { beatIndex -= 1 }
    }
}
