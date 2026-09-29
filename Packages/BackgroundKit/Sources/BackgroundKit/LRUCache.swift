/// A tiny bounded cache that evicts its least recently used entry past `capacity`.
///
/// Used for rendered bitmaps (blur regions, blurred wallpapers), where only the last
/// few results are ever reused and an unbounded dictionary can quietly hold hundreds
/// of megabytes — a real problem on an 8 GB Mac mini.
public struct LRUCache<Key: Hashable, Value> {
    public let capacity: Int
    private var storage: [Key: Value] = [:]
    /// Keys from least to most recently used.
    private var order: [Key] = []

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { storage.count }

    public subscript(key: Key) -> Value? {
        mutating get {
            guard let value = storage[key] else { return nil }
            touch(key)
            return value
        }
        set {
            if let newValue {
                storage[key] = newValue
                touch(key)
                while storage.count > capacity, let oldest = order.first {
                    order.removeFirst()
                    storage[oldest] = nil
                }
            } else {
                storage[key] = nil
                order.removeAll { $0 == key }
            }
        }
    }

    public mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
