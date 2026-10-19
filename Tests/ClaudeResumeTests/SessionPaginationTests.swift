import Foundation
import Testing
@testable import ClaudeResume

@Suite("Session pagination")
@MainActor
struct SessionPaginationTests {
    private func sessions(_ count: Int) -> [Session] {
        let now = Date()
        return (0..<count).map { index in
            Session(id: "session-\(index)", title: "Conversation \(index)", firstPrompt: nil,
                    lastPrompt: index == count - 1 ? "distantneedle" : nil,
                    cwd: "/tmp/project-\(index % 3)", branch: nil, promptCount: 1, startedAt: nil,
                    lastActivity: now.addingTimeInterval(-Double(index)),
                    transcriptURL: URL(fileURLWithPath: "/tmp/session-\(index).jsonl"))
        }
    }

    private func displayed(_ store: SessionStore) -> [String] {
        store.displayedSections.flatMap(\.sessions).map(\.id)
    }

    @Test func startsWithOnePageAndKeepsFullSectionCounts() {
        let store = SessionStore(demo: sessions(175), live: [:])
        #expect(store.visible.count == 175)
        #expect(store.displayedCount == SessionStore.pageSize)
        #expect(displayed(store) == Array(store.visible.prefix(SessionStore.pageSize)).map(\.id))
        #expect(store.displayedSections.first?.count == store.sections.first?.count)
        #expect(store.hasMoreSessions)
    }

    @Test(arguments: Grouping.allCases)
    func loadsPagesAcrossGroupsWithoutDuplicatesOrStaleTriggers(_ grouping: Grouping) throws {
        let store = SessionStore(demo: sessions(175), live: [:], pinned: ["session-174"])
        store.grouping = grouping
        #expect(displayed(store).first == "session-174")
        let firstBoundary = try #require(displayed(store).last)
        store.loadMoreIfNeeded(after: firstBoundary)
        #expect(store.displayedCount == 2 * SessionStore.pageSize)
        store.loadMoreIfNeeded(after: firstBoundary)
        #expect(store.displayedCount == 2 * SessionStore.pageSize)
        while store.hasMoreSessions {
            store.loadMoreIfNeeded(after: try #require(displayed(store).last))
        }
        #expect(displayed(store) == store.visible.map(\.id))
        #expect(Set(displayed(store)).count == 175)
        #expect(store.displayedCount == 175)
    }

    @Test func searchesBeyondLoadedPagesAndResetsPagination() throws {
        let store = SessionStore(demo: sessions(220), live: [:])
        store.loadMoreIfNeeded(after: try #require(displayed(store).last))
        #expect(store.displayedCount == 100)
        store.query = "distantneedle"
        #expect(store.visible.map(\.id) == ["session-219"])
        #expect(displayed(store) == store.visible.map(\.id))
        #expect(!store.hasMoreSessions)
        store.query = ""
        #expect(store.displayedCount == SessionStore.pageSize)
        #expect(store.visible.count == 220)
    }

    @Test func keyboardAndExternalSelectionRevealUnloadedRows() throws {
        let store = SessionStore(demo: sessions(220), live: [:])
        store.moveSelection(by: SessionStore.pageSize - 1)
        #expect(store.displayedCount == SessionStore.pageSize)
        store.moveSelection(by: 1)
        #expect(store.selection == store.visible[SessionStore.pageSize].id)
        #expect(store.displayedCount == 100)
        #expect(displayed(store).contains(try #require(store.selection)))
        store.selection = store.visible[170].id
        #expect(store.displayedCount == 200)
        #expect(displayed(store).contains(try #require(store.selection)))
    }

    @Test func filtersResetPagesWithoutLosingOlderMatches() throws {
        let store = SessionStore(demo: sessions(220), live: [:])
        store.loadMoreIfNeeded(after: try #require(displayed(store).last))
        store.project = "/tmp/project-1"
        #expect(store.displayedCount == SessionStore.pageSize)
        #expect(store.visible.count == 73)
        #expect(store.visible.allSatisfy { $0.cwd == "/tmp/project-1" })
        store.query = "distantneedle"
        #expect(store.visible.isEmpty)
        #expect(store.displayedCount == 0)
        #expect(store.displayedSections.isEmpty)
        store.project = "/tmp/project-0"
        #expect(store.visible.map(\.id) == ["session-219"])
        store.query = ""
        #expect(store.displayedCount == SessionStore.pageSize)
    }

    @Test func cachedResultsFollowPinsHiddenSessionsAndRenamedTitles() throws {
        let store = SessionStore(demo: sessions(175), live: [:])
        let oldest = try #require(store.visible.last)
        _ = store.displayedSections
        _ = store.projects
        store.togglePin(oldest)
        #expect(displayed(store).first == oldest.id)
        #expect(store.displayedSections.first?.id == "pinned")
        store.toggleHidden(oldest)
        #expect(!displayed(store).contains(oldest.id))
        #expect(store.visible.count == 174)
        #expect(store.projects.reduce(0) { $0 + $1.count } == 174)
        store.showHidden = true
        #expect(store.visible.count == 175)
        let target = try #require(store.visible.last)
        store.query = "newtitle"
        #expect(store.visible.isEmpty)
        store.rename(target, to: "newtitle")
        #expect(store.visible.map(\.id) == [target.id])
        #expect(store.highlightRanges(for: try #require(store.visible.first)).isEmpty == false)
    }

    @Test func hidingTheSelectionMovesItToTheNextRow() throws {
        let store = SessionStore(demo: sessions(5), live: [:])
        let first = try #require(store.selectedSession)
        store.toggleHidden(first)
        #expect(store.selection == "session-1")
    }

    @Test func waitingSessionsBeyondTheFirstPageComeFirst() {
        let waiting = LiveSession(sessionId: "session-110", pid: 1, status: .waiting, cwd: nil)
        let store = SessionStore(demo: sessions(120), live: ["session-110": waiting])
        #expect(store.displayedSections.first?.id == "waiting")
        #expect(displayed(store).first == "session-110")
        #expect(store.displayedCount == SessionStore.pageSize)
    }

    @Test func emptyAndShortListsNeedNoFurtherPage() {
        for count in [0, 1, SessionStore.pageSize] {
            let store = SessionStore(demo: sessions(count), live: [:])
            #expect(store.displayedCount == count)
            #expect(!store.hasMoreSessions)
            store.loadMoreIfNeeded(after: "missing")
            #expect(store.displayedCount == count)
        }
    }
}
