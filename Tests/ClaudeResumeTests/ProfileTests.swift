import Darwin
import Foundation
import Testing
@testable import ClaudeResume

@Suite("Accounts")
struct ProfileTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resume-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func transcript(_ title: String) -> Data {
        Data(#"{"type":"user","message":{"role":"user","content":"\#(title)"},"cwd":"/tmp","timestamp":"2026-10-17T10:00:00Z"}"#.utf8)
    }

    private func session(_ id: String, profile: AgentProfile = .personal, cwd: String? = "/tmp") -> Session {
        Session(id: id, title: "Task \(id)", firstPrompt: nil, lastPrompt: nil, cwd: cwd, branch: nil,
                promptCount: 1, startedAt: nil, lastActivity: Date(),
                transcriptURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"), profile: profile)
    }

    @Test func combinesHistoriesWithoutCollidingIDs() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = AgentProfile(id: "default", name: "Personal", directory: root.appendingPathComponent("personal"))
        let work = AgentProfile(id: "work", name: "Work", directory: root.appendingPathComponent("work"))
        for profile in [personal, work] {
            let project = profile.projectsRoot.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try transcript(profile.name).write(to: project.appendingPathComponent("same-id.jsonl"))
        }
        let scanner = ProfileScanner()
        let sessions = scanner.scan([personal, work])
        #expect(sessions.count == 2)
        #expect(Set(sessions.map(\.id)) == ["same-id"])
        #expect(Set(sessions.map(\.key)) == ["same-id", "work:same-id"])
        #expect(Set(sessions.map(\.profile)) == [personal, work])
        let file = work.projectsRoot.appendingPathComponent("project/same-id.jsonl")
        try transcript("Updated work conversation").write(to: file)
        #expect(scanner.scan([personal, work]).first(where: { $0.profile.id == "work" })?.title == "Updated work conversation")
        #expect(scanner.scan([personal]).count == 1)
    }

    @Test func scansEachAccountsRunningSessions() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = [AgentProfile(id: "default", name: "Personal", directory: root.appendingPathComponent("a")),
                        AgentProfile(id: "b", name: "B", directory: root.appendingPathComponent("b"))]
        for profile in profiles {
            try FileManager.default.createDirectory(at: profile.sessionsRoot, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["sessionId": "same-id", "pid": getpid(), "status": "idle"])
            try data.write(to: profile.sessionsRoot.appendingPathComponent("\(getpid()).json"))
        }
        #expect(Set(LiveSessions.scan(profiles: profiles).keys) == ["same-id", "b:same-id"])
    }

    @Test func persistsAccountsAndRejectsDuplicateFolders() throws {
        let name = "ClaudeResumeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ProfilePreferences.load(from: defaults) == [.personal])
        let work = AgentProfile(id: "work", name: "Work", directory: AgentProfile.canonicalDirectory("/tmp/claude-work"))
        let duplicate = AgentProfile(id: "copy", name: "Copy", directory: work.directory)
        let personalCopy = AgentProfile(id: "home", name: "Home", directory: AgentProfile.personal.directory)
        ProfilePreferences.save([.personal, work, duplicate, personalCopy], to: defaults)
        #expect(ProfilePreferences.load(from: defaults) == [.personal, work])
        ProfilePreferences.save([.personal], to: defaults)
        #expect(ProfilePreferences.load(from: defaults) == [.personal])
    }

    @Test func personalCommandsAreUnchanged() {
        #expect(Terminal.claude(for: .personal) == "claude")
        #expect(Terminal.resumeCommand(for: session("abc")) == "cd '/tmp' && claude --resume abc")
        #expect(Terminal.loginCommand(for: .personal) == "claude auth login")
        #expect(Terminal.newCommand(for: .personal, cwd: "/tmp/my project") == "cd '/tmp/my project' && claude")
    }

    @Test func otherAccountsGetTheirOwnFolderAndNoShellCredentials() {
        let work = AgentProfile(id: "work", name: "Work", directory: URL(fileURLWithPath: "/tmp/work's account"))
        let command = Terminal.resumeCommand(for: session("abc", profile: work), fork: true)
        #expect(command == "cd '/tmp' && env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN "
            + #"CLAUDE_CONFIG_DIR='/tmp/work'\''s account' claude --resume abc --fork-session"#)
        #expect(Terminal.loginCommand(for: work).hasSuffix("' claude auth login"))
        #expect(Terminal.newCommand(for: work, cwd: "/tmp") == "cd '/tmp' && \(Terminal.claude(for: work))")
    }

    @Test func commandsRunWithTheRightEnvironment() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        let project = root.appendingPathComponent("project's folder")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // A stand-in for `claude` that prints what it was given. No real login is used.
        let executable = bin.appendingPathComponent("claude")
        try Data(#"""
        #!/bin/sh
        printf '%s\n' "${CLAUDE_CONFIG_DIR-unset}" "${ANTHROPIC_API_KEY-unset}" "$@"
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        func run(_ command: String) throws -> [String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["PATH": bin.path + ":/usr/bin:/bin", "ANTHROPIC_API_KEY": "from-shell"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return String(decoding: bytes, as: UTF8.self).split(separator: "\n").map(String.init)
        }

        #expect(try run(Terminal.resumeCommand(for: session("abc", cwd: project.path)))
            == ["unset", "from-shell", "--resume", "abc"])
        let work = AgentProfile(id: "work", name: "Work", directory: root.appendingPathComponent("work's config"))
        #expect(try run(Terminal.resumeCommand(for: session("abc", profile: work, cwd: project.path)))
            == [work.directory.path, "unset", "--resume", "abc"])
        #expect(try run(Terminal.loginCommand(for: work)) == [work.directory.path, "unset", "auth", "login"])
    }

    @Test @MainActor func filtersPinsAndHidesWithinTheRightAccount() {
        let work = AgentProfile(id: "work", name: "Work", directory: URL(fileURLWithPath: "/tmp/work"))
        let personal = session("same")
        let other = session("same", profile: work)
        let store = SessionStore(demo: [personal, other],
                                 live: [other.key: LiveSession(sessionId: other.id, pid: 1, status: .idle, cwd: nil)])
        #expect(store.profiles == [.personal, work])
        store.profileFilter = work.id
        #expect(store.visible.map(\.key) == [other.key])
        #expect(store.selectedSession?.profile == work)
        store.togglePin(other)
        #expect(store.pinned == [other.key])
        store.toggleHidden(other)
        store.profileFilter = nil
        #expect(store.visible.map(\.key) == [personal.key])
        store.showHidden = true
        store.filter = .running
        #expect(store.visible.map(\.key) == [other.key])
    }

    @Test @MainActor func addingAndRemovingLeavesAccountDataAlone() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(demo: [], live: [:])
        let directory = root.appendingPathComponent("new-account")
        let profile = try #require(store.addProfile(name: "Work", directory: directory.path))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(store.addProfile(name: "Duplicate", directory: directory.path) == nil)
        #expect(store.addProfile(name: "Personal again", directory: "~/.claude") == nil)
        #expect(store.addProfile(name: "", directory: root.appendingPathComponent("other").path) == nil)
        #expect(store.addProfile(name: "Relative", directory: "relative-folder") == nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = directory.appendingPathComponent("keep.jsonl")
        try Data("keep".utf8).write(to: history)
        store.removeProfile(profile)
        #expect(FileManager.default.fileExists(atPath: history.path))
        #expect(store.profiles == [.personal])
    }
}
