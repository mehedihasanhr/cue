import Darwin
import Foundation
import os

/// Cue's MCP server, for AI agents: the Model Context Protocol over a Unix socket in
/// Cue's container, one line of JSON-RPC per message — the protocol's stdio framing.
///
/// An agent runs `cue-mcp` (in the app's Resources), which connects its own stdin and
/// stdout to this socket; each connection is one session, open for as long as the agent
/// keeps it. The sandbox lets Cue make a socket in its container and nowhere else, which
/// is why there is a bridge at all — the same arrangement as the agent hooks
/// (`AgentServer`). The file is the user's alone (0600).
///
/// Messages are read off the main thread and answered on it, one at a time and in order:
/// `handle` reads and changes the task store, which lives there.
nonisolated final class MCPServer: @unchecked Sendable {
    static let socketName = "mcp.sock"
    static var socketPath: String { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(socketName).path }

    let path: String
    private let handle: @MainActor (Data) -> Data?
    private var fd: Int32 = -1
    private var source: (any DispatchSourceRead)?
    /// The socket file this server made, so another copy of Cue replacing it — and then
    /// quitting — is noticed and the path taken back. See `AgentServer`.
    private var boundInode: ino_t = 0
    private var watchdog: (any DispatchSourceTimer)?
    private let queue = DispatchQueue(label: "com.stackrover.cue.mcp.server")
    private var sessions: [UUID: MCPSession] = [:]

    private static let log = Logger(subsystem: "com.stackrover.cue", category: "mcp")

    /// `handle` takes one message and returns the reply to send, or nil for none (a
    /// notification).
    init(path: String = MCPServer.socketPath, handle: @escaping @MainActor (Data) -> Data?) {
        self.path = path
        self.handle = handle
    }

    var isRunning: Bool { queue.sync { fd >= 0 } }

    func start() throws(AgentServer.StartError) {
        let failure: AgentServer.StartError? = queue.sync {
            do throws(AgentServer.StartError) { try bind() } catch { return error }
            return nil
        }
        if let failure { throw failure }
    }

    func stop() {
        queue.sync {
            watchdog?.cancel()
            watchdog = nil
            close()
            for session in sessions.values { session.close() }
            sessions.removeAll()
        }
    }

    private func bind() throws(AgentServer.StartError) {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw .pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        unlink(path) // a socket left by a previous run
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system("socket", errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw .system("bind", code)
        }
        chmod(path, 0o600)
        boundInode = Self.inode(of: path) ?? 0
        guard listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw .system("listen", code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        self.source = source
        source.resume()
        if watchdog == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.rebindIfReplaced() }
            watchdog = timer
            timer.resume()
        }
        Self.log.info("MCP server listening")
    }

    private func close() {
        source?.cancel()
        source = nil
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
        // Only our own file: another copy's live socket must stay.
        if Self.inode(of: path) == boundInode { unlink(path) }
    }

    private func rebindIfReplaced() {
        guard fd >= 0, Self.inode(of: path) != boundInode else { return }
        close()
        do { try bind() } catch { Self.log.error("MCP server: rebinding the socket failed: \(error.description, privacy: .public)") }
    }

    private static func inode(of path: String) -> ino_t? {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_ino : nil
    }

    private func accept() {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            let session = MCPSession(fd: client, handle: handle) { [weak self] id in
                self?.queue.async { self?.sessions[id] = nil }
            }
            sessions[session.id] = session
            session.start()
        }
    }
}

/// One agent's connection: lines in, replies out, until either side hangs up.
nonisolated final class MCPSession: @unchecked Sendable {
    let id = UUID()
    private let fd: Int32
    private let handle: @MainActor (Data) -> Data?
    private let onEnd: @Sendable (UUID) -> Void
    private let writes = DispatchQueue(label: "com.stackrover.cue.mcp.session.write")
    private let lock = NSLock()
    private var closed = false

    /// The longest line accepted; a task's text is small, and a client sending more than
    /// this is not speaking the protocol.
    private static let lineLimit = 16 << 20

    fileprivate init(fd: Int32, handle: @escaping @MainActor (Data) -> Data?, onEnd: @escaping @Sendable (UUID) -> Void) {
        self.fd = fd
        self.handle = handle
        self.onEnd = onEnd
    }

    fileprivate func start() {
        Thread.detachNewThread { [self] in readLoop() }
    }

    private func readLoop() {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            pending.append(buffer, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[(newline + 1)...])
                if !line.allSatisfy({ $0 == 0x0D || $0 == 0x20 }) { receive(Data(line)) }
            }
            if pending.count > Self.lineLimit { break }
        }
        // The client is done sending, but replies to its last messages may still be on
        // their way: they are queued on the main queue, then on `writes`, so hanging up
        // from the back of both sends them first. A client piping a few requests in and
        // closing its end (a script, a test) gets every answer.
        DispatchQueue.main.async { [self] in
            writes.async { [self] in
                close()
                onEnd(id)
            }
        }
    }

    private func receive(_ line: Data) {
        let handle = handle
        DispatchQueue.main.async { [self] in
            guard let reply = MainActor.assumeIsolated({ handle(line) }) else { return }
            send(reply)
        }
    }

    private func send(_ message: Data) {
        writes.async { [self] in
            guard !isClosed else { return }
            var payload = message
            payload.append(0x0A)
            payload.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
    }

    private var isClosed: Bool { lock.withLock { closed } }

    func close() {
        let wasOpen = lock.withLock {
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        // Shut down rather than closed here: the reader may still be inside `read`, and
        // closing a descriptor another thread is reading lets the number be reused under
        // it. The reader sees the end and returns; the descriptor is closed after writes.
        shutdown(fd, SHUT_RDWR)
        writes.async { [fd] in Darwin.close(fd) }
    }
}
