import Foundation

/// Appends one JSON object per line to a file, as the samples happen.
///
/// JSON Lines rather than one big array: a recording that crashes or fills the disk
/// still leaves every sample written up to that moment readable, and the writer never
/// has to hold the whole track in memory. A twenty-minute take at 120 Hz is about
/// 150,000 samples — small on disk, silly to accumulate in RAM.
///
/// Every method must be called on `queue`, which is the same queue frames arrive on, so
/// nothing crosses an isolation boundary and nothing needs a lock.
public final class JSONLWriter: @unchecked Sendable {
    public let url: URL
    private let queue: DispatchQueue
    private let encoder = JSONEncoder()
    private var handle: FileHandle?
    private var buffer = Data()
    private var lineCount = 0
    /// Flush at a size rather than per line: 150,000 one-line writes is 150,000 syscalls
    /// on the queue frames also arrive on.
    private static let flushThreshold = 64 * 1024

    public private(set) var isOpen = false

    public init(url: URL, queue: DispatchQueue) {
        self.url = url
        self.queue = queue
        encoder.outputFormatting = [.sortedKeys]
    }

    /// Creates the file. Failing here is worth knowing about: it means the package is
    /// not writable, which the video is about to discover the hard way.
    public func open() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        handle = try FileHandle(forWritingTo: url)
        isOpen = true
    }

    public func append(_ value: some Encodable) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isOpen, let data = try? encoder.encode(value) else { return }
        buffer.append(data)
        buffer.append(0x0A)
        lineCount += 1
        if buffer.count >= Self.flushThreshold { flush() }
    }

    public func flush() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !buffer.isEmpty, let handle else { return }
        try? handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    /// Closes the file and says whether anything was written — an empty track is left
    /// out of the manifest rather than recorded as an empty file.
    @discardableResult
    public func close() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        flush()
        try? handle?.close()
        handle = nil
        isOpen = false
        if lineCount == 0 { try? FileManager.default.removeItem(at: url) }
        return lineCount > 0
    }
}
