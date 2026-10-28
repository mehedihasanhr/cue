import Foundation

/// Where nobody is speaking, from a sound's waveform.
///
/// The reference's rule (docs/studio/10-motion-reference.md): the sound is read in 50 ms
/// windows, a window under a tenth of the loudest one is quiet, and a quiet stretch at
/// least `minimum` long is a silence. A tenth of the peak rather than a fixed level, so a
/// quiet microphone and a loud one find the same pauses.
public enum SilenceFinder {
    public static let window = 0.05
    public static let threshold = 0.1
    /// The camera stays until this far into a silence and is back this long before it
    /// ends, so it does not vanish mid-breath or reappear after the first word.
    public static let cameraInset = 0.5
    public static let minimumRange: ClosedRange<Double> = 2...15
    public static let defaultMinimum = 5.0

    /// The silences in `peaks`, in its own seconds, in order.
    public static func silences(in peaks: WaveformPeaks, minimum: Double) -> [ClosedRange<Double>] {
        guard let finest = peaks.levels.first, finest.count > 0, finest.binsPerSecond > 0 else { return [] }
        let perWindow = max(1, Int((window * finest.binsPerSecond).rounded()))
        var envelope: [Float] = []
        envelope.reserveCapacity(finest.count / perWindow + 1)
        var index = 0
        while index < finest.count {
            let end = min(finest.count, index + perWindow)
            var loudest: Float = 0
            for bin in index..<end {
                loudest = max(loudest, abs(finest.minimums[bin]), abs(finest.maximums[bin]))
            }
            envelope.append(loudest)
            index = end
        }
        guard let peak = envelope.max(), peak > 0 else {
            // No sound at all: the whole thing is one silence, if it is long enough.
            return peaks.duration >= minimum ? [0...peaks.duration] : []
        }
        let quiet = Float(threshold) * peak
        let seconds = Double(perWindow) / finest.binsPerSecond

        var result: [ClosedRange<Double>] = []
        var runStart: Int?
        for (index, level) in envelope.enumerated() {
            if level < quiet {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                append(start, index)
                runStart = nil
            }
        }
        if let start = runStart { append(start, envelope.count) }
        return result

        func append(_ from: Int, _ to: Int) {
            let range = (Double(from) * seconds)...min(peaks.duration, Double(to) * seconds)
            if range.upperBound - range.lowerBound >= minimum { result.append(range) }
        }
    }

    /// Where the camera is hidden for each silence: inside it by `cameraInset` at both ends.
    public static func cameraHidden(in silences: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        silences.compactMap { silence in
            let from = silence.lowerBound + cameraInset
            let to = silence.upperBound - cameraInset
            return to > from ? from...to : nil
        }
    }
}
