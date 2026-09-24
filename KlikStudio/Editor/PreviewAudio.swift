import AVFoundation
import CoreMedia
import Foundation
import Observation
import os
import RenderKit
import TimelineKit

/// The edit, out loud.
///
/// The preview used to be silent: the picture was drawn by a display link reading a wall
/// clock, and the recording's sound went nowhere until the export. So the one thing a
/// screen recording is usually cut against — where somebody stopped talking — could not
/// be heard while cutting it.
///
/// Two decisions carry this:
///
/// **The sound is the export's sound.** `AudioMixdown` already turns a timeline into an
/// `AVComposition`, honouring cuts, reordering and speed through the composition's own
/// time mapping, and its result is exactly what an `AVPlayer` takes. Playing that asset
/// means the preview cannot drift from the file that comes out, because there is one
/// piece of code deciding what the sound is.
///
/// **The sound is the clock.** Video can drop a frame and nobody minds; audio cannot, and
/// a wall-clock playhead would slide against it over a long take. So when there is sound,
/// the player's time drives the playhead rather than the other way round. With no sound —
/// a silent recording, or an edit whose audio is still being built — the wall clock is
/// still there, unchanged.
@MainActor
@Observable
final class PreviewAudio {
    /// Whether this recording has any sound to play at all. Drives whether the transport
    /// shows a level control, so a silent take does not get a dead speaker button.
    private(set) var hasSound = false

    /// The level, kept across recordings: somebody who turns the sound down while editing
    /// at night should not have it come back at full the next time.
    var volume: Double {
        didSet {
            settings?.previewVolume = volume
            applyLevel()
        }
    }

    var isMuted: Bool {
        didSet {
            settings?.previewIsMuted = isMuted
            applyLevel()
        }
    }

    private let videoURL: URL
    private let packageURL: URL
    private let settings: StudioSettings?

    private var player: AVPlayer?
    /// The edit the current player was built for. When this stops matching the timeline,
    /// what is loaded is the sound of an edit that no longer exists.
    private var built: Timeline.AudioSignature?
    private var building: Task<Void, Never>?
    /// Set while the player should be running, so a rebuild that finishes mid-playback
    /// knows to pick the sound up rather than sit there loaded and quiet.
    private var wantsToPlay = false

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "audio")

    init(videoURL: URL, packageURL: URL, settings: StudioSettings?) {
        self.videoURL = videoURL
        self.packageURL = packageURL
        self.settings = settings
        volume = settings?.previewVolume ?? 1
        isMuted = settings?.previewIsMuted ?? false
    }

    // MARK: - Time

    /// Where the sound has got to, or `nil` when the sound is not what is keeping time.
    ///
    /// `nil` covers every case the wall clock has to handle: a recording with no audio, a
    /// rebuild still in flight, and a player that has been asked to play but has not
    /// started yet. The caller does not need to know which — only whether to trust this.
    var clock: CMTime? {
        guard wantsToPlay, let player, player.rate > 0,
              player.currentItem?.status == .readyToPlay else { return nil }
        return player.currentTime()
    }

    // MARK: - Building

    /// Makes sure the loaded sound is the sound of this edit.
    ///
    /// Cheap to call on every edit: the comparison is a value, and the look of the frame
    /// cannot change it. Only a cut, a trim, a reorder, a speed change or an added sound
    /// sends it back to AVFoundation.
    func prepare(for timeline: Timeline) {
        let signature = timeline.audioSignature
        guard signature != built || (player == nil && building == nil) else { return }

        built = signature
        building?.cancel()
        let videoURL = videoURL
        let packageURL = packageURL
        building = Task { [weak self] in
            let result = await AudioMixdown.build(timeline: timeline,
                                                  videoURL: videoURL,
                                                  packageURL: packageURL)
            guard !Task.isCancelled, let self else { return }
            self.adopt(result, for: signature)
        }
    }

    private func adopt(_ result: AudioMixdown.Result, for signature: Timeline.AudioSignature) {
        building = nil
        hasSound = !result.isEmpty
        guard !result.isEmpty else {
            player = nil
            return
        }

        let item = AVPlayerItem(asset: result.composition)
        item.audioMix = result.audioMix
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player
        applyLevel()

        // A rebuild that lands while playing joins in from where the picture has got to,
        // rather than waiting for the next press of Play.
        if wantsToPlay, let resume {
            player.seek(to: resume, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
        }
    }

    /// Where to come in, for a rebuild that finishes while playback is already running.
    /// Set by `play(from:)` and kept current by the editor's scrubbing.
    private var resume: CMTime?

    // MARK: - Transport

    func play(from time: CMTime, timeline: Timeline) {
        wantsToPlay = true
        resume = time
        prepare(for: timeline)
        guard let player else { return }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        applyLevel()
        player.play()
    }

    func pause() {
        wantsToPlay = false
        resume = nil
        player?.pause()
    }

    /// Follows the playhead when something else moved it — a scrub, a step, a jump to a
    /// cut. Seeking a paused player is pointless work, so it only happens while playing.
    func follow(_ time: CMTime) {
        resume = time
        guard wantsToPlay, let player else { return }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func applyLevel() {
        player?.volume = Float(max(0, min(1, volume)))
        player?.isMuted = isMuted
    }

    func cancel() {
        building?.cancel()
        building = nil
        player?.pause()
        player = nil
    }
}
