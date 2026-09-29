import AppKit
import Foundation
import os

/// What each pointer actually looked like, saved beside the recording.
///
/// The editor draws its own pointer from the recorded positions, which is the whole reason
/// the video has no cursor burned into it: size, smoothing, click bounce and auto-zoom all
/// need the pointer to be data rather than pixels. The cost is that the drawn pointer is an
/// approximation of the real one, and on a Mac whose pointer is not the stock one — a
/// larger size, a different fill or outline colour, one of the accessibility pointers — the
/// approximation is visibly not what the person was looking at.
///
/// So the real artwork is saved too: one PNG per shape the pointer actually took while
/// recording, with the hotspot that says which pixel of it is the point. The editor can
/// then draw the true pointer at any size, because a picture of a cursor scales as well as
/// a drawing of one.
///
/// This is the machine's own pointer, written into its owner's own recording, which is the
/// same thing burning it into the video has always done — with the difference that it stays
/// a separate, re-sizable, removable layer.
///
/// One image per shape, written the first time that shape appears. A recording that only
/// ever shows an arrow writes one small file.
public final class CursorArtworkWriter: @unchecked Sendable {
    /// Where one shape's artwork lives, and which pixel of it is the point.
    public struct Entry: Codable, Equatable, Sendable {
        /// Relative to the package.
        public var path: String
        /// The hotspot, as a fraction of the image — stored normalised so it survives the
        /// image being drawn at any size.
        public var hotspotX: Double
        public var hotspotY: Double
        /// The artwork's size in points, so the renderer knows its aspect.
        public var width: Double
        public var height: Double

        public init(path: String, hotspotX: Double, hotspotY: Double, width: Double, height: Double) {
            self.path = path
            self.hotspotX = hotspotX
            self.hotspotY = hotspotY
            self.width = width
            self.height = height
        }
    }

    private let folder: URL
    private let relativeFolder: String
    private let state = OSAllocatedUnfairLock(initialState: [CursorShape: Entry]())

    private static let log = Logger(subsystem: "com.stackrover.klik.recordkit", category: "cursor-artwork")

    public init(folder: URL, relativeFolder: String) {
        self.folder = folder
        self.relativeFolder = relativeFolder
    }

    /// Saves this shape's artwork, if it has not been saved already.
    ///
    /// Called from the same slow timer that reads the pointer's shape, and a no-op on all
    /// but the first sighting of each shape — so a recording pays for this a handful of
    /// times in total rather than at the sample rate.
    @MainActor
    public func capture(_ shape: CursorShape, from cursor: NSCursor) {
        guard state.withLock({ $0[shape] == nil }) else { return }
        guard let entry = write(shape, cursor) else { return }
        state.withLock { $0[shape] = entry }
    }

    /// What was captured, for the manifest. Empty when nothing was.
    public var entries: [CursorShape: Entry] { state.withLock { $0 } }

    @MainActor
    private func write(_ shape: CursorShape, _ cursor: NSCursor) -> Entry? {
        let image = cursor.image
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        // Asked for at its natural pixel size rather than its point size: a Retina pointer
        // is 2× the points, and throwing that away here would be throwing away exactly the
        // resolution this exists to keep.
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return nil }

        let name = "\(shape.rawValue).png"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            // Losing the real artwork costs the drawn one, which is what every recording
            // made before this had. Not worth failing a take over.
            Self.log.error("Couldn't save \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let hotspot = cursor.hotSpot
        return Entry(path: "\(relativeFolder)/\(name)",
                     // Normalised, so the renderer can place the point without knowing what
                     // size the artwork happens to be drawn at.
                     hotspotX: Double(hotspot.x / size.width),
                     hotspotY: Double(hotspot.y / size.height),
                     width: Double(size.width),
                     height: Double(size.height))
    }

    /// Writes the index the editor reads, and says where it went. `nil` when there was
    /// nothing to write, so the manifest does not name a file that is not there.
    public func writeIndex(to url: URL, relativePath: String) -> String? {
        let entries = self.entries
        guard !entries.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let keyed = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) })
            try encoder.encode(keyed).write(to: url, options: .atomic)
            return relativePath
        } catch {
            Self.log.error("Couldn't write the cursor index: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
