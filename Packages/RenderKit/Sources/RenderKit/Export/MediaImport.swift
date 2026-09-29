import AVFoundation
import CoreMedia
import Foundation
import TimelineKit

/// Reading a movie on its way into a project, and making one movie of another take.
///
/// Here rather than in the app so it can be tested without a window: what a file's length,
/// size and sound are measured as is what the timeline will believe about it for good —
/// see `MediaFile` — and getting it wrong is a trim that stops short or a picture fitted
/// to the wrong shape.
public enum MediaImport {
    public enum Failure: Error, Equatable, LocalizedError {
        case unreadable
        case noPicture
        case tooShort
        case couldNotCombine(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable: "That file couldn't be read as a movie."
            case .noPicture: "That file has no picture in it. To add sound, use Add Sound… in the Audio menu."
            case .tooShort: "That movie is too short to be a clip."
            case .couldNotCombine(let detail): "The recording's picture and sound couldn't be put together. \(detail)"
            }
        }
    }

    /// What the timeline needs to know about a movie: its length, its picture's size the
    /// way up it plays, and whether it has any sound.
    public static func measure(_ url: URL) async throws(Failure) -> (duration: CMTime, pixelSize: CGSize, hasSound: Bool) {
        let asset = AVURLAsset(url: url)
        let video: AVAssetTrack?
        let audio: [AVAssetTrack]
        let duration: CMTime
        do {
            video = try await asset.loadTracks(withMediaType: .video).first
            audio = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw .unreadable
        }
        guard let video else { throw .noPicture }
        guard duration.isNumeric, duration >= Clip.minimumDuration else { throw .tooShort }
        guard let natural = try? await video.load(.naturalSize),
              let transform = try? await video.load(.preferredTransform) else { throw .unreadable }
        // A movie shot on its side reports its size unrotated, as the recording does.
        let size = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        guard size.width >= 1, size.height >= 1 else { throw .noPicture }
        return (duration, size, !audio.isEmpty)
    }

    /// One movie out of a take whose picture and sound were recorded to separate files:
    /// the screen's picture, with every source of its sound beside it as a track of its own.
    ///
    /// Nothing is re-encoded — the samples are copied as they are — so it costs the time
    /// to copy the files and loses nothing. Each source stays its own track rather than
    /// being mixed, which is what the mixdown already expects of a movie: it lays every
    /// sound track a file has.
    ///
    /// - Parameter sounds: the take's sound files. A file that will not open is left out
    ///   rather than failing the rest: a take whose microphone file was lost still has a
    ///   picture worth bringing in.
    public static func combine(picture: URL, sounds: [URL], into destination: URL) async throws(Failure) {
        let composition = AVMutableComposition()
        do {
            let asset = AVURLAsset(url: picture)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noPicture }
            let range = try await source.load(.timeRange)
            guard let track = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw Failure.couldNotCombine("There was nowhere to put the picture.")
            }
            try track.insertTimeRange(range, of: source, at: .zero)
            track.preferredTransform = try await source.load(.preferredTransform)
            // Held to the picture's length: sound that runs on past the last frame would
            // make a clip longer than anything it can show.
            for url in sounds {
                let sound = AVURLAsset(url: url)
                for source in (try? await sound.loadTracks(withMediaType: .audio)) ?? [] {
                    guard let soundRange = try? await source.load(.timeRange),
                          let lane = composition.addMutableTrack(withMediaType: .audio,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid)
                    else { continue }
                    let heard = CMTimeRange(start: soundRange.start,
                                            duration: CMTimeMinimum(soundRange.duration, range.duration))
                    try? lane.insertTimeRange(heard, of: source, at: .zero)
                }
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .couldNotCombine(error.localizedDescription)
        }
        try await write(composition, to: destination)
    }

    private static func write(_ asset: AVAsset, to destination: URL) async throws(Failure) {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw .couldNotCombine("The movie couldn't be written.")
        }
        try? FileManager.default.removeItem(at: destination)
        if #available(macOS 15, *) {
            do {
                try await session.export(to: destination, as: .mov)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw .couldNotCombine(error.localizedDescription)
            }
        } else {
            session.outputURL = destination
            session.outputFileType = .mov
            await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { finished.resume() }
            }
            guard session.status == .completed else {
                try? FileManager.default.removeItem(at: destination)
                throw .couldNotCombine(session.error?.localizedDescription ?? "The movie couldn't be written.")
            }
        }
    }
}
