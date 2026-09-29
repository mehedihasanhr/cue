import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// ProRes 422 and 4444: what the settings mean, and that a real file comes out at the
/// size, rate and length asked for, with its sound.
@Suite("ProRes export", .serialized, .timeLimit(.minutes(3)))
struct ProResExportTests {
    private func time(_ seconds: Double) -> CMTime { DressingFixtures.time(seconds) }

    // MARK: - Settings

    @Test("Both ProRes formats are MOV files, written by their own codec whatever was chosen before")
    func proResIsAMovie() {
        for format in [ExportFormat.proRes422, .proRes4444] {
            #expect(format.fileExtension == "mov")
            #expect(format.fileType == .mov)
            #expect(format.carriesAudio)
            #expect(format.isProRes)
            #expect(!format.offersCodecChoice)
            for codec in ExportCodec.allCases {
                #expect(codec.resolved(for: format) == (format == .proRes422 ? .proRes422 : .proRes4444))
            }
        }
        #expect(ExportFormat.mov.fileExtension == "mov")
        #expect(ExportFormat.mp4.fileExtension == "mp4", "the old formats keep their names")
        #expect(ExportFormat.gif.fileExtension == "gif")
    }

    @Test("Only ProRes 4444 and HEVC with transparency in a MOV keep a see-through background")
    func whichFormatsKeepAlpha() {
        #expect(ExportSettings(format: .proRes4444).keepsTransparency)
        #expect(!ExportSettings(format: .proRes422).keepsTransparency)
        #expect(ExportSettings(format: .mov, codec: .hevcWithAlpha).keepsTransparency)
        #expect(!ExportSettings(format: .mp4, codec: .hevcWithAlpha).keepsTransparency,
                "an MP4 cannot hold HEVC with alpha, so it is written as plain HEVC")
        #expect(ExportCodec.hevcWithAlpha.resolved(for: .mp4) == .hevc)
        #expect(!ExportSettings(format: .mp4).keepsTransparency)
        #expect(!ExportSettings(format: .gif).keepsTransparency)
        #expect(ExportCodec.choices(for: .mov).contains(.hevcWithAlpha))
        #expect(!ExportCodec.choices(for: .mp4).contains(.hevcWithAlpha))
    }

    @Test("ProRes is estimated as a guess, and 4444 as bigger than 422")
    func estimate() {
        let size = CGSize(width: 1_920, height: 1_080)
        let four22 = ExportSettings(format: .proRes422, frameRate: 30).estimate(projectSize: size, duration: 10)
        let four444 = ExportSettings(format: .proRes4444, frameRate: 30).estimate(projectSize: size, duration: 10)
        #expect(four22.isApproximate && four444.isApproximate)
        #expect(four444.byteCount > four22.byteCount)
        // Apple's figure for 1080p30 422 is about 147 Mb/s: ten seconds is near 180 MB.
        #expect((150_000_000...230_000_000).contains(four22.byteCount))
    }

    @Test("A ProRes preset would never be mistaken for one of the four errands")
    func noPresetMatchesProRes() {
        #expect(ExportPreset.matching(ExportSettings(format: .proRes422)) == nil)
        #expect(ExportPreset.matching(ExportSettings(format: .proRes4444)) == nil)
    }

    // MARK: - Files

    private func export(format: ExportFormat, frameRate: Int, seconds: Double,
                        cap: Double?, withSound: Bool) async throws -> (folder: URL, file: URL) {
        let folder = try ExportTests.scratch()
        let source = folder.appendingPathComponent("source.mov")
        let size = CGSize(width: 640, height: 360)
        try await ExportTests.writeVideoWithTone(to: source, size: size,
                                                 frames: Int(seconds * 30), frameRate: 30)
        var timeline = Timeline(sourceDuration: time(seconds))
        timeline.style.background = .color(ColorValue(r: 0.1, g: 0.1, b: 0.2))
        timeline.zooms = [ZoomRegion(start: time(0.2), duration: time(0.5), scale: 1.6)]
        var settings = ExportSettings(format: format, frameRate: frameRate, includesAudio: withSound)
        settings.maximumDimension = cap
        let exporter = VideoExporter(timeline: timeline,
                                     builder: SceneBuilder(videoSize: size),
                                     cursor: nil,
                                     videoURL: source,
                                     packageURL: folder,
                                     settings: settings)
        let destination = folder.appendingPathComponent("out.\(format.fileExtension)")
        try await exporter.export(to: destination)
        return (folder, destination)
    }

    private func codecType(of track: AVAssetTrack) async throws -> FourCharCode? {
        let descriptions = try await track.load(.formatDescriptions)
        return descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) }
    }

    @Test("ProRes 422 comes out at the size, rate and length asked for, with its sound",
          .timeLimit(.minutes(2)))
    func proRes422File() async throws {
        let (folder, file) = try await export(format: .proRes422, frameRate: 30, seconds: 1,
                                              cap: 320, withSound: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let asset = AVURLAsset(url: file)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await codecType(of: video) == kCMVideoCodecType_AppleProRes422)
        let size = try await video.load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 180))
        #expect(abs(try await video.load(.nominalFrameRate) - 30) < 0.5)
        #expect(abs(try await asset.load(.duration).seconds - 1) < 0.1)

        let sound = try #require(try await asset.loadTracks(withMediaType: .audio).first, "the sound came too")
        let audioDescriptions = try await sound.load(.formatDescriptions)
        let format = try #require(audioDescriptions.first.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        })
        #expect(format.mFormatID == kAudioFormatLinearPCM, "uncompressed beside ProRes, for editing")
        #expect(format.mBitsPerChannel == 24)
        #expect(abs(try await sound.load(.timeRange).duration.seconds - 1) < 0.1)
    }

    @Test("ProRes 4444 comes out at the size, rate and length asked for", .timeLimit(.minutes(2)))
    func proRes4444File() async throws {
        let (folder, file) = try await export(format: .proRes4444, frameRate: 24, seconds: 1.5,
                                              cap: nil, withSound: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let asset = AVURLAsset(url: file)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await codecType(of: video) == kCMVideoCodecType_AppleProRes4444)
        #expect(try await video.load(.naturalSize) == CGSize(width: 640, height: 360))
        #expect(abs(try await video.load(.nominalFrameRate) - 24) < 0.5)
        #expect(abs(try await asset.load(.duration).seconds - 1.5) < 0.1)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty, "no sound was asked for")
    }
}
