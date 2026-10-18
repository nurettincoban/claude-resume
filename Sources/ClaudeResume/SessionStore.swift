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

    private(set) var sessions: [Session] = []
    private(set) var live: [String: LiveSession] = [:]
    private(set) var isLoaded = false
    var query = "" { didSet { if query != oldValue { selectFirst() } } }
    var filter: SessionFilter = .all { didSet { if filter != oldValue { selectFirst() } } }
    /// Only show sessions from this folder.
    var project: String? { didSet { if project != oldValue { selectFirst() } } }
    var grouping: Grouping = Grouping(rawValue: UserDefaults.standard.string(forKey: Prefs.grouping) ?? "") ?? .date {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: Prefs.grouping); selectFirst() }
    }
    var showHidden = UserDefaults.standard.bool(forKey: Prefs.showHidden) {
        didSet { UserDefaults.standard.set(showHidden, forKey: Prefs.showHidden) }
    }
    var previewOpen = false
    var selection: Session.ID?
    var error: String?
    private(set) var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Prefs.pinned) ?? [])
    private(set) var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Prefs.hidden) ?? [])

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

    /// Notices sessions going from busy to idle, so they can be announced after the next scan.
    func trackTurns(_ next: [String: LiveSession], now: Date = Date()) {
        for (id, session) in next {
            if session.status == .busy {
                if busySince[id] == nil { busySince[id] = session.statusSince ?? now }
            } else if let since = busySince.removeValue(forKey: id) {
                finished[id] = now.timeIntervalSince(since)
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
        let done = finished
        finished = [:]
        guard UserDefaults.standard.bool(forKey: Prefs.notifications) else { return }
        for (id, duration) in done where duration >= Self.minimumTurn {
            guard let session = sessions.first(where: { $0.id == id }) else { continue }
            let running = live[id]
            launchQueue.async {
                // Skip it when that tab is already in front of you.
                if let running, let terminal = Terminal.id(for: running), Terminal.frontmostID() == terminal { return }
                DispatchQueue.main.async { Notifier.shared.post(session, duration: duration) }
            }
        }
    }

    // MARK: Listing

    var sections: [SessionSection] {
        let terms = Search.terms(query)
        let base = scoped
        if !terms.isEmpty {
            let matches = base.compactMap { session in Search.match(session, terms: terms).map { (session, $0.score) } }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastActivity > $1.0.lastActivity }
            return matches.isEmpty ? [] : [SessionSection(id: "results", title: "Results", sessions: matches.map(\.0))]
        }
        let pinnedSessions = base.filter { pinned.contains($0.id) }
        let rest = base.filter { !pinned.contains($0.id) }
        var result: [SessionSection] = []
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
    var visible: [Session] { sections.flatMap(\.sessions) }

    /// Sessions after the Running, project and hidden filters, before search and grouping.
    private var scoped: [Session] {
        sessions.filter { session in
            (filter == .all || live[session.id] != nil)
                && (project == nil || session.projectPath == project)
                && (showHidden || !hidden.contains(session.id))
        }
    }

    /// Folders with sessions, most recently used first.
    var projects: [(path: String, name: String, count: Int)] {
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

    func moveSelection(by offset: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : list.count)
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
            hidden.insert(session.id)
            pinned.remove(session.id)
            save(pinned, Prefs.pinned)
            if !showHidden, selection == session.id {
                let list = visible
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
