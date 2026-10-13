import Darwin
import Foundation

/// A Claude Code process that is running right now, from `~/.claude/sessions/<pid>.json`.
struct LiveSession: Hashable, Sendable {
    enum Status: String, Sendable { case busy, idle }

    let sessionId: String
    let pid: pid_t
    let status: Status
    let cwd: String?
    /// When the status last changed.
    var statusSince: Date?

    /// The controlling terminal, e.g. `/dev/ttys012`, used to find the process's iTerm2 tab.
    var tty: String? { LiveSessions.tty(of: pid) }
}

enum LiveSessions {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)

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
                statusSince: (entry["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            )
            // Two processes can claim one session (a resume next to the original); busy wins.
            if let existing = result[id], existing.status == .busy { continue }
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
