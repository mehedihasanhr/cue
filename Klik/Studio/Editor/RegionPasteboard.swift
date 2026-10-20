import AppKit
import Observation
import os
import TimelineKit

/// The clipboard, as the editor sees it.
///
/// The system pasteboard rather than a variable on the model, and this is the whole reason
/// the type exists: an editor window is an `NSWindow` this app owns and there can be
/// several of them open at once (`EditorWindows`), so a zoom tuned in one take has to be
/// pastable into another. A private `var` would have made "copy" mean "copy within this
/// window", which is the kind of almost-working that is worse than nothing.
///
/// A single shared instance, because the pasteboard is a single system-wide thing. Two
/// observers of it would be two answers to the same question.
@MainActor
@Observable
final class RegionPasteboard {
    static let shared = RegionPasteboard()

    /// Our own type, reverse-DNS under the app's bundle identifier.
    ///
    /// A private UTI rather than one of the system's: what goes under it is a Klik region
    /// in Klik's own JSON, and claiming a public type for it would invite other apps to
    /// read it as something it is not. Nothing else declares this, so anything found under
    /// it came from a Klik Studio — though not necessarily *this* one, which is why the
    /// payload is still decoded defensively.
    static let type = NSPasteboard.PasteboardType("com.stackrover.klik.studio.region")

    /// Footage, under a type of its own.
    ///
    /// A second UTI rather than a second `kind` inside the first one's payload, and the
    /// reason is what `canReadItem` can answer: whether Paste is live has to be decidable
    /// from the *types* on the pasteboard, without reading and decoding a payload that may
    /// be a whole stretch of an edit. Two types means the menu can be right about which
    /// paste it is offering while touching nothing but a list of names.
    static let footageType = NSPasteboard.PasteboardType("com.stackrover.klik.studio.footage")

    /// Whether Paste would do anything, for the menu item to be honest about.
    ///
    /// Stored and observed rather than computed, because a computed property that read
    /// `NSPasteboard` would give SwiftUI nothing to invalidate on: the menu would show
    /// whatever was true the last time something else happened to change.
    private(set) var hasRegion = false

    /// The same question about footage. Separate rather than folded into `hasRegion`,
    /// because the two pastes are different edits and a caller may care which it is about
    /// to do — pasting footage changes how long the edit is.
    private(set) var hasFootage = false

    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount - 1
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private static let log = Logger(subsystem: "com.stackrover.klik", category: "clipboard")

    private init() {
        refresh()
        // Re-read when the app comes forward, which covers every way the pasteboard can
        // change behind our back: a copy made in another app can only have happened while
        // this one was not active, and a copy made *here* calls `refresh()` itself. That
        // is two events rather than a poll, and a menu that is right whenever it is open.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                         object: nil,
                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Asks the pasteboard whether it still holds what it held last time.
    ///
    /// Guarded on `changeCount` so the common case — the app being activated with nothing
    /// new copied — does no work at all and, more to the point, does not write to an
    /// observed property and wake every menu that reads it.
    func refresh() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        // `canReadItem` rather than reading and decoding: this runs on activation, and
        // whether the menu item is live is a question about types, not about contents.
        hasRegion = pasteboard.canReadItem(withDataConformingToTypes: [Self.type.rawValue])
        hasFootage = pasteboard.canReadItem(withDataConformingToTypes: [Self.footageType.rawValue])
    }

    // MARK: - Writing

    func write(_ region: CopiedRegion) {
        guard let data = region.encoded() else {
            Self.log.error("A \(region.title, privacy: .public) could not be encoded for the clipboard")
            return
        }
        let item = NSPasteboardItem()
        // The real payload first. A pasteboard item lists its types richest-first, and the
        // plain text below is a courtesy for other apps — our own paste must never find it
        // in preference to the region it describes.
        item.setData(data, forType: Self.type)
        item.setString(region.summary, forType: .string)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        refresh()
    }

    /// Footage, written the same way and clearing the same pasteboard.
    ///
    /// Clearing matters more here than it looks: one pasteboard holds one thing, so copying
    /// footage has to make the region that was on it stop being pasteable. Leaving both
    /// there would give two live Paste items whose order decided what happened, which is
    /// exactly the sort of "almost working" the type's own note warns about.
    func write(_ footage: CopiedFootage) {
        guard let data = footage.encoded() else {
            Self.log.error("Footage could not be encoded for the clipboard")
            return
        }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.footageType)
        item.setString(footage.summary, forType: .string)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        refresh()
    }

    // MARK: - Reading

    /// The region on the pasteboard, if there is one this build understands.
    func read() -> CopiedRegion? {
        guard let data = NSPasteboard.general.data(forType: Self.type) else { return nil }
        guard let region = CopiedRegion.decoded(from: data) else {
            // Reached when a newer Klik Studio copied a kind of region this build has never
            // heard of, or when the bytes are damaged. Either way the answer is to do
            // nothing visible — but it is worth a line in the log, because "⌘V did nothing"
            // is otherwise indistinguishable from a bug in the paste itself.
            Self.log.notice("Something was on the clipboard under our type that this build could not read")
            return nil
        }
        return region
    }

    /// The footage on the pasteboard, if there is any this build understands.
    ///
    /// Same shape and same bargain as `read()`: a payload from a newer build, or damaged
    /// bytes, is indistinguishable from an empty pasteboard to every caller, and worth one
    /// line in the log so that "⌘V did nothing" can be told apart from a bug in the paste.
    func readFootage() -> CopiedFootage? {
        guard let data = NSPasteboard.general.data(forType: Self.footageType) else { return nil }
        guard let footage = CopiedFootage.decoded(from: data) else {
            Self.log.notice("Something was on the clipboard under our footage type that this build could not read")
            return nil
        }
        return footage
    }
}
