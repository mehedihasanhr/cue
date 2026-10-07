import CoreMedia
import Foundation

/// Which row of its lane each region sits in, so regions that overlap in time sit one
/// above the other instead of on top of each other.
///
/// Two labels on screen at once used to share one row of the timeline: the later chip
/// covered the earlier one, and the one underneath could not be seen, clicked or dragged.
/// Editing apps stack overlapping clips instead — Final Cut's connected clips, Premiere's
/// and DaVinci's tracks — and that is what this is, worked out rather than chosen: each
/// region goes in the highest row it does not overlap anything in, so a lane only grows as
/// tall as its busiest moment.
public enum RegionStacking {
    /// The row of each region, 0 at the top.
    ///
    /// Earliest start first, and regions that start together in the order they are given,
    /// so the answer does not shuffle while nothing about the regions has changed. Touching
    /// is not overlapping: a region that ends where the next begins shares its row.
    public static func rows<Region: TimelineRegion>(of regions: [Region]) -> [UUID: Int] {
        let ordered = regions.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }
        var ends: [CMTime] = []
        var rows: [UUID: Int] = [:]
        for (_, region) in ordered {
            if let free = ends.firstIndex(where: { $0 <= region.start }) {
                ends[free] = region.end
                rows[region.id] = free
            } else {
                rows[region.id] = ends.count
                ends.append(region.end)
            }
        }
        return rows
    }

    /// How many rows a lane of `regions` needs: at least one, so an empty lane is still a lane.
    public static func rowCount<Region: TimelineRegion>(of regions: [Region]) -> Int {
        max(1, (rows(of: regions).values.max() ?? 0) + 1)
    }
}
