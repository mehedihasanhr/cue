import CoreMedia

/// Where a caption written by hand goes.
public enum CaptionPlacement {
    /// How long a caption typed by hand lasts when it is first added. Long enough to read
    /// a short line; it is trimmed to suit like any other region.
    public static let typedDuration = CMTime(seconds: 3, preferredTimescale: 600)

    /// The first free stretch at or after a moment, long enough to hold a caption.
    ///
    /// With the moment inside a caption the answer is after it, the way a new line in a
    /// document goes under the line the caret is on. Putting the new one at the moment
    /// itself cuts the caption already there short — to a sliver, if the moment is near
    /// its start — which is not what anybody adding a line meant to do to the one before.
    ///
    /// A gap too short to read a caption in is passed over rather than filled.
    ///
    /// - Returns: `nil` when every moment from there to the end is spoken for.
    public static func slot(at time: CMTime,
                            among captions: [CaptionCue],
                            in duration: CMTime,
                            lasting wanted: CMTime = typedDuration) -> (start: CMTime, duration: CMTime)? {
        let ordered = captions.sorted { $0.start < $1.start }
        var start = max(.zero, time)
        // Bounded by the number of captions: each pass moves past at least one of them.
        for _ in 0...ordered.count {
            while let covering = ordered.first(where: { $0.start <= start && start < $0.end }) {
                start = covering.end
            }
            let following = ordered.first { $0.start > start }
            let limit = min(following?.start ?? duration, duration)
            let length = min(wanted, limit - start)
            if length >= Clip.minimumDuration { return (start, length) }
            guard let following else { return nil }
            start = following.end
        }
        return nil
    }
}
