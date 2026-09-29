import Foundation

/// A `major.minor.patch` version, ordered.
///
/// Add-ons ship on their own schedule, so the host constantly has to answer "is the
/// thing that is installed new enough to talk to?" — string comparison gets that
/// wrong the moment a version reaches 0.10.0, which is soon.
///
/// Anything after the patch number (`1.2.3-beta.2`, Screen Studio's `3.7.5-4595`) is
/// kept for display and ignored for ordering: a build suffix says which build, not
/// which release, and two builds of one release are interchangeable to a caller
/// asking about capability.
nonisolated struct SemanticVersion: Sendable, Hashable, Comparable, Codable, LosslessStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// Everything after the patch number, without the separator. Empty when there is none.
    let suffix: String

    init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0, suffix: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.suffix = suffix
    }

    /// Parses `1`, `1.2`, `1.2.3` and `1.2.3-anything`. A missing component is zero,
    /// because `CFBundleShortVersionString` is routinely two components.
    init?(_ description: String) {
        let trimmed = description.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Split the release from any build/pre-release suffix at the first character
        // that cannot be part of a number or a dot.
        let releaseEnd = trimmed.firstIndex { !$0.isNumber && $0 != "." } ?? trimmed.endIndex
        let release = trimmed[..<releaseEnd]
        var tail = String(trimmed[releaseEnd...])
        if tail.first == "-" || tail.first == "+" { tail.removeFirst() }

        let parts = release.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }

        self.init(numbers[0],
                  numbers.count > 1 ? numbers[1] : 0,
                  numbers.count > 2 ? numbers[2] : 0,
                  suffix: tail)
    }

    var description: String {
        let release = "\(major).\(minor).\(patch)"
        return suffix.isEmpty ? release : "\(release)-\(suffix)"
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// This process's own version, for the "is the host new enough?" half of the
    /// handshake. Falls back to `0.0.0` rather than trapping — a missing key in a test
    /// bundle must not take the app down.
    static var host: SemanticVersion {
        let string = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return string.flatMap(SemanticVersion.init) ?? SemanticVersion(0)
    }
}
