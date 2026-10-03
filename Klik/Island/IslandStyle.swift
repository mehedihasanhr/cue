import SwiftUI

/// The island's palette, kept quiet so it sits with the smoke behind every panel:
/// what is selected is soft white with dark text, focus is a thin light ring, and
/// the one colour is a muted steel blue for the few things that must stand out.
enum IslandStyle {
    /// A selected tab, pill or chip.
    static let selectedFill = Color.white.opacity(0.92)
    static let selectedText = Color.black.opacity(0.86)
    /// The ring around the card under the pointer.
    static let hoverRing = Color.white.opacity(0.42)
    static let hoverRingWidth: CGFloat = 1
    /// The ring around a chosen card (keyboard selection, a compare pick).
    static let selectedRing = Color.white.opacity(0.8)
    static let selectedRingWidth: CGFloat = 1.5
    /// Drop targets, compare badges, progress, the search field in use.
    static let accent = Color(red: 0.36, green: 0.58, blue: 0.86)
}
