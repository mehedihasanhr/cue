import AppKit
import Darwin
import os

/// The processes behind a session: whether its agent is still running, and which
/// app (the terminal) to bring forward to answer it there.
nonisolated enum AgentProcess {
    /// A process's parent and short name; nil once it has exited.
    static func info(_ pid: Int32) -> (parent: Int32, name: String)? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (info.kp_eproc.e_ppid, name)
    }

    /// `pid` and its ancestors, nearest first, up to (not including) launchd.
    static func ancestry(of pid: Int32) -> [(pid: Int32, name: String)] {
        var chain: [(Int32, String)] = []
        var current = pid
        while current > 1, chain.count < 32, let info = info(current) {
            chain.append((current, info.name))
            current = info.parent
        }
        return chain
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "nc", "env"]

    /// The agent itself: the first process up from the hook that is not a shell.
    static func agentPID(from hookParent: Int32) -> Int32? {
        ancestry(of: hookParent).first { !shells.contains($0.name) }?.pid
    }

    static func isRunning(_ pid: Int32) -> Bool { info(pid) != nil }

    /// Whether other processes can be looked up at all from here (the sandbox may
    /// not allow it); when not, nothing is judged gone by its pid.
    static let canSeeProcesses: Bool = info(1) != nil

    /// The app a session runs in: the first app up the process tree from the hook —
    /// a terminal (WezTerm, Terminal, iTerm) for a CLI session, or the agent's own
    /// app (Codex, Claude) for one started there.
    @MainActor
    static func hostApp(of pid: Int32) -> NSRunningApplication? {
        let chain = ancestry(of: pid)
        let app = chain.lazy.compactMap { NSRunningApplication(processIdentifier: $0.pid) }.first { $0.activationPolicy == .regular }
        Log.app.info("Agent sessions: host of \(pid) is \(app?.localizedName ?? "unknown", privacy: .public) via \(chain.map { "\($0.pid):\($0.name)" }.joined(separator: " → "), privacy: .public)")
        return app
    }
}
