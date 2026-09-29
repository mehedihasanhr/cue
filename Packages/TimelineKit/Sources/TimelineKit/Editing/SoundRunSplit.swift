import CoreMedia

extension SoundRun {
    /// This run in pieces at the given moments, each piece playing on from where the
    /// last stopped. Moments outside it, or too near its ends to leave a piece worth
    /// keeping, are ignored.
    func split(at moments: [CMTime]) -> [SoundRun] {
        var pieces: [SoundRun] = []
        var rest = self
        for moment in moments.sorted() {
            guard moment - rest.start >= Clip.minimumDuration,
                  rest.end - moment >= Clip.minimumDuration else { continue }
            var first = rest
            first.duration = moment - rest.start
            let played = CMTimeMultiplyByFloat64(first.duration, multiplier: rest.speed)
            let second = SoundRun(start: moment, duration: rest.end - moment,
                                  sourceStart: rest.sourceStart + played, speed: rest.speed)
            pieces.append(first)
            rest = second
        }
        pieces.append(rest)
        return pieces
    }
}
