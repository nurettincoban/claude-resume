import Darwin
import Foundation

/// A Claude Code process that is running right now, from `~/.claude/sessions/<pid>.json`.
struct LiveSession: Hashable, Sendable {
    /// `waiting` means Claude is blocked on you: a permission prompt or a question.
    enum Status: String, Sendable { case busy, idle, waiting }

    let sessionId: String
    let pid: pid_t
    let status: Status
    let cwd: String?
    /// When the status last changed.
    var statusSince: Date?
    /// Why a waiting session is waiting, as Claude Code words it (e.g. "input needed").
    var waitingFor: String?
    /// False for a Codex client found without its app-server: it runs, but whether it's working
    /// is unknown. It shows as idle and never counts as busy.
    var statusKnown = true

    /// The controlling terminal, e.g. `/dev/ttys012`, used to find the process's iTerm2 tab.
    var tty: String? { LiveSessions.tty(of: pid) }
}

extension LiveSession.Status {
    /// Which status to show when two processes claim one session.
    var urgency: Int {
        switch self {
        case .waiting: 2
        case .busy: 1
        case .idle: 0
        }
    }
}

extension LiveSession {
    /// Whether there's a process of ours to switch to or quit. A Codex conversation loaded in
    /// another Codex client has none.
    var hasProcess: Bool { pid > 0 }

    /// `waitingFor` as a sentence-case label, e.g. "Input needed".
    var waitingLabel: String {
        guard let reason = waitingFor else { return "Needs your input" }
        return reason.prefix(1).uppercased() + reason.dropFirst()
    }
}

enum LiveSessions {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)

    /// Read only specific terminal markers; never log a process's environment.
    static func processBytes(_ pid: pid_t) -> [UInt8]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        // A nil-buffer query reports argv's size only, truncating the environment.
        var size = Int(sysconf(_SC_ARG_MAX))
        guard size > 4, size <= 8 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        return Array(bytes.prefix(size))
    }

    /// KERN_PROCARGS2 contains argc, executable path, padding, argv, then environment.
    static func environmentValue(_ name: String, in bytes: [UInt8]) -> String? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard argc > 0, argc < bytes.count else { return nil }
        var index = 4
        func skipString() -> Bool {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            guard index < bytes.count else { return false }
            index += 1
            return true
        }
        guard skipString() else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        for _ in 0..<argc { guard skipString() else { return nil } }
        let prefix = Array((name + "=").utf8)
        while index < bytes.count, bytes[index] != 0 {
            let start = index
            guard skipString() else { return nil }
            let value = bytes[start..<(index - 1)]
            if value.starts(with: prefix) { return String(bytes: value.dropFirst(prefix.count), encoding: .utf8) }
        }
        return nil
    }

    /// Running sessions across accounts, keyed by `Session.key`.
    static func scan(profiles: [AgentProfile]) -> [String: LiveSession] {
        var result: [String: LiveSession] = [:]
        for profile in profiles {
            if profile.provider == .codex {
                result.merge(CodexRuntime.scan(profile)) { _, new in new }
                continue
            }
            for (id, live) in scan(root: profile.sessionsRoot) { result[profile.sessionKey(id)] = live }
        }
        return result
    }

    /// Running sessions keyed by session id. Registry files left behind by crashed processes are ignored.
    static func scan(root: URL = defaultRoot) -> [String: LiveSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [:] }
        var result: [String: LiveSession] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = entry["sessionId"] as? String,
                  let pid = (entry["pid"] as? NSNumber)?.int32Value,
                  isAlive(pid) else { continue }
            let live = LiveSession(
                sessionId: id,
                pid: pid,
                status: LiveSession.Status(rawValue: entry["status"] as? String ?? "") ?? .idle,
                cwd: entry["cwd"] as? String,
                statusSince: (entry["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                waitingFor: (entry["waitingFor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
            // Two processes can claim one session (a resume next to the original); the one that
            // needs attention wins.
            if let existing = result[id], existing.status.urgency >= live.status.urgency { continue }
            result[id] = live
        }
        return result
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    static func tty(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }
}
