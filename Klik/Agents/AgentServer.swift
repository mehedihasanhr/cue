import Darwin
import Foundation
import os

/// One hook run, connected to Klik: its event, and the way back to it. An event
/// that waits for an answer keeps its connection until `reply`.
nonisolated final class AgentConnection: @unchecked Sendable {
    let id = UUID()
    private let fd: Int32
    private let queue: DispatchQueue
    private var closed = false

    fileprivate init(fd: Int32) {
        self.fd = fd
        queue = DispatchQueue(label: "com.stackrover.klik.agents.connection")
    }

    /// Writes the answer (nothing: "ask in the terminal") and hangs up.
    func reply(_ data: Data = Data()) {
        queue.async { [self] in
            guard !closed else { return }
            if !data.isEmpty {
                var payload = data
                payload.append(0x0A)
                payload.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                        if written <= 0 { break }
                        offset += written
                    }
                }
            }
            closeNow()
        }
    }

    private func closeNow() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    /// Reads one newline-terminated line (the event), giving up after `timeout`.
    fileprivate func readLine(limit: Int = 8 << 20, timeout: TimeInterval = 5) -> Data? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while line.count < limit {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            line.append(buffer, count: count)
            if buffer[count - 1] == 0x0A { break }
        }
        tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return line.isEmpty ? nil : line
    }
}

/// Listens on a Unix socket for the hook script. Each connection carries one event;
/// it is handed to `onEvent` on the main queue together with its connection.
nonisolated final class AgentServer: @unchecked Sendable {
    let path: String
    private var fd: Int32 = -1
    private var source: (any DispatchSourceRead)?
    /// The socket file this server made. Another copy of Klik starting up replaces
    /// the file with its own; when that copy quits, hooks would find nobody there.
    private var boundInode: ino_t = 0
    private var watchdog: (any DispatchSourceTimer)?
    private let queue = DispatchQueue(label: "com.stackrover.klik.agents.server")
    private let onEvent: @Sendable (AgentEvent, AgentConnection) -> Void

    init(path: String, onEvent: @escaping @Sendable (AgentEvent, AgentConnection) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    enum StartError: Error, CustomStringConvertible {
        case pathTooLong
        case system(String, Int32)

        var description: String {
            switch self {
            case .pathTooLong: "The socket path is too long"
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    func start() throws(StartError) {
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
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw .system("bind", code)
        }
        chmod(path, 0o600)
        boundInode = Self.inode(of: path) ?? 0
        guard listen(fd, 32) == 0 else {
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
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        close()
    }

    private func close() {
        source?.cancel()
        source = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
            // Only our own file: another copy's live socket must stay.
            if Self.inode(of: path) == boundInode { unlink(path) }
        }
    }

    /// Takes the socket path back when its file is gone or belongs to someone else
    /// (another copy of Klik ran and quit), so hooks reach this one again.
    private func rebindIfReplaced() {
        guard fd >= 0, Self.inode(of: path) != boundInode else { return }
        close()
        do { try start() } catch { Log.app.error("Agent sessions: rebinding the socket failed: \(error.description, privacy: .public)") }
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
            let connection = AgentConnection(fd: client)
            let onEvent = onEvent
            DispatchQueue.global(qos: .userInitiated).async {
                guard let line = connection.readLine(), let event = AgentEvent(line: line) else {
                    connection.reply()
                    return
                }
                // The hook closes its side once the event is sent, so a question's
                // connection stays open here until it is answered; the hook being
                // stopped (answered in the terminal) is noticed by its pid instead.
                if !event.wantsAnswer { connection.reply() } // news only: the hook can go
                DispatchQueue.main.async { onEvent(event, connection) }
            }
        }
    }
}
