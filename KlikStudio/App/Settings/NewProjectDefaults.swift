import Foundation
import Observation
import TimelineKit

/// What a new recording's pointer, captions and voice start as, beyond the frame and the
/// three pointer settings `StudioSettings` has always kept.
///
/// Reached as `settings.newProjects`, and applied by `StudioSettings.styled(_:)` to a
/// project nobody has edited yet — so, like every other default there, changing one never
/// rewrites a project somebody already made.
///
/// Every default here is the model's own default, deliberately: until somebody moves a
/// control, applying these changes nothing, and a new recording looks exactly as it did
/// before this object existed.
@MainActor
@Observable
final class NewProjectDefaults {
    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let clickRing = "editor.clickRing"
        static let clickStyle = "editor.clickStyle"
        static let motionBlur = "editor.motionBlur"
        static let hidesIdlePointer = "editor.hidesIdlePointer"
        static let alwaysArrow = "editor.alwaysArrow"
        static let clickSound = "audio.clickSound"
        static let clickSoundKind = "audio.clickSoundKind"
        static let clickSoundVolume = "audio.clickSoundVolume"
        static let cleansVoice = "audio.cleansVoice"
        static let evensVolume = "audio.evensVolume"
        static let captionPosition = "captions.position"
        static let captionTypeface = "captions.typeface"
        static let captionAnimation = "captions.animation"
        static let captionSize = "captions.size"
        static let captionBackground = "captions.background"
        static let captionHighlightsWords = "captions.highlightsWords"
    }

    private static let pointer = CursorStyle()
    private static let captions = CaptionStyle()

    /// The ranges the controls offer, which are also what a stored value is clamped to —
    /// so a hand-edited defaults file cannot ask for a caption bigger than the slider can.
    /// The same range as the editor's Captions panel, so no look is ever clamped by it.
    static let captionSizes: ClosedRange<Double> = 0.02...0.12
    static let captionBackgrounds: ClosedRange<Double> = 0...1

    // MARK: - Pointer

    /// A ring where each click lands. See `CursorStyle.clickHighlight`.
    var clickRing = pointer.clickHighlight { didSet { store(clickRing, Key.clickRing) } }
    var clickStyle = pointer.clickStyle { didSet { store(clickStyle.rawValue, Key.clickStyle) } }
    var motionBlur = pointer.motionBlur { didSet { store(motionBlur, Key.motionBlur) } }
    var hidesIdlePointer = pointer.hidesWhenIdle { didSet { store(hidesIdlePointer, Key.hidesIdlePointer) } }
    var alwaysArrow = pointer.alwaysArrow { didSet { store(alwaysArrow, Key.alwaysArrow) } }

    // MARK: - Sound

    var clickSound = pointer.clickSound { didSet { store(clickSound, Key.clickSound) } }
    var clickSoundKind = pointer.clickSoundKind { didSet { store(clickSoundKind.rawValue, Key.clickSoundKind) } }
    var clickSoundVolume = pointer.clickSoundVolume { didSet { store(clickSoundVolume, Key.clickSoundVolume) } }
    /// Clean up voice and even out volume, on every microphone of a new recording.
    var cleansVoice = false { didSet { store(cleansVoice, Key.cleansVoice) } }
    var evensVolume = false { didSet { store(evensVolume, Key.evensVolume) } }

    // MARK: - Captions

    var captionPosition = captions.position { didSet { store(captionPosition.rawValue, Key.captionPosition) } }
    var captionTypeface = captions.typeface { didSet { store(captionTypeface.rawValue, Key.captionTypeface) } }
    var captionAnimation = captions.animation { didSet { store(captionAnimation.rawValue, Key.captionAnimation) } }
    /// A fraction of the finished frame's height, like `CaptionStyle.fontSize`.
    var captionSize = captions.fontSize { didSet { store(captionSize, Key.captionSize) } }
    var captionBackground = captions.backgroundOpacity { didSet { store(captionBackground, Key.captionBackground) } }
    var captionHighlightsWords = captions.highlightsWords { didSet { store(captionHighlightsWords, Key.captionHighlightsWords) } }

    /// See `StudioAppPreferences.isLoading`.
    @ObservationIgnored private var isLoading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func store(_ value: Any, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    /// Reads every value again, leniently — at launch, and after Reset All Settings.
    func load() {
        isLoading = true
        defer { isLoading = false }
        let pointer = Self.pointer
        let captions = Self.captions
        clickRing = bool(Key.clickRing) ?? pointer.clickHighlight
        clickStyle = defaults.string(forKey: Key.clickStyle).flatMap(CursorStyle.ClickStyle.init) ?? pointer.clickStyle
        motionBlur = bool(Key.motionBlur) ?? pointer.motionBlur
        hidesIdlePointer = bool(Key.hidesIdlePointer) ?? pointer.hidesWhenIdle
        alwaysArrow = bool(Key.alwaysArrow) ?? pointer.alwaysArrow
        clickSound = bool(Key.clickSound) ?? pointer.clickSound
        clickSoundKind = defaults.string(forKey: Key.clickSoundKind).flatMap(CursorStyle.ClickSound.init) ?? pointer.clickSoundKind
        clickSoundVolume = number(Key.clickSoundVolume, in: 0...1) ?? pointer.clickSoundVolume
        cleansVoice = bool(Key.cleansVoice) ?? false
        evensVolume = bool(Key.evensVolume) ?? false
        captionPosition = defaults.string(forKey: Key.captionPosition).flatMap(CaptionStyle.Position.init) ?? captions.position
        captionTypeface = defaults.string(forKey: Key.captionTypeface).flatMap(CaptionStyle.Typeface.init) ?? captions.typeface
        captionAnimation = defaults.string(forKey: Key.captionAnimation).flatMap(CaptionStyle.Animation.init) ?? captions.animation
        captionSize = number(Key.captionSize, in: Self.captionSizes) ?? captions.fontSize
        captionBackground = number(Key.captionBackground, in: Self.captionBackgrounds) ?? captions.backgroundOpacity
        captionHighlightsWords = bool(Key.captionHighlightsWords) ?? captions.highlightsWords
    }

    private func bool(_ key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    /// A stored number, clamped into the range its control offers; `nil` when there is
    /// none, or it is not a finite number.
    private func number(_ key: String, in range: ClosedRange<Double>) -> Double? {
        guard let value = (defaults.object(forKey: key) as? NSNumber)?.doubleValue, value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Dresses a brand-new project in these defaults.
    func apply(to timeline: inout Timeline) {
        timeline.cursor.clickHighlight = clickRing
        timeline.cursor.clickStyle = clickStyle
        timeline.cursor.motionBlur = motionBlur
        timeline.cursor.hidesWhenIdle = hidesIdlePointer
        timeline.cursor.alwaysArrow = alwaysArrow
        timeline.cursor.clickSound = clickSound
        timeline.cursor.clickSoundKind = clickSoundKind
        timeline.cursor.clickSoundVolume = clickSoundVolume
        timeline.captionStyle.position = captionPosition
        timeline.captionStyle.typeface = captionTypeface
        timeline.captionStyle.animation = captionAnimation
        timeline.captionStyle.fontSize = captionSize
        timeline.captionStyle.backgroundOpacity = captionBackground
        timeline.captionStyle.highlightsWords = captionHighlightsWords
        timeline.treatVoices(cleansVoice: cleansVoice, evensVolume: evensVolume)
    }

    /// Moves what a look says about the fields above into them, and returns the rest.
    ///
    /// The same split `useForNewRecordings(_:)` makes for the frame: a field this window
    /// has a control for is shown in that control, not hidden inside a look where the
    /// control would be overruled without saying so.
    func absorb(_ look: Look) -> Look {
        var kept = look
        if let value = look.pointer.clickHighlight { clickRing = value; kept.pointer.clickHighlight = nil }
        if let value = look.pointer.clickStyle { clickStyle = value; kept.pointer.clickStyle = nil }
        if let value = look.pointer.motionBlur { motionBlur = value; kept.pointer.motionBlur = nil }
        if let value = look.pointer.hidesWhenIdle { hidesIdlePointer = value; kept.pointer.hidesWhenIdle = nil }
        if let value = look.pointer.alwaysArrow { alwaysArrow = value; kept.pointer.alwaysArrow = nil }
        if let value = look.pointer.clickSound { clickSound = value; kept.pointer.clickSound = nil }
        if let value = look.pointer.clickSoundKind { clickSoundKind = value; kept.pointer.clickSoundKind = nil }
        if let value = look.pointer.clickSoundVolume, (0...1).contains(value) {
            clickSoundVolume = value
            kept.pointer.clickSoundVolume = nil
        }
        if let value = look.captions.position { captionPosition = value; kept.captions.position = nil }
        if let value = look.captions.typeface { captionTypeface = value; kept.captions.typeface = nil }
        if let value = look.captions.animation { captionAnimation = value; kept.captions.animation = nil }
        // Taken only when the control can show it; anything outside stays with the look
        // rather than being quietly rounded to the nearest end of a slider.
        if let value = look.captions.fontSize, Self.captionSizes.contains(value) {
            captionSize = value
            kept.captions.fontSize = nil
        }
        if let value = look.captions.backgroundOpacity, Self.captionBackgrounds.contains(value) {
            captionBackground = value
            kept.captions.backgroundOpacity = nil
        }
        if let value = look.captions.highlightsWords { captionHighlightsWords = value; kept.captions.highlightsWords = nil }
        return kept
    }
}
