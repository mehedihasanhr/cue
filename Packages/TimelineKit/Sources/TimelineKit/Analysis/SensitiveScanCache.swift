import Foundation
import RecordKit

/// The last scan for sensitive text, kept in the package's `derived` folder beside the
/// other measurements of the footage.
///
/// Reading every frame's text takes a while, and the answer depends only on the footage
/// and on the rules that recognise things — not on the edit, which is why a finding is
/// kept on the recording's clock. So it is written once and read back until the video
/// file changes or the rules do.
public enum SensitiveScanCache {
    /// Bumped whenever `SensitiveText` or the scanner changes what it would find, so an
    /// older scan is done again rather than trusted.
    public static let version = 1

    private struct Cached: Codable {
        var version: Int
        var size: Int64
        var modified: Double
        var findings: [SensitiveFinding]

        init(version: Int, size: Int64, modified: Double, findings: [SensitiveFinding]) {
            self.version = version
            self.size = size
            self.modified = modified
            self.findings = findings
        }

        /// Finding by finding, so one that cannot be read costs the cache that finding.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            size = try container.decode(Int64.self, forKey: .size)
            modified = try container.decode(Double.self, forKey: .modified)
            let findings = (try? container.decodeIfPresent([Lenient].self, forKey: .findings)) ?? nil
            self.findings = (findings ?? []).compactMap(\.finding).filter { !$0.sightings.isEmpty }
        }

        private enum CodingKeys: String, CodingKey { case version, size, modified, findings }

        private struct Lenient: Decodable {
            let finding: SensitiveFinding?
            init(from decoder: any Decoder) throws {
                finding = try? decoder.singleValueContainer().decode(SensitiveFinding.self)
            }
        }
    }

    /// The last scan, if the recording and the rules are the same as when it was made.
    public static func cached(in package: RecordingPackage, source url: URL) -> [SensitiveFinding]? {
        guard let stamp = stamp(of: url),
              let data = try? Data(contentsOf: cacheURL(in: package)),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              cached.version == version, cached.size == stamp.size, cached.modified == stamp.modified
        else { return nil }
        return cached.findings
    }

    public static func cache(_ findings: [SensitiveFinding], in package: RecordingPackage, source url: URL) {
        guard let stamp = stamp(of: url) else { return }
        let cached = Cached(version: version, size: stamp.size, modified: stamp.modified, findings: findings)
        try? FileManager.default.createDirectory(at: package.derivedFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(cached).write(to: cacheURL(in: package), options: .atomic)
    }

    static func cacheURL(in package: RecordingPackage) -> URL {
        package.derivedFolder.appendingPathComponent("sensitive-text.json")
    }

    private static func stamp(of url: URL) -> (size: Int64, modified: Double)? {
        // Asked afresh: a URL remembers what it was last told about its file, and a
        // recording replaced under the same name would otherwise look unchanged.
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return (Int64(size), modified.timeIntervalSinceReferenceDate)
    }
}
