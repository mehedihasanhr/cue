import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// Reducing a recording's sound to something drawable — and surviving a cache file that
/// is not what it claims to be.
struct WaveformTests {
    private func finest(_ values: [(Float, Float)], binsPerSecond: Double = 200) -> WaveformPeaks.Level {
        .init(binsPerSecond: binsPerSecond, minimums: values.map(\.0), maximums: values.map(\.1))
    }

    private func ramp(_ count: Int) -> WaveformPeaks.Level {
        finest((0..<count).map { (Float(-$0) / Float(count), Float($0) / Float(count)) })
    }

    // MARK: - The mipmap

    @Test func eachLevelIsTheOneBeforeItHalved() throws {
        let peaks = WaveformPeaks(duration: 4, finest: ramp(800))
        #expect(peaks.levels.count == 4)

        for (coarse, fine) in zip(peaks.levels.dropFirst(), peaks.levels) {
            #expect(coarse.binsPerSecond == fine.binsPerSecond / 2)
            #expect(coarse.count == (fine.count + 1) / 2)
            // A bin must span both of the bins it replaced, not average them: an
            // averaged waveform loses exactly the transients it is drawn to show.
            let first = try #require(coarse.maximums.first)
            #expect(first == max(fine.maximums[0], fine.maximums[1]))
            #expect(coarse.minimums[0] == min(fine.minimums[0], fine.minimums[1]))
        }
    }

    @Test func aLevelIsPickedWithEnoughBinsToDrawWithButNotAbsurdlyMany() throws {
        let peaks = WaveformPeaks(duration: 60, finest: ramp(12_000))   // 200 bins/s
        for pointsPerSecond in [1.0, 4, 20, 100, 400, 600] {
            let level = try #require(peaks.level(forPointsPerSecond: pointsPerSecond))
            let perColumn = level.binsPerSecond / pointsPerSecond

            #expect(perColumn <= 64, "reading dozens of bins per column is work nobody can see")
            if level.binsPerSecond < WaveformBuilder.finestBinsPerSecond {
                #expect(perColumn >= 1, "a coarser level was only chosen because it still covers every column")
            }
        }
        // Past the finest resolution there is nothing better to offer, and the columns
        // simply repeat rather than inventing detail.
        #expect(peaks.level(forPointsPerSecond: 10_000)?.binsPerSecond == WaveformBuilder.finestBinsPerSecond)
    }

    // MARK: - Drawing

    @Test func columnsComeBackExactlyAsManyAsAreAskedFor() {
        let peaks = WaveformPeaks(duration: 10, finest: ramp(2_000))
        #expect(peaks.columns(from: 0, to: 10, count: 400).count == 400)
        #expect(peaks.columns(from: 3, to: 4, count: 37).count == 37)
    }

    @Test func aZeroLengthStretchIsSilentRatherThanACrash() {
        let peaks = WaveformPeaks(duration: 10, finest: ramp(2_000))
        let columns = peaks.columns(from: 5, to: 5, count: 10)
        #expect(columns.count == 10)
    }

    @Test func askingPastTheEndOfTheSoundIsSilence() {
        let peaks = WaveformPeaks(duration: 2, finest: ramp(400))
        let columns = peaks.columns(from: 10, to: 12, count: 20)
        #expect(columns.allSatisfy { $0.min == 0 && $0.max == 0 })
    }

    @Test func askingForMoreColumnsThanThereAreBinsRepeatsRatherThanTraps() {
        let peaks = WaveformPeaks(duration: 0.05, finest: finest([(-0.5, 0.5), (-0.2, 0.2)]))
        let columns = peaks.columns(from: 0, to: 0.05, count: 200)
        #expect(columns.count == 200)
    }

    @Test func emptyPeaksDrawAsSilence() {
        let peaks = WaveformPeaks(duration: 5, finest: finest([]))
        #expect(peaks.isEmpty)
        #expect(peaks.columns(from: 0, to: 5, count: 8).allSatisfy { $0.max == 0 })
    }

    // MARK: - The cache file

    private let size: UInt64 = 12_345
    private let modified = 700_000.0

    @Test func aCacheFileRoundTripsExactly() throws {
        let peaks = WaveformPeaks(duration: 3.25, finest: ramp(650))
        let data = WaveformPeaks.Cache.encode(peaks, sourceSize: size, sourceModified: modified)
        let decoded = try #require(WaveformPeaks.Cache.decode(data, sourceSize: size, sourceModified: modified))

        #expect(decoded.duration == peaks.duration)
        #expect(decoded.levels.count == peaks.levels.count)
        for (a, b) in zip(decoded.levels, peaks.levels) {
            #expect(a.binsPerSecond == b.binsPerSecond)
            #expect(a.minimums == b.minimums)
            #expect(a.maximums == b.maximums)
        }
    }

    @Test func aCacheForDifferentFootageIsRefused() {
        let data = WaveformPeaks.Cache.encode(WaveformPeaks(duration: 1, finest: ramp(200)),
                                              sourceSize: size, sourceModified: modified)
        #expect(WaveformPeaks.Cache.decode(data, sourceSize: size + 1, sourceModified: modified) == nil)
        #expect(WaveformPeaks.Cache.decode(data, sourceSize: size, sourceModified: modified + 500) == nil)
    }

    @Test func rubbishIsRefusedRatherThanTrusted() {
        #expect(WaveformPeaks.Cache.decode(Data(), sourceSize: size, sourceModified: modified) == nil)
        #expect(WaveformPeaks.Cache.decode(Data("not a waveform at all".utf8),
                                           sourceSize: size, sourceModified: modified) == nil)
    }

    @Test func aFileTruncatedByACrashIsRefusedAtEveryLength() {
        let data = WaveformPeaks.Cache.encode(WaveformPeaks(duration: 2, finest: ramp(400)),
                                              sourceSize: size, sourceModified: modified)
        // Every prefix but the whole thing must come back nil, and none may trap.
        for length in stride(from: 0, to: data.count, by: 37) {
            #expect(WaveformPeaks.Cache.decode(data.prefix(length), sourceSize: size, sourceModified: modified) == nil)
        }
    }

    // MARK: - One cache file per sound

    /// The recording stopped being the only sound in a project the moment music and
    /// voiceovers got waveforms of their own, so the cache needed a name per sound rather
    /// than one file called `peaks.bin`.
    @Test func eachSoundGetsACacheFileOfItsOwn() {
        let package = RecordingPackage(url: URL(fileURLWithPath: "/tmp/nowhere.klik"))
        let recording = WaveformBuilder.cacheURL(in: package)
        let music = WaveformBuilder.cacheURL(in: package, key: WaveformBuilder.key(forPath: "Audio/music.m4a"))
        let voice = WaveformBuilder.cacheURL(in: package, key: WaveformBuilder.key(forPath: "Audio/voice.m4a"))

        #expect(recording.lastPathComponent == "peaks.bin", "the recording keeps the name it always had")
        #expect(music != recording)
        #expect(music != voice)
    }

    /// Two regions naming the same file share one waveform, which is what should happen
    /// when the same music is laid down twice — and a key derived by substituting the
    /// awkward characters out of a path would not guarantee it.
    @Test func theSameFileHasTheSameKeyWhereverItIsNamed() {
        #expect(WaveformBuilder.key(forPath: "Audio/music.m4a")
                == WaveformBuilder.key(forPath: "Audio/music.m4a"))
        #expect(WaveformBuilder.key(forPath: "Audio/a b/music.m4a")
                != WaveformBuilder.key(forPath: "Audio/a-b/music.m4a"))
    }

    /// A key has to be usable as a filename whatever the path was, since that is the only
    /// thing it is for.
    @Test func aKeyIsSomethingAFileCanBeCalled() {
        for path in ["Audio/music.m4a", "a/b/c/d e f.wav", "../odd/../name.aiff", ""] {
            let key = WaveformBuilder.key(forPath: path)
            #expect(!key.isEmpty)
            #expect(!key.contains("/"))
            #expect(!key.contains("."))
        }
    }
}
