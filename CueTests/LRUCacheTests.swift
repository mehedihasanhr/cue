import BackgroundKit
import XCTest

/// The bounded cache behind rendered-bitmap caching (blur regions, wallpapers).
final class LRUCacheTests: XCTestCase {
    func testEvictsLeastRecentlyUsedPastCapacity() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache["a"] = 1
        cache["b"] = 2
        _ = cache["a"] // "a" is now the most recently used
        cache["c"] = 3 // evicts "b"

        XCTAssertEqual(cache["a"], 1)
        XCTAssertNil(cache["b"])
        XCTAssertEqual(cache["c"], 3)
        XCTAssertEqual(cache.count, 2)
    }

    func testOverwritingKeepsASingleEntry() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache["a"] = 1
        cache["a"] = 10
        cache["b"] = 2
        XCTAssertEqual(cache["a"], 10)
        XCTAssertEqual(cache.count, 2)
    }

    func testRemovalAndReset() {
        var cache = LRUCache<String, Int>(capacity: 3)
        cache["a"] = 1
        cache["b"] = 2
        cache["a"] = nil
        XCTAssertNil(cache["a"])
        XCTAssertEqual(cache.count, 1)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache["b"])
    }
}
