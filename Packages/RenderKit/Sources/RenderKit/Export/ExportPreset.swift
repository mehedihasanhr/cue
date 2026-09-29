import Foundation

/// The handful of exports people actually ask for, each as one choice.
///
/// Five controls — format, size, frame rate, quality, sound — is five decisions, and the
/// answers are nearly always one of four sets. Naming those sets after the errand rather
/// than after the settings is the whole point: nobody wants "H.264, 1920, 30 fps, no
/// audio", they want the clip that goes in a pull request. The settings are still there
/// underneath for the one export a month that is genuinely different.
///
/// A value in `RenderKit` rather than in the app, beside the settings it resolves to, so
/// "does this preset mean what it says" is a test and not an inspection of a SwiftUI file.
public enum ExportPreset: String, Sendable, CaseIterable, Codable, Identifiable {
    /// The good one. What you send someone who is going to watch it properly.
    case colleague
    /// Small, silent, and plays inline where code is reviewed.
    case review
    /// Under whatever a chat app will take, which is the only requirement it has.
    case chat
    /// No sound, no player, plays anywhere a picture does.
    case gif

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .colleague: "Send"
        case .review: "Review"
        case .chat: "Chat"
        case .gif: "GIF"
        }
    }

    /// What the errand is, in the words someone would use to describe it.
    public var detail: String {
        switch self {
        case .colleague: "1080p with sound, for someone who'll watch it properly."
        case .review: "Silent 1080p at 30 fps — plays inline in a pull request."
        case .chat: "720p, small enough to drop into a chat window."
        case .gif: "Silent, looping, plays anywhere a picture does."
        }
    }

    public var symbol: String {
        switch self {
        case .colleague: "paperplane"
        case .review: "checkmark.bubble"
        case .chat: "bubble.left.and.bubble.right"
        case .gif: "photo.stack"
        }
    }

    /// The settings this preset stands for.
    ///
    /// Written out in full rather than as changes to `ExportSettings()`'s defaults: a
    /// preset whose meaning moves because a default moved is a preset that lies, and the
    /// defaults exist for the sheet's first ever open, not for these.
    public var settings: ExportSettings {
        switch self {
        case .colleague:
            ExportSettings(format: .mp4,
                           frameRate: 60,
                           quality: .better,
                           codec: .automatic,
                           maximumDimension: 1_920,
                           includesAudio: true)
        case .review:
            // Silent on purpose. A clip attached to a diff is read next to other people's
            // work, often with headphones in for something else, and 30 fps halves the
            // file for footage that is mostly a still screen with a pointer on it.
            ExportSettings(format: .mp4,
                           frameRate: 30,
                           quality: .better,
                           codec: .automatic,
                           maximumDimension: 1_920,
                           includesAudio: false)
        case .chat:
            // 720p at Good, which is the combination that keeps a minute-long take inside
            // the attachment limits every messenger has and none of them agree on.
            ExportSettings(format: .mp4,
                           frameRate: 30,
                           quality: .good,
                           codec: .automatic,
                           maximumDimension: 1_280,
                           includesAudio: true)
        case .gif:
            // 15 fps and 640 across: a GIF stores every frame whole, so both of these are
            // the difference between a file that sends and one that does not.
            ExportSettings(format: .gif,
                           frameRate: 15,
                           quality: .good,
                           codec: .automatic,
                           maximumDimension: 640,
                           includesAudio: false,
                           loops: true)
        }
    }

    /// The preset these settings are, if they are one.
    ///
    /// Compared on the fields a preset actually claims, so a stored `loops` left over from
    /// a GIF does not stop an MP4 from still being recognised as Send — otherwise the
    /// highlight in the sheet drops off for a reason nobody can see.
    public static func matching(_ settings: ExportSettings) -> ExportPreset? {
        allCases.first { preset in
            let claimed = preset.settings
            guard claimed.format == settings.format,
                  claimed.frameRate == settings.frameRate,
                  claimed.quality == settings.quality,
                  claimed.codec == settings.codec,
                  claimed.maximumDimension == settings.maximumDimension else { return false }
            // Sound is only a claim where the format can carry any.
            return !claimed.format.carriesAudio || claimed.includesAudio == settings.includesAudio
        }
    }
}
