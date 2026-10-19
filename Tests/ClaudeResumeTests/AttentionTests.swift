import Foundation
import Testing
@testable import ClaudeResume

@Suite("Needs you, last turn and cost labels")
@MainActor
struct AttentionTests {
    private func session(_ id: String, ago: TimeInterval = 0) -> Session {
        Session(id: id, title: id, firstPrompt: nil, lastPrompt: nil, cwd: "/tmp", branch: nil, promptCount: 1,
                startedAt: nil, lastActivity: Date().addingTimeInterval(-ago),
                transcriptURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    private func live(_ id: String, _ status: LiveSession.Status, since: Date? = nil) -> LiveSession {
        LiveSession(sessionId: id, pid: 1, status: status, cwd: nil, statusSince: since)
    }

    @Test func waitingIsAnnouncedOnceAndDoesNotEndTheTurn() {
        let start = Date()
        let store = SessionStore(demo: [session("a")], live: ["a": live("a", .busy, since: start)])
        store.trackTurns(["a": live("a", .busy, since: start)], now: start)
        store.trackTurns(["a": live("a", .waiting)], now: start.addingTimeInterval(30))
        #expect(store.needsInput == ["a"])
        #expect(store.finished.isEmpty)
        store.trackTurns(["a": live("a", .idle)], now: start.addingTimeInterval(90))
        #expect(store.finished["a"] == 90)
    }

    @Test func waitingSessionsComeFirst() {
        let sessions = [session("new", ago: 10), session("old", ago: 9000)]
        let store = SessionStore(demo: sessions, live: ["old": live("old", .waiting)], pinned: ["new"])
        #expect(store.sections.map(\.id).prefix(2) == ["waiting", "pinned"])
        #expect(store.visible.first?.id == "old")
        #expect(store.waitingCount == 1)
    }

    @Test func registryReadsWaitingStatusAndReason() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pid = ProcessInfo.processInfo.processIdentifier
        let entry = #"{"pid":\#(pid),"sessionId":"s1","status":"waiting","waitingFor":"input needed","statusUpdatedAt":1791808723879}"#
        try Data(entry.utf8).write(to: root.appendingPathComponent("\(pid).json"))
        let found = try #require(LiveSessions.scan(root: root)["s1"])
        #expect(found.status == .waiting)
        #expect(found.waitingLabel == "Input needed")
    }

    @Test func lastTurnCoversOnlyTheLatestPrompt() throws {
        func user(_ text: String, _ time: String) -> String {
            #"{"isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"timestamp":"\#(time)","cwd":"/tmp"}"#
        }
        func edit(_ id: String, _ time: String) -> String {
            #"{"isSidechain":false,"message":{"model":"claude-opus-5-5","id":"\#(id)","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t","name":"Edit","input":{"file_path":"/tmp/\#(id).swift"}}],"usage":{"input_tokens":10,"output_tokens":100}},"requestId":"r\#(id)","type":"assistant","timestamp":"\#(time)"}"#
        }
        let failure = #"{"isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"boom","is_error":true}]},"timestamp":"2026-10-13T10:06:00.000Z"}"#
        let lines = [
            user("first", "2026-10-13T09:00:00.000Z"), edit("m1", "2026-10-13T09:01:00.000Z"),
            user("second", "2026-10-13T10:00:00.000Z"), edit("m2", "2026-10-13T10:05:00.000Z"),
            edit("m3", "2026-10-13T10:06:00.000Z"), failure,
            #"{"type":"system","subtype":"turn_duration","durationMs":412000,"timestamp":"2026-10-13T10:07:00.000Z"}"#,
        ]
        let session = try #require(TranscriptParser.parse(Data(lines.joined(separator: "\n").utf8), id: "s",
                                                           url: URL(fileURLWithPath: "/tmp/s.jsonl"), modified: Date()))
        let turn = try #require(session.lastTurn)
        #expect(turn.edits == 2)
        #expect(turn.errors == 1)
        #expect(turn.duration == 412)
        #expect((turn.cost ?? 0) > 0 && (turn.cost ?? 0) < (session.cost ?? 0))
        #expect(Fmt.turn(turn).hasPrefix("6m 52s · 2 edits · 1 error · +≈"))
    }

    @Test func costIsLabelledAsEstimateUnlessRecordedWins() {
        var s = session("a")
        s.estimatedCost = 4
        #expect(Fmt.cost(s) == "≈$4.00")
        s.recordedCost = 6
        #expect(Fmt.cost(s) == "$6.00")
        s.estimatedCost = 9
        #expect(Fmt.cost(s) == "≈$9.00")
    }
}
