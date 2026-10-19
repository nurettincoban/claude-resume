import Foundation
import Testing
@testable import ClaudeResume

@Suite("Codex accounts and history")
struct CodexTests {
    private let profile = AgentProfile(id: "codex-work", name: "Work", directory: URL(fileURLWithPath: "/tmp/codex-work", isDirectory: true), provider: .codex)
    private let defaultCodex = AgentProfile(id: "codex-default", name: "Codex", directory: AgentProfile.defaultCodexDirectory, provider: .codex)

    private func data(_ entries: [[String: Any]]) throws -> Data {
        var result = Data()
        for entry in entries {
            result.append(try JSONSerialization.data(withJSONObject: entry, options: [.withoutEscapingSlashes]))
            result.append(10)
        }
        return result
    }
    private func meta(source: Any = "cli") -> [String: Any] {
        ["type": "session_meta", "timestamp": "2026-10-17T10:00:00Z", "payload": ["id": "thread-id", "session_id": "session-id", "cwd": "/tmp/project", "source": source, "git": ["branch": "main"]]]
    }
    private func event(_ type: String, _ extra: [String: Any]) -> [String: Any] {
        ["type": "event_msg", "timestamp": "2026-10-17T10:05:00Z", "payload": extra.merging(["type": type]) { _, new in new }]
    }
    private func parse(_ entries: [[String: Any]]) throws -> Session? {
        CodexTranscriptParser.parse(try data(entries), profile: profile, url: URL(fileURLWithPath: "/tmp/test.jsonl"), modified: Date())
    }
    private func session(_ profile: AgentProfile, cwd: String = "/tmp/my project") -> Session {
        var session = Session(id: "thread", title: "Test", firstPrompt: nil, lastPrompt: nil, cwd: cwd, branch: nil,
                              promptCount: 1, startedAt: nil, lastActivity: Date(), transcriptURL: URL(fileURLWithPath: "/tmp/a.jsonl"),
                              profile: profile)
        session.resumeID = "resume-id"
        return session
    }

    @Test func readsPaginatedEventsWithoutCountingResponseCopies() throws {
        let user: [String: Any] = ["type": "UserMessage", "id": "u1", "content": [["type": "text", "text": "Fix checkout"]]]
        let assistant: [String: Any] = ["type": "AgentMessage", "id": "a1", "content": ["Fixed checkout; https://github.com/example/repo/pull/12"], "phase": "final_answer"]
        let session = try #require(try parse([
            meta(), event("user_message", ["message": "Fix checkout"]), event("item_completed", ["item": user]), event("item_completed", ["item": user]),
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fix checkout"]]]],
            ["type": "turn_context", "payload": ["model": "test-model"]],
            event("item_completed", ["item": assistant]),
            event("item_completed", ["item": ["type": "FileChange", "id": "f1", "changes": [["path": "/tmp/project/test.swift"]]]]),
            ["type": "token_usage_record", "payload": ["thread_token_usage": ["input_tokens": 100, "cached_input_tokens": 60, "output_tokens": 20, "reasoning_output_tokens": 10, "total_tokens": 120]]],
            event("token_count", ["info": ["total_token_usage": ["input_tokens": 100, "output_tokens": 20, "total_tokens": 120]]])
        ]))
        #expect(session.id == "thread-id")
        #expect(session.cliID == "session-id")
        #expect(session.key == "codex-work:thread-id")
        #expect(session.title == "Fix checkout")
        #expect(session.promptCount == 1)
        #expect(session.lastReply?.hasPrefix("Fixed checkout") == true)
        #expect(session.filesChanged == ["/tmp/project/test.swift"])
        #expect(session.pullRequests.count == 1)
        #expect(session.tokens == 120)
        #expect(session.outputTokens == 20)
        #expect(session.cost == nil)
        #expect(session.models == ["test-model"])
        #expect(session.branch == "main")
    }

    @Test func readsLegacyMessagesAndSkipsSubagents() throws {
        let entries = [meta(), event("user_message", ["message": "Explain this repo"]), event("agent_message", ["message": "A small app"])]
        let session = try #require(try parse(entries))
        #expect(session.promptCount == 1)
        #expect(session.lastReply == "A small app")
        #expect(try parse([meta(source: ["subagent": ["thread_spawn": [:]]])] + Array(entries.dropFirst())) == nil)
        #expect(CodexTranscriptParser.cleanPrompt("# AGENTS.md instructions") == nil)
        #expect(CodexTranscriptParser.cleanPrompt("<environment_context>private paths</environment_context>\nActual question") == "Actual question")
    }

    @Test func defaultCodexFolderKeepsTheShellEnvironment() {
        #expect(defaultCodex.usesDefaultFolder)
        #expect(Terminal.resumeCommand(for: session(defaultCodex))
            == "cd '/tmp/my project' && env CLAUDE_RESUME_SESSION='codex-default:thread' codex resume 'resume-id'")
        #expect(Terminal.resumeCommand(for: session(defaultCodex), fork: true, extraFlags: "--model test")
            == "cd '/tmp/my project' && env -u CLAUDE_RESUME_SESSION codex fork 'resume-id' --model test")
        #expect(Terminal.loginCommand(for: defaultCodex) == "env -u CLAUDE_RESUME_SESSION codex login")
    }

    @Test func otherCodexFoldersGetTheirOwnHomeAndNoShellCredentials() {
        #expect(!profile.usesDefaultFolder)
        let resume = Terminal.resumeCommand(for: session(profile))
        #expect(resume == "cd '/tmp/my project' && env -u OPENAI_API_KEY -u CODEX_API_KEY -u CODEX_ACCESS_TOKEN "
            + "CODEX_HOME='/tmp/codex-work' CLAUDE_RESUME_SESSION='codex-work:thread' codex resume 'resume-id'")
        #expect(Terminal.newCommand(for: profile, cwd: "/tmp") == "cd '/tmp' && env -u OPENAI_API_KEY -u CODEX_API_KEY -u CODEX_ACCESS_TOKEN -u CLAUDE_RESUME_SESSION CODEX_HOME='/tmp/codex-work' codex")
    }

    @Test func commandsRunWithTheRightEnvironment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-commands-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        let project = root.appendingPathComponent("project's folder")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // A stand-in for `codex` that prints what it was given. No real login is used.
        let executable = bin.appendingPathComponent("codex")
        try Data(#"""
        #!/bin/sh
        printf '%s\n' "${CODEX_HOME-unset}" "${OPENAI_API_KEY-unset}" "${CLAUDE_RESUME_SESSION-unset}" "$@"
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        func run(_ command: String) throws -> [String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["PATH": bin.path + ":/usr/bin:/bin", "OPENAI_API_KEY": "from-shell",
                                   "CLAUDE_RESUME_SESSION": "inherited"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }

        var other = session(AgentProfile(id: "work", name: "Work", directory: root.appendingPathComponent("work's home"), provider: .codex),
                            cwd: project.path)
        other.resumeID = "resume-id; echo wrong-account"
        #expect(try run(Terminal.resumeCommand(for: other))
            == [other.profile.directory.path, "unset", "work:thread", "resume", "resume-id; echo wrong-account"])
        #expect(try run(Terminal.resumeCommand(for: other, fork: true))
            == [other.profile.directory.path, "unset", "unset", "fork", "resume-id; echo wrong-account"])
        #expect(try run(Terminal.resumeCommand(for: session(defaultCodex, cwd: project.path)))
            == ["unset", "from-shell", "codex-default:thread", "resume", "resume-id"])
    }

    @Test func accountsSavedBeforeCodexAreClaudeAccounts() throws {
        let old = Data(#"{"id":"work","name":"Work","directory":"file:///tmp/claude-work/"}"#.utf8)
        #expect(try JSONDecoder().decode(AgentProfile.self, from: old).provider == .claude)
        let restored = try JSONDecoder().decode(AgentProfile.self, from: JSONEncoder().encode(profile))
        #expect(restored == profile)
        #expect(profile.label == "Work · Codex")
        #expect(defaultCodex.label == "Codex")
    }

    @Test func mapsAppServerStatuses() {
        #expect(CodexRuntime.status(type: "idle", flags: [])?.status == .idle)
        #expect(CodexRuntime.status(type: "active", flags: [])?.status == .busy)
        #expect(CodexRuntime.status(type: "active", flags: ["waitingOnApproval"])?.status == .waiting)
        #expect(CodexRuntime.status(type: "active", flags: ["waitingOnUserInput"])?.waitingFor == "input needed")
        #expect(CodexRuntime.status(type: "notLoaded", flags: []) == nil)
    }

    @Test func readsArgumentsButNotTheEnvironment() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/usr/local/bin/codex\0\0codex\0app-server\0SECRET=private\0\0".utf8)
        #expect(CodexRuntime.arguments(in: bytes) == ["codex", "app-server"])
        #expect(CodexRuntime.arguments(in: []) == [])
    }

    @Test @MainActor func unknownStatusIsNeitherBusyNorQuittable() {
        let codex = session(profile)
        let live = LiveSession(sessionId: codex.id, pid: 0, status: .idle, cwd: nil, statusKnown: false)
        let store = SessionStore(demo: [codex], live: [codex.key: live])
        #expect(!store.anyBusy)
        #expect(store.idleSessions(olderThan: 0).isEmpty)
        #expect(!live.hasProcess)
    }

    @Test @MainActor func accountFiltersAndNamesStayIndependent() {
        let claude = Session(id: "same", title: "Claude title", firstPrompt: nil, lastPrompt: nil, cwd: "/tmp", branch: nil,
                             promptCount: 1, startedAt: nil, lastActivity: Date(), transcriptURL: URL(fileURLWithPath: "/tmp/not-written.jsonl"))
        var codex = claude
        codex.profile = profile
        let store = SessionStore(demo: [claude, codex], live: [:])
        store.profileFilter = profile.id
        #expect(store.visible.map(\.key) == [codex.key])
        store.rename(codex, to: "Renamed Codex")
        #expect(store.session(codex.key)?.title == "Renamed Codex")
        #expect(store.session(claude.key)?.title == "Claude title")
        store.profileFilter = AgentProfile.personal.id
        #expect(store.visible.map(\.key) == [claude.key])
    }

    @Test func scannersReadEachHomeAndItsSessionIndexTitles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-scanner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var profiles: [AgentProfile] = []
        for name in ["codex", "codex-account-2"] {
            let home = root.appendingPathComponent(name)
            let directory = home.appendingPathComponent("sessions/2026/10/17")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data([meta(), event("user_message", ["message": "Question for \(name)"])]).write(to: directory.appendingPathComponent("rollout.jsonl"))
            try data([["id": "thread-id", "thread_name": "Renamed \(name)"]]).write(to: home.appendingPathComponent("session_index.jsonl"))
            profiles.append(AgentProfile(id: name, name: name, directory: home, provider: .codex))
        }
        let sessions = ProfileScanner().scan(profiles)
        #expect(Set(sessions.map(\.key)) == ["codex:thread-id", "codex-account-2:thread-id"])
        #expect(Set(sessions.map(\.title)) == ["Renamed codex", "Renamed codex-account-2"])
    }

    /// Talks to a real Codex app-server, read-only. Run with CODEX_DAEMON_SMOKE=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_DAEMON_SMOKE"] == "1"))
    func readsARunningCodexDaemonWithoutStartingATurn() throws {
        let connection = try CodexConnection(directory: AgentProfile.defaultCodexDirectory)
        let result = try connection.request("thread/loaded/list", params: ["limit": 100])
        let ids = try #require(result["data"] as? [String])
        if let id = ids.first {
            let thread = try #require(try connection.request("thread/read", params: ["threadId": id, "includeTurns": false])["thread"] as? [String: Any])
            #expect(thread["status"] is [String: Any])
        }
    }
}
