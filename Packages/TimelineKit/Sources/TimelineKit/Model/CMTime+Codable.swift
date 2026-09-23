import CoreMedia
import Foundation

/// Writing `CMTime` to disk.
///
/// `CMTime` is the right currency for an edit — a rational number, so 1/30 of a second
/// is exact and adding thirty of them is exactly one second — but CoreMedia does not
/// make it `Codable`, and a document made of value types has to be writable.
///
/// The conformance is retroactive, which is a promise worth being careful about: it is
/// scoped to this package, it encodes the two fields the type is actually made of, and
/// it round-trips exactly rather than through `seconds`, which would quietly turn every
/// frame boundary into a float. If a future SDK adds `Codable` to `CMTime`, the compiler
/// will say so here and this file is the only thing to delete.
extension CMTime: @retroactive Codable {
    private enum CodingKeys: String, CodingKey {
        case value, timescale, flags, epoch
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(value: try container.decode(CMTimeValue.self, forKey: .value),
                  timescale: try container.decode(CMTimeScale.self, forKey: .timescale),
                  flags: CMTimeFlags(rawValue: try container.decodeIfPresent(UInt32.self, forKey: .flags) ?? 1),
                  epoch: try container.decodeIfPresent(CMTimeEpoch.self, forKey: .epoch) ?? 0)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(timescale, forKey: .timescale)
        try container.encode(flags.rawValue, forKey: .flags)
        try container.encode(epoch, forKey: .epoch)
    }
}
