import AppKit
import Foundation
import Observation

enum Prefs {
    static let terminal = "terminal"
    static let placement = "placement"
    static let extraFlags = "extraFlags"
    static let hotKey = "hotKeyEnabled"
    static let grouping = "grouping"
    static let notifications = "notifyWhenFinished"
    static let showHidden = "showHidden"
    static let pinned = "pinnedSessions"
    static let hidden = "hiddenSessions"
    static let titles = "titleOverrides"

    static var currentPlacement: Terminal.Placement {
        Terminal.Placement(rawValue: UserDefaults.standard.string(forKey: placement) ?? "") ?? .tab
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            hotKey: true, notifications: true, placement: Terminal.Placement.tab.rawValue,
            terminal: Terminal.Kind.iterm.rawValue,
            grouping: Grouping.date.rawValue,
        ])
    }
}

enum SessionFilter: String, CaseIterable, Identifiable {
    case all, running
    var id: String { rawValue }
    var title: String { self == .all ? "All" : "Running" }
}

enum Grouping: String, CaseIterable, Identifiable {
    case date, project, cost
    var id: String { rawValue }
    var title: String {
        switch self {
        case .date: "Date"
        case .project: "Project"
        case .cost: "Cost"
        }
    }
}

struct SessionSection: Identifiable, Equatable {
    let id: String
    let title: String
    var sessions: [Session]
    var subtitle: String?
    /// The full section size when only the first rows are on screen.
    var totalCount: Int?

    var count: Int { totalCount ?? sessions.count }
}

/// A title set in ClaudeResume for a session that was running at the time. Claude Code keeps
/// its own title in memory and re-writes it, so the new one is written to the transcript once
/// the session has stopped. `base` is the title it replaced, so a later `/rename` wins.
private struct TitleOverride: Codable {
    var title: String
    var base: String
}

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()
    /// Rows added to the list at a time. Search, grouping and keyboard navigation still see every session.
    static let pageSize = 50

    private(set) var sessions: [Session] = [] { didSet { invalidateListing() } }
    private(set) var live: [String: LiveSession] = [:] {
        didSet {
            // Only the Running filter and the Needs you section depend on live state.
            if Self.waitingIds(live) != Self.waitingIds(oldValue)
                || (filter == .running && Set(live.keys) != Set(oldValue.keys)) { invalidateListing() }
        }
    }
    private(set) var isLoaded = false
    var query = "" { didSet { if query != oldValue { resetListing() } } }
    var filter: SessionFilter = .all { didSet { if filter != oldValue { resetListing() } } }
    /// Only show sessions from this folder.
    var project: String? { didSet { if project != oldValue { resetListing() } } }
    var grouping: Grouping = Grouping(rawValue: UserDefaults.standard.string(forKey: Prefs.grouping) ?? "") ?? .date {
        didSet {
            guard grouping != oldValue else { return }
            if persists { UserDefaults.standard.set(grouping.rawValue, forKey: Prefs.grouping) }
            resetListing()
        }
    }
    var showHidden = UserDefaults.standard.bool(forKey: Prefs.showHidden) {
        didSet {
            guard showHidden != oldValue else { return }
            if persists { UserDefaults.standard.set(showHidden, forKey: Prefs.showHidden) }
            resetListing()
        }
    }
    var previewOpen = false
    var selection: Session.ID? { didSet { if selection != oldValue { revealSelection() } } }
    var error: String?
    private(set) var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Prefs.pinned) ?? []) {
        didSet { invalidateListing() }
    }
    private(set) var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Prefs.hidden) ?? []) {
        didSet { invalidateListing() }
    }

    /// Bumped whenever the listing's inputs change, so views re-read the cached listing.
    private var listingRevision = 0
    /// Bumped when the list starts over from the top (new search, filter or grouping).
    private(set) var listResetID = 0
    private var displayLimit = SessionStore.pageSize
    @ObservationIgnored private var cachedListing: Listing?
    @ObservationIgnored private var cachedPage: (revision: Int, limit: Int, sections: [SessionSection])?

    /// Search, filtering and grouping results, computed once per change instead of on every hover.
    private struct Listing {
        let day: Date
        let sections: [SessionSection]
        let sessions: [Session]
        let indices: [String: Int]
        let matches: [String: Search.Match]
        let projects: [(path: String, name: String, count: Int)]
    }

    /// Called before a session launches, so the panel can get out of the way.
    var onLaunch: (() -> Void)?
    /// Called when something needs the person's attention after the panel was closed.
    var onError: (() -> Void)?

    private let scanner: SessionScanner
    private let liveRoot: URL
    private let persists: Bool
    private var scanning = false
    private var rescanRequested = false
    private var timer: Timer?
    private let launchQueue = DispatchQueue(label: "ClaudeResume.launch")
    private var titleOverrides: [String: TitleOverride] = [:]
    /// When each running session started its current turn.
    private var busySince: [String: Date] = [:]
    /// Sessions that just finished a turn, notified once the rescan has their latest reply.
    private(set) var finished: [String: TimeInterval] = [:]
    /// Sessions that just started waiting for permission or an answer.
    private(set) var needsInput: Set<String> = []

    init(scanner: SessionScanner = SessionScanner(), liveRoot: URL = LiveSessions.defaultRoot) {
        self.scanner = scanner
        self.liveRoot = liveRoot
        persists = true
        if let data = UserDefaults.standard.data(forKey: Prefs.titles),
           let saved = try? JSONDecoder().decode([String: TitleOverride].self, from: data) {
            titleOverrides = saved
        }
    }

    /// Loads demo data for screenshots and tests. Nothing is read from or written to disk.
    init(demo sessions: [Session], live: [String: LiveSession], pinned: Set<String> = []) {
        scanner = SessionScanner(root: URL(fileURLWithPath: "/nonexistent"))
        liveRoot = URL(fileURLWithPath: "/nonexistent")
        persists = false
        grouping = .date
        showHidden = false
        hidden = []
        self.pinned = pinned
        self.sessions = sessions
        self.live = live
        isLoaded = true
        selectFirst()
    }

    var anyBusy: Bool { live.values.contains { $0.status == .busy } }
    var waitingCount: Int { live.values.filter { $0.status == .waiting }.count }

    // MARK: Refresh

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLive() }
        }
    }

    func refresh() {
        guard persists else { return }
        guard !scanning else { rescanRequested = true; return }
        scanning = true
        let scanner = scanner, liveRoot = liveRoot
        Task.detached(priority: .userInitiated) {
            let sessions = scanner.scan()
            let live = LiveSessions.scan(root: liveRoot)
            await MainActor.run {
                self.trackTurns(live)
                self.apply(sessions: sessions, live: live)
                self.scanning = false
                if self.rescanRequested { self.rescanRequested = false; self.refresh() }
            }
        }
    }

    private func refreshLive() {
        let liveRoot = liveRoot
        Task.detached(priority: .utility) {
            let live = LiveSessions.scan(root: liveRoot)
            await MainActor.run {
                guard live != self.live else { return }
                // A session that went busy or idle has new messages; pick them up.
                self.trackTurns(live)
                self.live = live
                self.refresh()
            }
        }
    }

    /// Notices sessions finishing a turn (busy → idle) or starting to wait for you, so they can
    /// be announced after the next scan. A wait for permission doesn't end the turn.
    func trackTurns(_ next: [String: LiveSession], now: Date = Date()) {
        for (id, session) in next {
            switch session.status {
            case .busy:
                if busySince[id] == nil { busySince[id] = session.statusSince ?? now }
            case .waiting:
                if live[id]?.status != .waiting { needsInput.insert(id) }
            case .idle:
                if let since = busySince.removeValue(forKey: id) { finished[id] = now.timeIntervalSince(since) }
            }
        }
        // Exited while busy (quit or crashed): nothing to announce.
        for id in busySince.keys where next[id] == nil { busySince[id] = nil }
    }

    private func apply(sessions scanned: [Session], live: [String: LiveSession]) {
        var sessions = scanned
        resolveTitleOverrides(&sessions, live: live)
        self.sessions = sessions
        self.live = live
        isLoaded = true
        if selection == nil || !visible.contains(where: { $0.id == selection }) { selectFirst() }
        announceFinished()
    }

    // MARK: Notifications

    /// Turns shorter than this don't get a notification: you were probably watching.
    static let minimumTurn: TimeInterval = 20

    private func announceFinished() {
        let done = finished, waiting = needsInput
        finished = [:]
        needsInput = []
        guard UserDefaults.standard.bool(forKey: Prefs.notifications) else { return }
        for (id, duration) in done where duration >= Self.minimumTurn {
            guard let session = session(id) else { continue }
            notifyUnlessInFront(live[id]) { Notifier.shared.post(session, duration: duration) }
        }
        // Every wait is worth a notification, however short the turn: Claude is stuck until you answer.
        for id in waiting {
            guard let session = session(id), let running = live[id], running.status == .waiting else { continue }
            notifyUnlessInFront(running) { Notifier.shared.postNeedsInput(session, reason: running.waitingLabel) }
        }
    }

    /// Posts unless the session's tab is already in front of you.
    private func notifyUnlessInFront(_ running: LiveSession?, _ post: @escaping @MainActor () -> Void) {
        launchQueue.async {
            if let running, let terminal = Terminal.id(for: running), Terminal.frontmostID() == terminal { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { post() } }
        }
    }

    // MARK: Listing

    private var listing: Listing {
        _ = listingRevision
        // Date sections move at midnight even when nothing else changed.
        let day = Calendar.current.startOfDay(for: Date())
        if let cachedListing, cachedListing.day == day { return cachedListing }
        var matches: [String: Search.Match] = [:]
        let sections = makeSections(matches: &matches)
        let ordered = sections.flatMap(\.sessions)
        let indices = ordered.enumerated().reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        let result = Listing(day: day, sections: sections, sessions: ordered, indices: indices,
                             matches: matches, projects: makeProjects())
        cachedListing = result
        cachedPage = nil
        return result
    }

    private func invalidateListing(resetPage: Bool = false) {
        cachedListing = nil
        cachedPage = nil
        listingRevision += 1
        if resetPage { displayLimit = Self.pageSize }
    }

    private func resetListing() {
        invalidateListing(resetPage: true)
        listResetID += 1
        selectFirst()
    }

    private static func waitingIds(_ live: [String: LiveSession]) -> Set<String> {
        Set(live.filter { $0.value.status == .waiting }.keys)
    }

    var sections: [SessionSection] { listing.sections }

    /// The sections cut to the rows loaded so far. Only these go into the list.
    var displayedSections: [SessionSection] {
        let current = listing
        if let cachedPage, cachedPage.revision == listingRevision, cachedPage.limit == displayLimit {
            return cachedPage.sections
        }
        var remaining = displayLimit
        var page: [SessionSection] = []
        for section in current.sections {
            guard remaining > 0 else { break }
            var partial = section
            partial.totalCount = section.sessions.count
            partial.sessions = Array(section.sessions.prefix(remaining))
            remaining -= partial.sessions.count
            page.append(partial)
        }
        cachedPage = (listingRevision, displayLimit, page)
        return page
    }

    var displayedCount: Int { min(displayLimit, visible.count) }
    var hasMoreSessions: Bool { displayedCount < visible.count }

    /// Loads the next page once the last loaded row appears.
    func loadMoreIfNeeded(after id: String) {
        let current = listing.sessions
        let count = min(displayLimit, current.count)
        guard count > 0, count < current.count, current[count - 1].id == id else { return }
        displayLimit += Self.pageSize
    }

    func highlightRanges(for session: Session) -> [Range<String.Index>] {
        listing.matches[session.id]?.titleRanges ?? []
    }

    private func makeSections(matches: inout [String: Search.Match]) -> [SessionSection] {
        let terms = Search.terms(query)
        let base = scoped
        if !terms.isEmpty {
            let ranked = base.compactMap { session -> (Session, Double)? in
                guard let match = Search.match(session, terms: terms) else { return nil }
                matches[session.id] = match
                return (session, match.score)
            }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastActivity > $1.0.lastActivity }
            return ranked.isEmpty ? [] : [SessionSection(id: "results", title: "Results", sessions: ranked.map(\.0))]
        }
        // Sessions blocked on you come first, whatever the grouping.
        let waiting = base.filter { live[$0.id]?.status == .waiting }
        let waitingIds = Set(waiting.map(\.id))
        let pinnedSessions = base.filter { pinned.contains($0.id) && !waitingIds.contains($0.id) }
        let rest = base.filter { !pinned.contains($0.id) && !waitingIds.contains($0.id) }
        var result: [SessionSection] = []
        if !waiting.isEmpty {
            result.append(SessionSection(id: "waiting", title: "Needs you", sessions: waiting))
        }
        if !pinnedSessions.isEmpty {
            result.append(SessionSection(id: "pinned", title: "Pinned", sessions: pinnedSessions))
        }
        switch grouping {
        case .date: result += Self.group(rest, now: Date())
        case .project: result += Self.groupByProject(rest)
        case .cost:
            let sorted = rest.sorted { ($0.cost ?? 0) > ($1.cost ?? 0) }
            if !sorted.isEmpty {
                let total = sorted.compactMap(\.cost).reduce(0, +)
                result.append(SessionSection(id: "cost", title: "Most expensive", sessions: sorted,
                                             subtitle: Fmt.usd(total)))
            }
        }
        return result
    }

    /// Sessions in display order, for keyboard navigation.
    var visible: [Session] { listing.sessions }

    /// Sessions after the Running, project and hidden filters, before search and grouping.
    private var scoped: [Session] {
        sessions.filter { session in
            (filter == .all || live[session.id] != nil)
                && (project == nil || session.projectPath == project)
                && (showHidden || !hidden.contains(session.id))
        }
    }

    /// Folders with sessions, most recently used first.
    var projects: [(path: String, name: String, count: Int)] { listing.projects }

    private func makeProjects() -> [(path: String, name: String, count: Int)] {
        var order: [String] = [], counts: [String: Int] = [:]
        for session in sessions where showHidden || !hidden.contains(session.id) {
            guard let cwd = session.projectPath else { continue }
            if counts[cwd] == nil { order.append(cwd) }
            counts[cwd, default: 0] += 1
        }
        return order.map { ($0, ($0 as NSString).lastPathComponent, counts[$0] ?? 0) }
    }

    var hiddenCount: Int { sessions.filter { hidden.contains($0.id) }.count }

    nonisolated static func group(_ sessions: [Session], now: Date, calendar: Calendar = .current) -> [SessionSection] {
        var buckets: [String: SessionSection] = [:], order: [String] = []
        let today = calendar.startOfDay(for: now)
        let monthFormat = Date.FormatStyle().month(.wide)
        let monthYearFormat = Date.FormatStyle().month(.wide).year()

        for session in sessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            let day = calendar.startOfDay(for: session.lastActivity)
            let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            let key: String, title: String
            switch days {
            case ...0: (key, title) = ("today", "Today")
            case 1: (key, title) = ("yesterday", "Yesterday")
            case 2...6: (key, title) = ("week", "Previous 7 days")
            case 7...29: (key, title) = ("month", "Previous 30 days")
            default:
                let components = calendar.dateComponents([.year, .month], from: session.lastActivity)
                key = "m\(components.year ?? 0)-\(components.month ?? 0)"
                let sameYear = components.year == calendar.component(.year, from: now)
                title = session.lastActivity.formatted(sameYear ? monthFormat : monthYearFormat)
            }
            if buckets[key] == nil { buckets[key] = SessionSection(id: key, title: title, sessions: []); order.append(key) }
            buckets[key]!.sessions.append(session)
        }
        return order.compactMap { buckets[$0] }
    }

    /// One section per folder, the most recently used folder first.
    nonisolated static func groupByProject(_ sessions: [Session]) -> [SessionSection] {
        var buckets: [String: SessionSection] = [:], order: [String] = []
        for session in sessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            let key = session.projectPath ?? "?"
            if buckets[key] == nil {
                let parent = session.projectPath.map { Fmt.path(($0 as NSString).deletingLastPathComponent) }
                buckets[key] = SessionSection(id: "p:" + key, title: session.folderName, sessions: [], subtitle: parent)
                order.append(key)
            }
            buckets[key]!.sessions.append(session)
        }
        return order.compactMap { buckets[$0] }
    }

    // MARK: Selection

    private func selectFirst() {
        selection = visible.first?.id
    }

    /// Loads enough pages to show the selection, e.g. after moving past the last loaded row.
    private func revealSelection() {
        guard let selection, let index = listing.indices[selection], index >= displayLimit else { return }
        displayLimit = (index / Self.pageSize + 1) * Self.pageSize
    }

    func moveSelection(by offset: Int) {
        let current = listing
        let list = current.sessions
        guard !list.isEmpty else { return }
        let index = selection.flatMap { current.indices[$0] } ?? (offset > 0 ? -1 : list.count)
        selection = list[max(0, min(list.count - 1, index + offset))].id
    }

    var selectedSession: Session? {
        sessions.first { $0.id == selection }
    }

    func session(_ id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    // MARK: Library

    func togglePin(_ session: Session) {
        if pinned.remove(session.id) == nil { pinned.insert(session.id) }
        save(pinned, Prefs.pinned)
    }

    func toggleHidden(_ session: Session) {
        if hidden.remove(session.id) == nil {
            // Read the order from before the hide, so the next row can take the selection.
            let list = visible
            hidden.insert(session.id)
            pinned.remove(session.id)
            save(pinned, Prefs.pinned)
            if !showHidden, selection == session.id {
                if let index = list.firstIndex(where: { $0.id == session.id }) {
                    selection = list.indices.contains(index + 1) ? list[index + 1].id : list.dropLast().last?.id
                }
            }
        }
        save(hidden, Prefs.hidden)
    }

    private func save(_ ids: Set<String>, _ key: String) {
        guard persists else { return }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
    }

    /// Renames a session. Stopped sessions get the same `custom-title` line `/rename` writes,
    /// so `claude --resume` shows it too. Running ones are written once they stop.
    func rename(_ session: Session, to raw: String) {
        guard let title = TranscriptParser.clean(raw), title != session.title,
              let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let base = titleOverrides[session.id]?.base ?? session.title
        sessions[index].title = title
        if live[session.id] == nil {
            do {
                try TranscriptWriter.appendTitle(title, sessionId: session.id, to: session.transcriptURL)
                titleOverrides[session.id] = nil
            } catch {
                self.error = "Couldn't rename: \(error.localizedDescription)"
                titleOverrides[session.id] = TitleOverride(title: title, base: base)
            }
        } else {
            titleOverrides[session.id] = TitleOverride(title: title, base: base)
        }
        saveOverrides()
        refresh()
    }

    private func resolveTitleOverrides(_ sessions: inout [Session], live: [String: LiveSession]) {
        guard !titleOverrides.isEmpty else { return }
        var changed = false
        for (id, override) in titleOverrides {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { continue }
            let parsed = sessions[index].title
            if parsed == override.title || parsed != override.base {
                // The transcript caught up, or the session was renamed somewhere else.
                titleOverrides[id] = nil
                changed = true
                continue
            }
            sessions[index].title = override.title
            if live[id] == nil, (try? TranscriptWriter.appendTitle(override.title, sessionId: id,
                                                                to: sessions[index].transcriptURL)) != nil {
                titleOverrides[id] = nil
                changed = true
            }
        }
        if changed { saveOverrides() }
    }

    private func saveOverrides() {
        guard persists, let data = try? JSONEncoder().encode(titleOverrides) else { return }
        UserDefaults.standard.set(data, forKey: Prefs.titles)
    }

    // MARK: Running sessions

    /// Running sessions that have waited for input longer than `age`.
    func idleSessions(olderThan age: TimeInterval) -> [Session] {
        let cutoff = Date().addingTimeInterval(-age)
        return sessions.filter { session in
            guard let live = live[session.id], live.status == .idle else { return false }
            return (live.statusSince ?? session.lastActivity) < cutoff
        }
    }

    /// Stops the Claude Code processes and optionally closes their original terminal tabs.
    func quit(_ targets: [Session], closeTabs: Bool) {
        let running = targets.compactMap { live[$0.id] }
        guard !running.isEmpty else { return }
        launchQueue.async {
            // Resolve terminal identities while the processes still exist, before sending SIGTERM.
            let processes = running.map { ($0.pid, closeTabs ? Terminal.id(for: $0) : nil) }
            for (pid, _) in processes { kill(pid, SIGTERM) }
            // Give them a moment to exit before closing the tabs they ran in.
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline, processes.contains(where: { LiveSessions.isAlive($0.0) }) {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if closeTabs {
                for (pid, terminal) in processes where !LiveSessions.isAlive(pid) {
                    if let terminal { _ = try? Terminal.close(terminal) }
                }
            }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    // MARK: Actions

    func open(_ session: Session, placement: Terminal.Placement? = nil, fork: Bool = false) {
        error = nil
        let running = fork ? nil : live[session.id]
        guard running != nil || session.folderExists else {
            error = "\(session.cwd ?? "The session's folder") no longer exists."
            return
        }
        let placement = placement ?? Prefs.currentPlacement
        let command = Terminal.resumeCommand(for: session, fork: fork,
                                          extraFlags: UserDefaults.standard.string(forKey: Prefs.extraFlags) ?? "")
        let terminal = Terminal.selected()
        onLaunch?()
        launchQueue.async {
            do {
                try Terminal.open(command, live: running, in: terminal, placement: placement, cwd: session.cwd)
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.error = message
                    self.onError?()
                }
            }
        }
    }

    func copyCommand(_ session: Session) {
        copy(Terminal.resumeCommand(for: session, extraFlags: UserDefaults.standard.string(forKey: Prefs.extraFlags) ?? ""))
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealFolder(_ session: Session) {
        guard let cwd = session.cwd else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    func revealTranscript(_ session: Session) {
        NSWorkspace.shared.activateFileViewerSelecting([session.transcriptURL])
    }

    func revealFile(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openLink(_ link: SessionLink) {
        NSWorkspace.shared.open(link.url)
    }
}
