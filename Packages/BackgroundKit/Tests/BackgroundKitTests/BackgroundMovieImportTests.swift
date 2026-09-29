import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import BackgroundKit

/// A background movie is copied into the project, and only a movie is.
struct BackgroundMovieImportTests {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("movie-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Two frames of grey, which is all a movie needs to be one.
    private func writeMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<2 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { break }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    @Test func aMovieIsCopiedIntoTheProject() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("Loop.MOV")
        try await writeMovie(to: movie)
        let package = folder.appendingPathComponent("Take.klikrec", isDirectory: true)
        let path = try await BackgroundMovieImport.copy(movie, into: package)
        #expect(path.hasPrefix("\(BackgroundImport.folderName)/"))
        #expect(path.hasSuffix(".mov"))
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent(path).path))
    }

    @Test func somethingElseIsRefused() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("notes.mov")
        try "not a movie".write(to: text, atomically: true, encoding: .utf8)
        await #expect(throws: BackgroundMovieImport.Failure.notAMovie) {
            try await BackgroundMovieImport.copy(text, into: folder.appendingPathComponent("Take.klikrec"))
        }
    }
}
