import Foundation
import Testing
@testable import ClaudeResume

@Suite("Transcript parsing")
struct TranscriptParserTests {
    private let url = URL(fileURLWithPath: "/tmp/s1.jsonl")
    private let modified = Date(timeIntervalSince1970: 0)

    private func user(_ content: String, time: String = "2026-10-13T10:00:00.000Z", extra: String = "") -> String {
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":\#(content)},"uuid":"u","timestamp":"\#(time)","cwd":"/Users/me/code/demo","gitBranch":"feat/x"\#(extra)}"#
    }

    private func assistant(time: String) -> String {
        #"{"parentUuid":"u","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[]},"timestamp":"\#(time)"}"#
    }

    private func parse(_ lines: [String]) -> Session? {
        TranscriptParser.parse(Data(lines.joined(separator: "\n").utf8), id: "s1", url: url, modified: modified)
    }

    @Test func usesFirstPromptWhenUntitled() throws {
        let session = try #require(parse([user(#""fix the  login\nbug""#)]))
        #expect(session.title == "fix the login bug")
        #expect(session.cwd == "/Users/me/code/demo")
        #expect(session.branch == "feat/x")
        #expect(session.promptCount == 1)
        #expect(session.folderName == "demo")
    }

    @Test func customTitleBeatsAITitleAndLastOneWins() throws {
        let session = try #require(parse([
            #"{"type":"ai-title","aiTitle":"First AI title","sessionId":"s1"}"#,
            user(#""hello""#),
            #"{"type":"custom-title","customTitle":"Old name","sessionId":"s1"}"#,
            #"{"type":"custom-title","customTitle":"New name","sessionId":"s1"}"#,
            #"{"type":"ai-title","aiTitle":"Later AI title","sessionId":"s1"}"#,
        ]))
        #expect(session.title == "New name")
    }

    @Test func ignoresUntitledPlaceholder() throws {
        let session = try #require(parse([
            #"{"type":"custom-title","customTitle":"Untitled session","sessionId":"s1"}"#,
            #"{"type":"ai-title","aiTitle":"Design tier progression","sessionId":"s1"}"#,
            user(#""hello""#),
        ]))
        #expect(session.title == "Design tier progression")
    }

    @Test func skipsToolResultsMetaAndNotifications() throws {
        let session = try #require(parse([
            user(#""<local-command-caveat>Caveat: ignore</local-command-caveat>""#, extra: #","isMeta":true"#),
            user(#"[{"type":"tool_result","tool_use_id":"t","content":"output"}]"#),
            user(#""<task-notification>done</task-notification>""#, extra: #","origin":{"kind":"task-notification"}"#),
            user(#"[{"type":"text","text":"skill instructions"}]"#, extra: #","isMeta":true"#),
            user(#""real question""#, extra: #","origin":{"kind":"human"}"#),
        ]))
        #expect(session.title == "real question")
        #expect(session.promptCount == 1)
    }

    @Test func emptySessionsAreDropped() {
        #expect(parse([
            #"{"type":"mode","mode":"normal","sessionId":"s1"}"#,
            user(#"[{"type":"tool_result","tool_use_id":"t","content":"x"}]"#),
        ]) == nil)
    }

    @Test func slashCommandsBecomeReadable() {
        #expect(TranscriptParser.cleanPrompt(
            "<command-message>plan</command-message>\n<command-name>/plan</command-name>\n<command-args>add login</command-args>"
        ) == "/plan add login")
        #expect(TranscriptParser.cleanPrompt("<command-name>/clear</command-name>") == nil)
        #expect(TranscriptParser.cleanPrompt("look at\n\n<pasted_content id=\"a\">lots\nof\ntext</pasted_content>")
            == "look at [pasted text]")
    }

    @Test func lastActivityComesFromMessagesNotFileDate() throws {
        let session = try #require(parse([
            user(#""hi""#, time: "2026-10-13T10:00:00.000Z"),
            assistant(time: "2026-10-13T10:05:00.000Z"),
            #"{"type":"last-prompt","lastPrompt":"hi","sessionId":"s1"}"#,
        ]))
        #expect(session.lastActivity == TranscriptParser.parseDate("2026-10-13T10:05:00.000Z"))
        #expect(session.startedAt == TranscriptParser.parseDate("2026-10-13T10:00:00.000Z"))
    }

    @Test func scannerReadsTopLevelTranscriptsOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-resume-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-Users-me-code-demo")
        let nested = project.appendingPathComponent("abc/subagents")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(user(#""top level""#).utf8).write(to: project.appendingPathComponent("abc.jsonl"))
        try Data(user(#""subagent""#).utf8).write(to: nested.appendingPathComponent("agent-1.jsonl"))

        let sessions = SessionScanner(root: root).scan()
        #expect(sessions.map(\.id) == ["abc"])
        #expect(sessions.first?.title == "top level")
    }
}

@Suite("Commands and grouping")
struct CommandTests {
    private func session(_ id: String, cwd: String? = "/Users/me/my project", ago: TimeInterval = 0, now: Date) -> Session {
        Session(id: id, title: id, firstPrompt: id, lastPrompt: id, cwd: cwd, branch: nil, promptCount: 1,
                startedAt: nil, lastActivity: now.addingTimeInterval(-ago), transcriptURL: URL(fileURLWithPath: "/tmp"))
    }

    @Test func shellQuoting() {
        #expect(ITerm.shellQuote("/Users/me/it's here") == #"'/Users/me/it'\''s here'"#)
        #expect(ITerm.appleScriptString(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    }

    @Test func resumeCommand() {
        let now = Date()
        let s = session("abc-123", now: now)
        #expect(ITerm.resumeCommand(for: s) == "cd '/Users/me/my project' && claude --resume abc-123")
        #expect(ITerm.resumeCommand(for: s, fork: true, extraFlags: " --model opus ")
            == "cd '/Users/me/my project' && claude --resume abc-123 --fork-session --model opus")
        #expect(ITerm.resumeCommand(for: session("x", cwd: nil, now: now)) == "claude --resume x")
    }

    @Test func groupsByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")!
        let sessions = [
            session("today", ago: 3600, now: now),
            session("yesterday", ago: 86400, now: now),
            session("week", ago: 3 * 86400, now: now),
            session("month", ago: 20 * 86400, now: now),
            session("old", ago: 80 * 86400, now: now),
        ]
        let sections = SessionStore.group(sessions, now: now, calendar: calendar)
        #expect(sections.map(\.id) == ["today", "yesterday", "week", "month", "m2026-7"])
        #expect(sections.map { $0.sessions.map(\.id) } == [["today"], ["yesterday"], ["week"], ["month"], ["old"]])
    }

    @Test @MainActor func searchMatchesEveryTerm() {
        let now = Date()
        var a = session("a", now: now); a.title = "Refactor checkout flow"
        var b = session("b", now: now); b.title = "Checkout tests"; b.branch = "fix/flaky"
        let store = SessionStore(demo: [a, b], live: [:])
        store.query = "checkout flaky"
        #expect(store.visible.map(\.id) == ["b"])
        store.query = ""
        store.filter = .running
        #expect(store.visible.isEmpty)
    }
}

@Suite("Session details")
struct SessionDetailTests {
    private let url = URL(fileURLWithPath: "/tmp/s1.jsonl")

    private func parse(_ lines: [String]) -> Session? {
        TranscriptParser.parse(Data(lines.joined(separator: "\n").utf8), id: "s1", url: url, modified: Date())
    }

    private let prompt = #"{"isSidechain":false,"type":"user","message":{"role":"user","content":"do it"},"timestamp":"2026-10-13T10:00:00.000Z","cwd":"/Users/me/code/demo"}"#

    private func assistant(id: String, request: String, content: String, output: Int = 100) -> String {
        #"{"parentUuid":"u","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"\#(id)","type":"message","role":"assistant","content":\#(content),"stop_reason":null,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000,"output_tokens":\#(output),"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"iterations":[{"type":"message"}],"speed":"standard"}},"requestId":"\#(request)","type":"assistant","timestamp":"2026-10-13T10:01:00.000Z"}"#
    }

    @Test func readsRecapLinksFilesReplyAndUsage() throws {
        let session = try #require(parse([
            prompt,
            assistant(id: "msg_1", request: "req_1", content: #"[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/Users/me/code/demo/a.swift","old_string":"x","new_string":"y"}}]"#),
            // The same response written as a second line must not be counted twice.
            assistant(id: "msg_1", request: "req_1", content: #"[{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"/Users/me/code/demo/b.swift","content":"{ \"usage\": 1 }"}}]"#),
            assistant(id: "msg_2", request: "req_2", content: ###"[{"type":"text","text":"## Done\n**All** tests pass."}]"###, output: 50),
            #"{"type":"pr-link","sessionId":"s1","prNumber":455,"prUrl":"https://gitlab.example.com/team/svc/-/merge_requests/455","prRepository":"team/svc","timestamp":"2026-10-13T10:02:00.000Z"}"#,
            #"{"type":"frame-link","sessionId":"s1","frameUrl":"https://claude.ai/code/artifact/abc","title":"Design brief","artifactCount":1}"#,
            #"{"parentUuid":"x","isSidechain":false,"type":"system","subtype":"away_summary","content":"MR !455 is open. Next: watch CI. (disable recaps in /config)","timestamp":"2026-10-13T10:03:00.000Z"}"#,
        ]))
        #expect(session.recap == "MR !455 is open. Next: watch CI.")
        #expect(session.lastReply == "Done\nAll tests pass.")
        #expect(session.filesChanged == ["/Users/me/code/demo/b.swift", "/Users/me/code/demo/a.swift"])
        #expect(session.pullRequests.map(\.label) == ["!455"])
        #expect(session.pullRequests.first?.detail == "Merge request !455 · svc")
        #expect(session.artifacts.map(\.label) == ["Design brief"])
        #expect(session.outputTokens == 150)
        #expect(session.tokens == 2 * (10 + 1000) + 150)
        #expect(session.models == ["Opus 5.5"])
        #expect((session.cost ?? 0) > 0)
    }

    @Test func recordedCostWinsWhenLarger() throws {
        let session = try #require(parse([
            prompt,
            assistant(id: "msg_1", request: "req_1", content: #"[{"type":"text","text":"hi"}]"#),
            #"{"type":"cost-state","sessionId":"s1","totalCostUSD":12.5}"#,
        ]))
        #expect(session.cost == 12.5)
    }
}

@Suite("Search")
struct SearchTests {
    private func session(_ title: String, branch: String? = nil) -> Session {
        Session(id: UUID().uuidString, title: title, firstPrompt: nil, lastPrompt: nil, cwd: "/Users/me/code/demo",
                branch: branch, promptCount: 1, startedAt: nil, lastActivity: Date(), transcriptURL: URL(fileURLWithPath: "/tmp"))
    }

    @Test func fuzzyMatchesAbbreviations() throws {
        let match = try #require(Search.match(session("Firmware update process analysis"), terms: ["frmw", "upd"]))
        let title = "Firmware update process analysis"
        let highlighted = match.titleRanges.map { String(title[$0]) }
        #expect(highlighted.joined().lowercased().contains("upd"))
        #expect(Search.match(session("Firmware update"), terms: ["xyz"]) == nil)
    }

    @Test func titleMatchesRankAboveBranchMatches() throws {
        let inTitle = try #require(Search.match(session("Checkout tests"), terms: ["checkout"]))
        let inBranch = try #require(Search.match(session("Tests", branch: "feat/checkout"), terms: ["checkout"]))
        #expect(inTitle.score > inBranch.score)
    }

    @Test func ignoresCaseAndDiacritics() {
        #expect(Search.match(session("Bu repo nasıl çalışıyor?"), terms: ["calis"]) != nil)
    }

    @Test func looseMatchesMustBeTight() {
        // "abc" spread over a long title is not a match.
        #expect(Search.fuzzyRanges("abc", in: "a long title with b and eventually c") == nil)
    }
}

@Suite("Store")
@MainActor
struct StoreTests {
    private func session(_ id: String, ago: TimeInterval = 0) -> Session {
        Session(id: id, title: id, firstPrompt: nil, lastPrompt: nil, cwd: "/tmp", branch: nil, promptCount: 1,
                startedAt: nil, lastActivity: Date().addingTimeInterval(-ago),
                transcriptURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    @Test func pinnedSessionsComeFirstAndHiddenOnesDisappear() {
        let sessions = [session("a", ago: 60), session("b", ago: 120), session("c", ago: 180)]
        let store = SessionStore(demo: sessions, live: [:], pinned: ["c"])
        #expect(store.sections.first?.id == "pinned")
        #expect(store.visible.map(\.id) == ["c", "a", "b"])
        store.toggleHidden(store.session("a")!)
        #expect(store.visible.map(\.id) == ["c", "b"])
        store.showHidden = true
        #expect(store.visible.count == 3)
    }

    @Test func noticesFinishedTurns() {
        let store = SessionStore(demo: [session("a")], live: [:])
        let start = Date()
        store.trackTurns(["a": LiveSession(sessionId: "a", pid: 1, status: .busy, cwd: nil, statusSince: start)], now: start)
        #expect(store.finished.isEmpty)
        store.trackTurns(["a": LiveSession(sessionId: "a", pid: 1, status: .idle, cwd: nil)], now: start.addingTimeInterval(45))
        #expect(store.finished["a"] == 45)
    }

    @Test func renameAppendsCustomTitleLine() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"type":"user"}"#.utf8).write(to: file) // no trailing newline on purpose
        try TranscriptWriter.appendTitle("New “name”", sessionId: "s1", to: file)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let entry = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: String]
        #expect(entry == ["type": "custom-title", "customTitle": "New “name”", "sessionId": "s1"])
    }
}
