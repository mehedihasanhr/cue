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

    /// Silenced while narration is being recorded through the built-in microphone.
    ///
    /// Separate from `isMuted` on purpose, and not persisted: muting is a choice the user
    /// made and has to find intact afterwards, whereas this is the preview getting out of
    /// the way of the microphone for a minute. Without it the take contains the edit — the
    /// speakers go into the mic and the voiceover arrives with the video underneath it,
    /// doubled and half a beat late.
    private(set) var isSilencedForCapture = false

    /// Keeps the preview quiet until `stopSilencingForCapture()`. The level and the mute
    /// the user chose are untouched, so restoring is a matter of clearing one flag rather
    /// than remembering and putting back two values.
    func silenceForCapture() {
        isSilencedForCapture = true
        applyLevel()
    }

    func stopSilencingForCapture() {
        isSilencedForCapture = false
        applyLevel()
    }

    private let videoURL: URL
    private let packageURL: URL
    /// The recording's clicks, for the click sounds. They never change for a recording,
    /// so they are handed over once rather than with every edit.
    private let clicks: [CursorTrack.Click]
    /// The recording's size in points. See `AudioMixdown.build(clickFrame:)`.
    private let clickFrame: CGSize?
    /// Where a resized window's picture sat, which the clicks follow as the picture does.
    private let picture: PictureTrack
    private let settings: StudioSettings?

    private var player: AVPlayer?
    /// The edit the current player was built for. When this stops matching the timeline,
    /// what is loaded is the sound of an edit that no longer exists.
    private var built: Timeline.AudioSignature?
    private var building: Task<Void, Never>?
    /// Set while the player should be running, so a rebuild that finishes mid-playback
    /// knows to pick the sound up rather than sit there loaded and quiet.
    private var wantsToPlay = false

    private static let log = Logger(subsystem: "com.stackrover.klik", category: "audio")

    init(videoURL: URL, packageURL: URL, clicks: [CursorTrack.Click] = [], clickFrame: CGSize? = nil,
         picture: PictureTrack = PictureTrack(), settings: StudioSettings?) {
        self.clickFrame = clickFrame
        self.picture = picture
        self.videoURL = videoURL
        self.packageURL = packageURL
        self.clicks = clicks
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
        let clicks = clicks
        let clickFrame = clickFrame
        let picture = picture
        building = Task { [weak self] in
            let result = await AudioMixdown.build(timeline: timeline,
                                                  videoURL: videoURL,
                                                  packageURL: packageURL,
                                                  clicks: clicks,
                                                  clickFrame: clickFrame,
                                                  picture: picture)
            guard !Task.isCancelled, let self else { return }
            self.adopt(result, for: signature)
        }
    }

    private func adopt(_ result: AudioMixdown.Result, for signature: Timeline.AudioSignature) {
        building = nil
        // Where the sound had got to, read off the player being replaced while it was
        // still running. `resume` is where Play was pressed, which may be minutes ago:
        // coming back in there made the playhead jump back to it whenever an edit landed
        // during playback, because the picture follows the sound's clock.
        let reached: CMTime? = if let player, player.rate > 0 { player.currentTime() } else { nil }
        hasSound = !result.isEmpty
        guard !result.isEmpty else {
            player = nil
            return
        }

        // The mix travels with the item: it carries the voice clean-up and the music's
        // dips under speech, which an item made here by hand could leave behind.
        let player = AVPlayer(playerItem: result.playerItem())
        player.actionAtItemEnd = .pause
        self.player = player
        applyLevel()

        // A rebuild that lands while playing joins in from where the picture has got to,
        // rather than waiting for the next press of Play.
        if wantsToPlay, let from = reached ?? resume {
            player.seek(to: from, toleranceBefore: .zero, toleranceAfter: .zero)
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
        player?.isMuted = isMuted || isSilencedForCapture
    }

    func cancel() {
        building?.cancel()
        building = nil
        player?.pause()
        player = nil
    }
}
