import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import RecordKit

/// A project made from a movie that was not recorded here.
struct MovieProjectTests {
    /// The sound stays in the movie, and the manifest says so by naming the same file for
    /// both — the shape the editor reads as "the sound is in the picture".
    @Test func aMovieWithSoundNamesItsOwnFileForBoth() {
        let manifest = MovieProject.manifest(name: "Demo", path: "media/screen.mov", duration: 12,
                                             pixelSize: CGSize(width: 1920, height: 1080),
                                             frameRate: 29.97, codec: "avc1", hasSound: true)
        #expect(manifest.track(.screen)?.path == "media/screen.mov")
        #expect(manifest.audioTracks.map(\.path) == ["media/screen.mov"])
        #expect(manifest.track(.screen)?.frameRate == 30)
        #expect(manifest.displayScale == 1)
        #expect(manifest.sourceRect == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(manifest.telemetry.cursor == nil)
    }

    @Test func aSilentMovieHasNoSound() {
        let manifest = MovieProject.manifest(name: "Demo", path: "media/screen.mp4", duration: 3,
                                             pixelSize: CGSize(width: 640, height: 480),
                                             frameRate: 0, codec: nil, hasSound: false)
        #expect(manifest.audioTracks.isEmpty)
        // A movie that does not say its rate is given an ordinary one rather than zero.
        #expect(manifest.track(.screen)?.frameRate == 30)
    }

    /// A phone video is often stored landscape with a quarter turn in its transform.
    @Test func aRotatedMovieIsMeasuredTheWayItIsShown() {
        let size = MovieProject.displayedSize(CGSize(width: 1920, height: 1080),
                                              CGAffineTransform(rotationAngle: .pi / 2))
        #expect(size == CGSize(width: 1080, height: 1920))
    }

    @Test func aFileWithNoVideoIsRefusedAndLeavesNothingBehind() async throws {
        let folder = URL.temporaryDirectory.appending(path: "MovieProjectTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let notAMovie = folder.appending(path: "notes.mov")
        try Data("not a movie".utf8).write(to: notAMovie)

        await #expect(throws: (any Error).self) {
            _ = try await MovieProject.create(from: notAMovie, in: folder.appending(path: "Projects"))
        }
        let made = (try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Projects").path)) ?? []
        #expect(made.isEmpty)
    }

    /// A real movie, end to end: copied in, measured, and the package readable.
    @Test func aRealMovieBecomesAProject() async throws {
        let folder = URL.temporaryDirectory.appending(path: "MovieProjectTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let movie = folder.appending(path: "Clip.mov")
        try await writeMovie(to: movie, size: CGSize(width: 320, height: 240), frames: 30)

        let package = try await MovieProject.create(from: movie, in: folder.appending(path: "Projects"))
        let manifest = try package.readManifest()
        #expect(package.url.lastPathComponent == "Clip.cuerec")
        #expect(manifest.track(.screen)?.pixelSize == CGSize(width: 320, height: 240))
        #expect(manifest.audioTracks.isEmpty)
        #expect(abs(manifest.duration - 1) < 0.1)
        let copy = package.url.appending(path: manifest.track(.screen)!.path)
        #expect(FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
    }

    private func writeMovie(to url: URL, size: CGSize, frames: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
