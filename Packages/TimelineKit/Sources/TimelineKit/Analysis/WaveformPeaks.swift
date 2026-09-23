import Foundation

/// The shape of a recording's sound, at every zoom the timeline can be at.
///
/// A mipmap rather than one array of peaks. Drawn from the finest level alone, a fully
/// zoomed-out hour would mean reducing seven hundred thousand bins for every column, on
/// every playhead tick. Each level is a pairwise reduction of the one before it, so the
/// drawing code picks a level with one to four bins per column and the work becomes
/// proportional to the width of the row instead of the length of the recording.
public struct WaveformPeaks: Sendable, Equatable {
    public struct Level: Sendable, Equatable {
        public let binsPerSecond: Double
        /// The lowest sample in each bin, −1…0.
        public let minimums: [Float]
        /// The highest sample in each bin, 0…1.
        public let maximums: [Float]

        public init(binsPerSecond: Double, minimums: [Float], maximums: [Float]) {
            self.binsPerSecond = binsPerSecond
            self.minimums = minimums
            self.maximums = maximums
        }

        public var count: Int { min(minimums.count, maximums.count) }

        /// Halves the resolution: two bins become one that spans both.
        func halved() -> Level {
            var mins: [Float] = []
            var maxes: [Float] = []
            mins.reserveCapacity((count + 1) / 2)
            maxes.reserveCapacity((count + 1) / 2)
            var index = 0
            while index < count {
                let next = min(index + 1, count - 1)
                mins.append(Swift.min(minimums[index], minimums[next]))
                maxes.append(Swift.max(maximums[index], maximums[next]))
                index += 2
            }
            return Level(binsPerSecond: binsPerSecond / 2, minimums: mins, maximums: maxes)
        }
    }

    public let duration: Double
    /// Finest first.
    public let levels: [Level]

    public init(duration: Double, levels: [Level]) {
        self.duration = duration
        self.levels = levels
    }

    /// Builds the coarser levels from the finest one.
    public init(duration: Double, finest: Level, levelCount: Int = 4) {
        var levels = [finest]
        while levels.count < levelCount, let last = levels.last, last.count > 2 {
            levels.append(last.halved())
        }
        self.init(duration: duration, levels: levels)
    }

    public var isEmpty: Bool { levels.allSatisfy { $0.count == 0 } }

    /// The coarsest level that still has at least one bin per drawn column.
    ///
    /// Reading more than about four bins per column is work nobody can see; reading fewer
    /// than one makes the waveform step instead of flow.
    public func level(forPointsPerSecond pointsPerSecond: Double) -> Level? {
        guard let finest = levels.first else { return nil }
        var chosen = finest
        for level in levels {
            if level.binsPerSecond >= pointsPerSecond { chosen = level } else { break }
        }
        return chosen
    }

    /// `count` min/max pairs covering `from`…`to` seconds.
    ///
    /// Tolerant on purpose: a clip can ask for a stretch past the end of the sound (a
    /// recording whose audio stopped early), for a zero-length stretch, or for more
    /// columns than there are bins. All three are ordinary and none of them may trap.
    public func columns(from: Double, to: Double, count: Int, pointsPerSecond: Double? = nil) -> [(min: Float, max: Float)] {
        guard count > 0 else { return [] }
        let span = max(0, to - from)
        let perSecond = pointsPerSecond ?? (span > 0 ? Double(count) / span : 1)
        guard let level = level(forPointsPerSecond: perSecond), level.count > 0 else {
            return Array(repeating: (min: Float(0), max: Float(0)), count: count)
        }

        var columns: [(min: Float, max: Float)] = []
        columns.reserveCapacity(count)
        for column in 0..<count {
            let progress = Double(column) / Double(count)
            let nextProgress = Double(column + 1) / Double(count)
            let startBin = Int(((from + span * progress) * level.binsPerSecond).rounded(.down))
            let endBin = Int(((from + span * nextProgress) * level.binsPerSecond).rounded(.up))

            var low: Float = 0
            var high: Float = 0
            // Clamped from both ends: a clip can ask for a stretch that starts past the
            // end of the sound, and an empty range is silence rather than a trap.
            let first = Swift.max(0, Swift.min(startBin, level.count))
            let last = Swift.max(first, Swift.min(level.count, Swift.max(startBin + 1, endBin)))
            for bin in first..<last {
                low = Swift.min(low, level.minimums[bin])
                high = Swift.max(high, level.maximums[bin])
            }
            columns.append((low, high))
        }
        return columns
    }
}

// MARK: - On disk

public extension WaveformPeaks {
    /// `derived/peaks.bin`: regenerable, so it is versioned and stamped rather than
    /// migrated. Anything that does not match is thrown away and built again.
    enum Cache {
        static let magic: [UInt8] = Array("KLWF".utf8)
        static let version: UInt32 = 1

        public static func encode(_ peaks: WaveformPeaks, sourceSize: UInt64, sourceModified: Double) -> Data {
            var data = Data(magic)
            data.append(contentsOf: withUnsafeBytes(of: version.littleEndian, Array.init))
            data.append(contentsOf: withUnsafeBytes(of: sourceSize.littleEndian, Array.init))
            data.append(contentsOf: withUnsafeBytes(of: sourceModified.bitPattern.littleEndian, Array.init))
            data.append(contentsOf: withUnsafeBytes(of: peaks.duration.bitPattern.littleEndian, Array.init))
            data.append(contentsOf: withUnsafeBytes(of: UInt32(peaks.levels.count).littleEndian, Array.init))
            for level in peaks.levels {
                data.append(contentsOf: withUnsafeBytes(of: level.binsPerSecond.bitPattern.littleEndian, Array.init))
                data.append(contentsOf: withUnsafeBytes(of: UInt32(level.count).littleEndian, Array.init))
                for value in level.minimums.prefix(level.count) {
                    data.append(contentsOf: withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init))
                }
                for value in level.maximums.prefix(level.count) {
                    data.append(contentsOf: withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init))
                }
            }
            return data
        }

        /// `nil` for anything that is not exactly what was written, including a file
        /// truncated by a crash. Never a trap: this is a cache, and the answer to a bad
        /// one is to build it again.
        public static func decode(_ data: Data, sourceSize: UInt64, sourceModified: Double) -> WaveformPeaks? {
            var reader = Reader(data)
            guard reader.bytes(4) == magic,
                  reader.u32() == version,
                  let storedSize = reader.u64(), storedSize == sourceSize,
                  let storedModified = reader.f64(), abs(storedModified - sourceModified) < 1,
                  let duration = reader.f64(),
                  let levelCount = reader.u32(), levelCount > 0, levelCount < 64
            else { return nil }

            var levels: [Level] = []
            for _ in 0..<levelCount {
                guard let binsPerSecond = reader.f64(), binsPerSecond > 0,
                      let count = reader.u32(), count < 100_000_000 else { return nil }
                guard let mins = reader.floats(Int(count)), let maxes = reader.floats(Int(count)) else { return nil }
                levels.append(Level(binsPerSecond: binsPerSecond, minimums: mins, maximums: maxes))
            }
            return WaveformPeaks(duration: duration, levels: levels)
        }

        private struct Reader {
            private let data: Data
            private var offset: Int
            init(_ data: Data) { self.data = data; offset = data.startIndex }

            mutating func bytes(_ count: Int) -> [UInt8]? {
                guard offset + count <= data.endIndex else { return nil }
                defer { offset += count }
                return Array(data[offset..<(offset + count)])
            }

            mutating func u32() -> UInt32? {
                bytes(4).map { $0.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
            }

            mutating func u64() -> UInt64? {
                bytes(8).map { $0.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) } }
            }

            mutating func f64() -> Double? {
                u64().map { Double(bitPattern: $0) }
            }

            mutating func floats(_ count: Int) -> [Float]? {
                guard let raw = bytes(count * 4) else { return nil }
                return raw.withUnsafeBytes { buffer in
                    (0..<count).map {
                        Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
                    }
                }
            }
        }
    }
}
