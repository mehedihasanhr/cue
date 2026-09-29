import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// The sound of a click: what it is, and where the edit puts it.
struct ClickSoundTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("click-sounds-\(UUID().uuidString)")
    }

    private func energy(_ samples: ArraySlice<Float>) -> Double {
        samples.reduce(0) { $0 + Double($1 * $1) }
    }

    // MARK: - The sound

    @Test(arguments: CursorStyle.ClickSound.allCases)
    func itIsShortLoudEnoughAndNeverClips(_ kind: CursorStyle.ClickSound) {
        let samples = ClickSound.samples(kind)
        let length = Double(samples.count) / ClickSound.sampleRate
        #expect(length > 0.03 && length < 0.1)
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(peak > 0.4 && peak < 0.7)
    }

    /// Most of it is at the start, the way a click is, and it has died away by the end.
    @Test(arguments: CursorStyle.ClickSound.allCases)
    func itStartsAtOnceAndDiesAway(_ kind: CursorStyle.ClickSound) {
        let samples = ClickSound.samples(kind)
        let tenth = Int(ClickSound.sampleRate * 0.01)
        let start = energy(samples[0..<tenth])
        let end = energy(samples[(samples.count - tenth)...])
        #expect(start > 0)
        #expect(end < start * 0.02)
        // No step at the very first sample, which would be a click of its own.
        #expect(abs(samples[0]) < 0.01)
        #expect(abs(samples[samples.count - 1]) < 0.01)
    }

    @Test func theTwoSoundsAreDifferentAndEachIsAlwaysTheSame() {
        #expect(ClickSound.samples(.soft) != ClickSound.samples(.crisp))
        #expect(ClickSound.samples(.soft) == ClickSound.samples(.soft))
    }

    @Test func theFileIsMadeOnceAndReadsBack() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try ClickSound.file(for: .crisp, in: folder)
        let made = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        let file = try AVAudioFile(forReading: url)
        #expect(Int(file.length) == ClickSound.samples(.crisp).count)
        #expect(file.fileFormat.sampleRate == ClickSound.sampleRate)

        #expect(try ClickSound.file(for: .crisp, in: folder) == url)
        let again = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(made == again, "not written a second time")
        // Nothing left behind from the writing.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [url.lastPathComponent])
    }

    // MARK: - In the mix

    private func clicks(_ times: Double...) -> [CursorTrack.Click] {
        times.map { CursorTrack.Click(t: $0, point: CGPoint(x: 10, y: 10), isSecondary: false) }
    }

    /// Where each sound was laid, on every track, in time order.
    private func starts(_ result: AudioMixdown.Result) async throws -> [Double] {
        var starts: [Double] = []
        for track in result.composition.tracks(withMediaType: .audio) {
            for segment in try await track.load(.segments) where !segment.isEmpty {
                starts.append((segment.timeMapping.target.start.seconds * 1_000).rounded() / 1_000)
            }
        }
        return starts.sorted()
    }

    /// A timeline whose recording has no sound of its own, so every sound in the mix is
    /// a click.
    private func timeline(_ change: (inout Timeline) -> Void = { _ in }) -> Timeline {
        var timeline = Timeline(sourceDuration: time(10))
        timeline.sound.isMuted = true
        timeline.cursor.clickSound = true
        change(&timeline)
        return timeline
    }

    private let nowhere = URL(fileURLWithPath: "/nonexistent/recording.mov")

    @Test func eachClickIsHeardWhereItIsSeen() async throws {
        let edit = timeline {
            $0.clips = [Clip(sourceStart: .zero, sourceDuration: time(3)),
                        Clip(sourceStart: time(5), sourceDuration: time(5))]
        }
        let result = await AudioMixdown.build(timeline: edit, videoURL: nowhere, packageURL: nil,
                                              clicks: clicks(1, 4, 6))
        // 4 s was cut; 6 s is a second into the second clip, which starts at 3.
        #expect(try await starts(result) == [1, 4])
    }

    @Test func switchedOffThereIsNothingToHear() async throws {
        let edit = timeline { $0.cursor.clickSound = false }
        let result = await AudioMixdown.build(timeline: edit, videoURL: nowhere, packageURL: nil,
                                              clicks: clicks(1, 4))
        #expect(result.isEmpty)
    }

    @Test func aDoubleClickIsTwoClicksNotOneCutShort() async throws {
        let result = await AudioMixdown.build(timeline: timeline(), videoURL: nowhere, packageURL: nil,
                                              clicks: clicks(2, 2.05))
        #expect(try await starts(result) == [2, 2.05])
        #expect(result.composition.tracks(withMediaType: .audio).count == 2)
        for track in result.composition.tracks(withMediaType: .audio) {
            for segment in try await track.load(.segments) where !segment.isEmpty {
                #expect(segment.timeMapping.target.duration.seconds > 0.06, "each heard whole")
            }
        }
    }

    @Test func theLastClickStopsWhereTheVideoDoes() async throws {
        let result = await AudioMixdown.build(timeline: timeline(), videoURL: nowhere, packageURL: nil,
                                              clicks: clicks(9.99))
        let track = try #require(result.composition.tracks(withMediaType: .audio).first)
        let range = try await track.load(.timeRange)
        #expect(abs(range.end.seconds - 10) < 0.001)
    }

    @Test func theLevelIsTheOneChosen() async throws {
        let edit = timeline { $0.cursor.clickSoundVolume = 0.3 }
        let result = await AudioMixdown.build(timeline: edit, videoURL: nowhere, packageURL: nil,
                                              clicks: clicks(1))
        let input = try #require(result.audioMix?.inputParameters.first)
        var start: Float = -1, end: Float = -1
        var range = CMTimeRange.zero
        #expect(input.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range))
        #expect(abs(start - 0.3) < 0.001)
    }
}

/// A ring does not appear where the pointer has been hidden.
struct HiddenPointerClickTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let builder = SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000), displayScale: 2)

    private var track: CursorTrack {
        let samples = (0...1_000).map { CursorSample(t: Double($0) / 100, x: 400, y: 250, shape: .arrow) }
        return CursorTrack(samples: samples,
                           input: [.mouseDown(t: 3, button: 0, x: 400, y: 250),
                                   .mouseDown(t: 7, button: 0, x: 400, y: 250)])
    }

    @Test func aClickInsideAHiddenStretchHasNoRing() {
        var timeline = Timeline(sourceDuration: time(10))
        timeline.cursorRegions = [CursorRegion(start: time(6), duration: time(3), isHidden: true)]
        #expect(builder.descriptor(for: timeline, at: time(3.1), cursor: track).clicks.count == 1)
        #expect(builder.descriptor(for: timeline, at: time(7.1), cursor: track).clicks.isEmpty)
    }
}
