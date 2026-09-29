import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// Measuring a movie on its way in, and making one movie of a take recorded to several
/// files.
///
/// One at a time: each writes movies, and a whole suite of encoders opened at once beside
/// every other suite's left all of them waiting on the hardware and none finishing.
@Suite(.serialized)
struct MediaImportTests {
    @Test func aMovieIsMeasuredForLengthSizeAndSound() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("in.mov")
        try await ImportedClipRenderTests.writeMovie(to: movie, size: CGSize(width: 90, height: 160),
                                                     colour: CIColor(red: 1, green: 0, blue: 0), seconds: 1, tone: 440)
        let measured = try await MediaImport.measure(movie)
        #expect(abs(measured.duration.seconds - 1) < 0.05)
        #expect(measured.pixelSize == CGSize(width: 90, height: 160))
        #expect(measured.hasSound)

        let silent = folder.appendingPathComponent("silent.mov")
        try await ExportTests.writeSilentVideo(to: silent, size: CGSize(width: 64, height: 36), frames: 15, frameRate: 30)
        #expect(try await MediaImport.measure(silent).hasSound == false)
    }

    @Test func aFileWithNoPictureIsRefusedWithAPointerToAddSound() async throws {
        let folder = try SynthesisedSound.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sound = folder.appendingPathComponent("tone.wav")
        var samples = [Float](repeating: 0, count: 48_000)
        SynthesisedSound.tone(&samples, frequency: 440, amplitude: 0.2)
        try SynthesisedSound.write(samples, to: sound)
        await #expect(throws: MediaImport.Failure.noPicture) { try await MediaImport.measure(sound) }
        #expect(MediaImport.Failure.noPicture.errorDescription?.contains("Add Sound") == true)
    }

    @Test func somethingThatIsNotAMovieIsUnreadable() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("notes.mov")
        try Data("not a movie".utf8).write(to: text)
        await #expect(throws: MediaImport.Failure.unreadable) { try await MediaImport.measure(text) }
    }

    /// A take's silent screen and its two sound files become one movie: the picture, and
    /// both sounds as tracks of their own, as long as the picture.
    @Test func aTakeIsCombinedIntoOneMovieWithEverySoundBesideThePicture() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = folder.appendingPathComponent("screen.mov")
        try await ExportTests.writeSilentVideo(to: screen, size: CGSize(width: 64, height: 36), frames: 30, frameRate: 30)
        var voice = [Float](repeating: 0, count: 48_000 * 2)
        SynthesisedSound.tone(&voice, frequency: 220, amplitude: 0.2)
        let microphone = folder.appendingPathComponent("microphone-1.wav")
        try SynthesisedSound.write(voice, to: microphone)
        let system = folder.appendingPathComponent("system-audio.wav")
        try SynthesisedSound.write(voice, to: system)
        let missing = folder.appendingPathComponent("gone.wav")

        let combined = folder.appendingPathComponent("take.mov")
        try await MediaImport.combine(picture: screen, sounds: [system, microphone, missing], into: combined)

        let asset = AVURLAsset(url: combined)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let sounds = try await asset.loadTracks(withMediaType: .audio)
        #expect(sounds.count == 2, "each source its own track; the missing one left out")
        for sound in sounds {
            let range = try await sound.load(.timeRange)
            #expect(range.duration.seconds <= 1.01, "held to the picture's length")
        }
        let measured = try await MediaImport.measure(combined)
        #expect(measured.hasSound)
        #expect(measured.pixelSize == CGSize(width: 64, height: 36))
    }
}
