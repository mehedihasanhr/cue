import CoreGraphics
import Foundation
import RecordKit

/// What each pointer in a recording actually looked like.
///
/// Written by the recorder while the pointer was still on screen — see
/// `CursorArtworkWriter` for why that is the only moment it can be read — and consulted by
/// the renderer, which would otherwise draw its own approximation of a stock Apple pointer
/// for somebody whose pointer is not stock at all.
///
/// Empty for every recording made before the artwork was kept, and for any take that
/// turned it off. Emptiness is the whole compatibility story: nothing found means the
/// drawn pointer, which is what those recordings have always had.
public struct CursorArtworkIndex: Sendable {
    /// One shape's artwork, resolved against the package it lives in.
    public struct Artwork: Equatable, Sendable {
        public let url: URL
        /// Which pixel of the image is the point, as a fraction of it. Normalised so the
        /// renderer can place the point without knowing what size it drew the image at.
        public let hotspot: CGPoint
        /// Height over width, so the renderer can size it without opening it first.
        public let aspect: Double

        public init(url: URL, hotspot: CGPoint, aspect: Double) {
            self.url = url
            self.hotspot = hotspot
            self.aspect = aspect
        }
    }

    private let artwork: [CursorShape: Artwork]

    public init(artwork: [CursorShape: Artwork] = [:]) {
        self.artwork = artwork
    }

    public var isEmpty: Bool { artwork.isEmpty }

    /// The real artwork for a shape, or — failing that — for an arrow.
    ///
    /// Falling back to the arrow rather than to nothing: a recording that saved an arrow
    /// and a text bar, and is being asked for a shape the tracker could only call `other`,
    /// looks more like itself with its own arrow than with a drawn one. A recording that
    /// saved nothing falls through to the drawing, as it must.
    public func artwork(for shape: CursorShape) -> Artwork? {
        artwork[shape] ?? artwork[.arrow]
    }

    /// Reads the index a recording wrote. Any failure is an empty index, because the
    /// drawn pointer is a complete answer and a missing sidecar is not worth an error.
    public static func read(_ manifest: RecordingManifest, in packageURL: URL) -> CursorArtworkIndex {
        guard let path = manifest.telemetry.cursorArtwork,
              let data = try? Data(contentsOf: packageURL.appendingPathComponent(path)),
              let entries = try? JSONDecoder().decode([String: CursorArtworkWriter.Entry].self, from: data)
        else { return CursorArtworkIndex() }

        var artwork: [CursorShape: Artwork] = [:]
        for (name, entry) in entries {
            guard let shape = CursorShape(rawValue: name), entry.width > 0, entry.height > 0 else { continue }
            let url = packageURL.appendingPathComponent(entry.path)
            // A named file that is not there is the same as no artwork for that shape: the
            // package can be moved, pruned or repaired by hand.
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            artwork[shape] = Artwork(url: url,
                                     hotspot: CGPoint(x: entry.hotspotX, y: entry.hotspotY),
                                     aspect: entry.height / entry.width)
        }
        return CursorArtworkIndex(artwork: artwork)
    }
}
