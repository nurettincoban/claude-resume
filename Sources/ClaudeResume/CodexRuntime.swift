import CryptoKit
import Darwin
import Foundation

// Everything that talks to a running Codex lives in this file. The protocol is Codex's local
// app-server control socket, which isn't a stable API: any failure here falls back to reading
// rollout files only, and removing this file leaves Codex history working.

/// JSON-RPC over WebSocket on `<CODEX_HOME>/app-server-control/app-server-control.sock`.
/// Only connects to a daemon that is already running; never starts or stops one.
final class CodexConnection {
    struct Failure: Error { }
    private var descriptor: Int32 = -1
    private var nextID = 0

    init(directory: URL) throws {
        let path = directory.appendingPathComponent("app-server-control/app-server-control.sock").path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw Failure() }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure() }
        do {
            var timeout = timeval(tv_sec: 1, tv_usec: 0), noSignal: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                bytes.copyBytes(from: Array(path.utf8) + [0])
            }
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard status == 0 else { throw Failure() }
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            try sendBytes(Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
            var header = Data()
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]), header.count < 16_384 { header.append(try readBytes(1)) }
            let response = String(decoding: header, as: UTF8.self)
            let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let accept = response.components(separatedBy: "\r\n").compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "sec-websocket-accept" else { return nil }
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }.first
            guard response.hasPrefix("HTTP/1.1 101 "), accept == expected else { throw Failure() }
            _ = try request("initialize", params: ["clientInfo": ["name": "claude_resume", "version": "1.0.0"], "capabilities": ["experimentalApi": false]])
            try sendFrame(Data(#"{"method":"initialized","params":{}}"#.utf8))
        } catch {
            Darwin.close(descriptor); descriptor = -1
            throw error
        }
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try sendFrame(JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]))
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let bytes = try readMessage()
            guard let message = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { continue }
            guard message["id"] as? Int == id else { continue }
            guard let result = message["result"] as? [String: Any] else { throw Failure() }
            return result
        }
        throw Failure()
    }

    private func sendBytes(_ bytes: Data) throws {
        try bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                guard count > 0 else { throw Failure() }
                sent += count
            }
        }
    }

    private func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= 16 * 1024 * 1024 else { throw Failure() }
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { buffer in
            var received = 0
            while received < count {
                let length = Darwin.recv(descriptor, buffer.baseAddress!.advanced(by: received), count - received, 0)
                guard length > 0 else { throw Failure() }
                received += length
            }
        }
        return bytes
    }

    private func sendFrame(_ bytes: Data, opcode: UInt8 = 1) throws {
        var frame = Data([0x80 | opcode])
        if bytes.count < 126 { frame.append(0x80 | UInt8(bytes.count)) }
        else if bytes.count <= 65_535 {
            frame.append(0x80 | 126)
            frame.append(UInt8((bytes.count >> 8) & 255)); frame.append(UInt8(bytes.count & 255))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(bytes.count) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: bytes.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try sendBytes(frame)
    }

    private func readMessage() throws -> Data {
        var message = Data()
        while true {
            let header = [UInt8](try readBytes(2))
            let opcode = header[0] & 15
            var length = UInt64(header[1] & 127)
            if length == 126 { length = (try readBytes(2)).reduce(0) { $0 << 8 | UInt64($1) } }
            else if length == 127 { length = (try readBytes(8)).reduce(0) { $0 << 8 | UInt64($1) } }
            guard length <= 16 * 1024 * 1024 else { throw Failure() }
            let mask = header[1] & 128 != 0 ? [UInt8](try readBytes(4)) : []
            var payload = try readBytes(Int(length))
            if !mask.isEmpty { payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }) }
            if opcode == 8 { throw Failure() }
            if opcode == 9 { try sendFrame(payload, opcode: 10); continue }
            if opcode == 10 { continue }
            guard opcode == 0 || opcode == 1 else { throw Failure() }
            message.append(payload)
            guard message.count <= 16 * 1024 * 1024 else { throw Failure() }
            if header[0] & 128 != 0 { return message }
        }
    }
}

enum CodexRuntime {
    private static let lock = NSLock()
    private static var connections: [URL: CodexConnection] = [:]
    private static var previous: [String: LiveSession] = [:]

    struct Failure: Error, LocalizedError {
        var errorDescription: String? {
            "Codex isn't reachable. Start Codex and try again, or rename the conversation in Codex."
        }
    }

    /// Saves a conversation's name in Codex, so `codex resume` shows it too.
    static func rename(_ session: Session, to name: String) throws {
        try lock.withLock {
            do {
                _ = try connection(session.profile).request("thread/name/set", params: ["threadId": session.id, "name": name])
            } catch {
                connections[session.profile.directory] = nil
                throw Failure()
            }
        }
    }

    /// Running Codex conversations keyed by `Session.key`.
    ///
    /// With the app-server: every loaded top-level thread and its status. Without it, or when the
    /// protocol has changed: only clients ClaudeResume launched, with an unknown status.
    static func scan(_ profile: AgentProfile) -> [String: LiveSession] {
        let frontends = codexFrontends(profile: profile)
        return lock.withLock {
            var result: [String: LiveSession] = [:]
            for (key, thread) in loadedThreads(profile) ?? [:] {
                let old = previous[key]
                result[key] = LiveSession(sessionId: thread.id, pid: frontends[key] ?? 0, status: thread.status,
                                          cwd: thread.cwd, statusSince: old?.status == thread.status ? old?.statusSince : Date(),
                                          waitingFor: thread.waitingFor)
            }
            for (key, pid) in frontends where result[key] == nil {
                result[key] = LiveSession(sessionId: String(key.split(separator: ":").last ?? ""), pid: pid,
                                          status: .idle, cwd: nil, statusKnown: false)
            }
            previous = previous.filter { !$0.key.hasPrefix(profile.id + ":") }.merging(result) { _, new in new }
            return result
        }
    }

    private struct LoadedThread {
        let id: String
        let status: LiveSession.Status
        let cwd: String?
        let waitingFor: String?
    }

    /// Nil when there's no daemon or it answered something unexpected.
    private static func loadedThreads(_ profile: AgentProfile) -> [String: LoadedThread]? {
        do {
            let client = try connection(profile)
            var ids: [String] = [], cursor: String?
            repeat {
                var params: [String: Any] = ["limit": 100]
                if let cursor { params["cursor"] = cursor }
                let page = try client.request("thread/loaded/list", params: params)
                guard let data = page["data"] as? [String] else { throw CodexConnection.Failure() }
                ids += data
                let next = page["nextCursor"] as? String
                guard next == nil || next != cursor else { throw CodexConnection.Failure() }
                cursor = next
            } while cursor != nil
            var result: [String: LoadedThread] = [:]
            for id in ids {
                guard let thread = try client.request("thread/read", params: ["threadId": id, "includeTurns": false])["thread"] as? [String: Any],
                      thread["parentThreadId"] as? String == nil,
                      let state = thread["status"] as? [String: Any], let type = state["type"] as? String,
                      let status = status(type: type, flags: state["activeFlags"] as? [String] ?? [])
                else { continue }
                result[profile.sessionKey(id)] = LoadedThread(id: id, status: status.status, cwd: thread["cwd"] as? String,
                                                        waitingFor: status.waitingFor)
            }
            return result
        } catch {
            connections[profile.directory] = nil
            return nil
        }
    }

    static func status(type: String, flags: [String]) -> (status: LiveSession.Status, waitingFor: String?)? {
        switch type {
        case "idle": return (.idle, nil)
        case "active":
            if flags.contains("waitingOnApproval") { return (.waiting, "approval needed") }
            if flags.contains("waitingOnUserInput") { return (.waiting, "input needed") }
            return (.busy, nil)
        default: return nil
        }
    }

    private static func connection(_ profile: AgentProfile) throws -> CodexConnection {
        if let existing = connections[profile.directory] { return existing }
        let client = try CodexConnection(directory: profile.directory)
        connections[profile.directory] = client
        return client
    }

    // MARK: Clients launched by ClaudeResume

    /// Codex clients ClaudeResume launched for this account, keyed by `Session.key`. They carry
    /// `CLAUDE_RESUME_SESSION`, and the shared app-server daemon is skipped.
    static func codexFrontends(profile: AgentProfile) -> [String: pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [:] }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        let status = processes.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return [:] }
        let home = AgentProfile.canonicalDirectory(profile.directory.path)
        var result: [String: pid_t] = [:]
        for process in processes.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            var comm = process.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == "codex" || name.hasPrefix("codex-"),
                  let bytes = LiveSessions.processBytes(process.kp_proc.p_pid),
                  let key = LiveSessions.environmentValue(sessionMarker, in: bytes), key.hasPrefix(profile.id + ":"),
                  AgentProfile.canonicalDirectory(LiveSessions.environmentValue("CODEX_HOME", in: bytes)
                      ?? AgentProfile.defaultCodexDirectory.path) == home,
                  !arguments(in: bytes).contains("app-server") else { continue }
            result[key] = process.kp_proc.p_pid
        }
        return result
    }

    /// Set on Codex clients ClaudeResume launches, to the conversation's `Session.key`.
    static let sessionMarker = "CLAUDE_RESUME_SESSION"

    /// argv from KERN_PROCARGS2: argc, executable path, padding, then the arguments.
    static func arguments(in bytes: [UInt8]) -> [String] {
        guard bytes.count > 4 else { return [] }
        let argc = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard argc > 0, argc < bytes.count else { return [] }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            if index < bytes.count { index += 1 }
        }
        return result
    }
}
