import AppKit
import CoreText
import Foundation
import os

/// Type families chosen by name, and what happens when a name is not on this Mac.
///
/// A project stores the family's name and nothing else — not a file, not a PostScript name
/// — because that is the one thing that means the same font on another Mac. A name this
/// Mac does not have is not an error: the words are drawn in the system's own type, exactly
/// as they were before a family was chosen, and the inspector says so. Measuring and
/// drawing both come through `font(family:size:weight:)`, so a label's box and its words
/// can never be worked out in two different fonts.
public enum FontFamilies {
    /// The families offered first, before the full list: ones that ship with macOS and
    /// read well on a screen recording. Only those present are shown — see `curatedInstalled`.
    public static let curated: [String] = [
        "Helvetica Neue", "Avenir Next", "Futura", "Gill Sans", "Georgia",
        "Baskerville", "Menlo", "American Typewriter", "Chalkboard SE", "Marker Felt",
    ]

    /// Every family installed on this Mac, in the order the system lists them.
    ///
    /// Only for the picker, on the main thread: the font manager belongs to AppKit's side
    /// of the app. The renderer asks `isInstalled`, which goes to Core Text and is safe
    /// from any thread.
    @MainActor
    public static var installed: [String] {
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
    }

    /// The curated families this Mac has.
    public static var curatedInstalled: [String] {
        curated.filter(isInstalled)
    }

    /// Whether this Mac has a family by this name. An empty name is the system's own type,
    /// which is always there, and so is not a family that can be missing.
    public static func isInstalled(_ family: String) -> Bool {
        let name = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return memo.withLock { known in
            if let answer = known[name] { return answer }
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
            let mandatory: Set<String> = [kCTFontFamilyNameAttribute as String]
            let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, mandatory as CFSet) as? [CTFontDescriptor]
            let answer = !(matches ?? []).isEmpty
            known[name] = answer
            return answer
        }
    }

    /// Answers already found. A font installed while the app runs is picked up the next
    /// time the app opens, which is what the system's own font menus do too.
    private static let memo = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    /// The family at a size and as near to a weight as the family has, or `nil` when this
    /// Mac does not have the family — the caller then draws in the system's type.
    public static func font(family: String, size: Double, weight: NSFont.Weight) -> NSFont? {
        let name = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isInstalled(name) else { return nil }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: name,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size),
              font.familyName?.caseInsensitiveCompare(name) == .orderedSame else { return nil }
        return font
    }
}
