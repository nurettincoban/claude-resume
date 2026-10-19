import ServiceManagement
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.851, green: 0.467, blue: 0.341) // Claude coral
    static let live = Color(red: 0.30, green: 0.75, blue: 0.45)
    /// Sessions blocked on a permission prompt or question.
    static let attention = Color(red: 0.96, green: 0.65, blue: 0.14)
    static let listWidth: CGFloat = 440
    static let previewWidth: CGFloat = 400
    static let height: CGFloat = 560
}

enum Fmt {
    /// Compact age: `now`, `5m`, `3h`, `Mon`, `12 Sep`, `Sep 2025`.
    static func age(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDateInToday(date) || seconds < 6 * 3600 { return "\(Int(seconds / 3600))h" }
        if seconds < 6 * 86400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).year())
    }

    static func prompts(_ count: Int) -> String {
        count == 1 ? "1 prompt" : "\(count) prompts"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1440)d \((minutes % 1440) / 60)h"
    }

    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// Cents below $100, whole dollars above.
    static func usd(_ value: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: Locale(identifier: "en_US"))
        if value > 0, value < 0.01 { return "<$0.01" }
        return value.formatted(style.precision(.fractionLength(value >= 100 ? 0 : 2)))
    }

    /// A session's cost, with `≈` when it's our estimate rather than Claude Code's recorded total.
    static func cost(_ session: Session) -> String? {
        session.cost.map { (session.costIsEstimate ? "≈" : "") + usd($0) }
    }

    static func costHelp(_ session: Session) -> String {
        session.costIsEstimate
            ? "Estimated: the session's tokens, subagents included, at API list prices. Not what a subscription bills."
            : "Claude Code's own recorded total for this session, at API prices."
    }

    /// "4m 12s · 6 edits · 1 error · +$0.84", leaving out parts that are zero or unknown.
    static func turn(_ turn: TurnSummary) -> String {
        var parts: [String] = []
        if let duration = turn.duration { parts.append(precise(duration)) }
        if turn.edits > 0 { parts.append(turn.edits == 1 ? "1 edit" : "\(turn.edits) edits") }
        if turn.errors > 0 { parts.append(turn.errors == 1 ? "1 error" : "\(turn.errors) errors") }
        if let cost = turn.cost, cost > 0 { parts.append("+≈" + usd(cost)) }
        return parts.joined(separator: " · ")
    }

    /// `45s`, `4m 12s`, `1h 5m`: seconds matter for a single turn.
    static func precise(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return duration(interval)
    }

    /// `~/code/app` instead of `/Users/me/code/app`.
    static func path(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct PanelView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            ListPane()
                .frame(width: Theme.listWidth)
            if store.previewOpen {
                Divider().opacity(0.6)
                Group {
                    if let session = store.selectedSession {
                        PreviewPane(session: session, live: store.live[session.id])
                    } else {
                        Text("Nothing selected")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: Theme.previewWidth)
            }
        }
        .frame(height: Theme.height)
    }
}

struct ListPane: View {
    @Environment(SessionStore.self) private var store
    @FocusState private var searchFocused: Bool
    @State private var hovered: Session.ID?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.5)
            if let error = store.error {
                ErrorBanner(message: error) { store.error = nil }
            }
            content
            Divider().opacity(0.5)
            footer
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelDidOpen)) { _ in
            searchFocused = true
        }
        .onAppear { searchFocused = true }
    }

    // MARK: Search

    private var searchBar: some View {
        @Bindable var store = store
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            if Snapshot.isActive {
                // ImageRenderer can't draw AppKit-backed text fields.
                HStack(spacing: 1) {
                    Text(store.query.isEmpty ? "Search conversations" : store.query)
                        .foregroundStyle(store.query.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                    if !store.query.isEmpty {
                        Rectangle().fill(Theme.accent).frame(width: 1.5, height: 18)
                    }
                }
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Search conversations", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
            }
            if !store.query.isEmpty {
                Button { store.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
            ProjectPicker(selection: $store.project, projects: store.projects)
            FilterPills(selection: $store.filter, runningCount: store.live.count)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 50)
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        let sections = store.displayedSections
        if !store.isLoaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sections.isEmpty {
            EmptyState(query: store.query, filter: store.filter, hasProject: store.project != nil)
        } else if Snapshot.isActive {
            // ImageRenderer can't draw scroll views.
            Color.clear
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) { rows(sections) }
                        .padding(.horizontal, 8)
                }
                .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        rows(sections)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: store.selection) { _, id in
                    guard let id, KeyboardState.lastMoveWasKeyboard else { return }
                    proxy.scrollTo(id)
                }
                .onChange(of: sections.first?.sessions.first?.id) { _, first in
                    if let first { proxy.scrollTo(first, anchor: .bottom) }
                }
                .onChange(of: store.listResetID) { _, _ in
                    if let first = sections.first?.sessions.first?.id { proxy.scrollTo(first, anchor: .top) }
                }
            }
        }
    }

    private func rows(_ sections: [SessionSection]) -> some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.sessions) { session in
                    row(session)
                        .onAppear {
                            if !Snapshot.isActive { store.loadMoreIfNeeded(after: session.id) }
                        }
                }
            } header: {
                SectionHeader(title: section.title, subtitle: section.subtitle, count: section.count)
            }
        }
    }

    private func row(_ session: Session) -> some View {
        SessionRow(
            session: session,
            live: store.live[session.id],
            highlights: store.highlightRanges(for: session),
            isSelected: store.selection == session.id,
            isHovered: hovered == session.id,
            isPinned: store.pinned.contains(session.id),
            isHidden: store.hidden.contains(session.id)
        )
        .id(session.id)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = session.id } else if hovered == session.id { hovered = nil }
        }
        .onTapGesture { store.open(session) }
        .contextMenu { SessionMenu(session: session) }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            KeyHint(keys: "↩", label: "Resume")
            KeyHint(keys: store.previewOpen ? "←" : "→", label: store.previewOpen ? "Close" : "Preview")
            if Snapshot.isActive {
                // ImageRenderer can't draw AppKit-backed menus.
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
            } else {
                SettingsMenu()
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 36)
    }

    private var summary: String {
        let count = store.query.isEmpty && store.project == nil && store.filter == .all
            ? store.sessions.count - (store.showHidden ? 0 : store.hiddenCount)
            : store.visible.count
        let noun = count == 1 ? "conversation" : "conversations"
        let running = store.live.count
        let total = store.hasMoreSessions ? "\(store.displayedCount) of \(count) \(noun)" : "\(count) \(noun)"
        return running > 0 ? "\(total) · \(running) running" : total
    }
}

// MARK: - Row

struct SessionRow: View {
    let session: Session
    let live: LiveSession?
    let highlights: [Range<String.Index>]
    let isSelected: Bool
    let isHovered: Bool
    let isPinned: Bool
    let isHidden: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(status: live?.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.accent)
                            .rotationEffect(.degrees(45))
                    }
                    if isHidden {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Text(highlightedTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    LinkBadges(links: session.links)
                }
                subtitle
            }
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(background)
        .opacity(isHidden ? 0.55 : 1)
        .help(session.recap ?? session.lastPrompt.map { "Last prompt: \($0)" } ?? "")
    }

    private var highlightedTitle: AttributedString {
        var text = AttributedString(session.title)
        text.foregroundColor = .primary
        for range in highlights {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].foregroundColor = Theme.accent
            text[lower..<upper].font = .system(size: 13, weight: .bold)
        }
        return text
    }

    private var subtitle: some View {
        HStack(spacing: 4) {
            if !session.folderExists {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("This folder no longer exists")
            }
            Text(session.folderName)
                .foregroundStyle(.secondary)
            if let branch = session.branch {
                Text("·").foregroundStyle(.quaternary)
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(branch)
                    .foregroundStyle(.tertiary)
                    .truncationMode(.middle)
            }
            Text("·").foregroundStyle(.quaternary)
            if let live, live.status == .waiting {
                // What Claude is blocked on matters more than the prompt count.
                Text(live.waitingLabel)
                    .foregroundStyle(Theme.attention)
                    .layoutPriority(1)
            } else {
                Text(Fmt.prompts(session.promptCount))
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if isSelected || isHovered {
                Image(systemName: live == nil ? "return" : "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                    .frame(height: 14)
            } else {
                Text(Fmt.age(session.lastActivity))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(height: 14)
            }
            Text(Fmt.cost(session) ?? " ")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 40, alignment: .trailing)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if isSelected {
            shape.fill(Theme.accent.opacity(0.16))
        } else if isHovered {
            shape.fill(Color.primary.opacity(0.05))
        } else {
            shape.fill(Color.clear)
        }
    }
}

/// Merge request / artifact chips on a row. Clicking one opens it.
struct LinkBadges: View {
    let links: [SessionLink]

    var body: some View {
        let pullRequests = links.filter { $0.kind == .pullRequest }
        let artifacts = links.filter { $0.kind == .artifact }
        HStack(spacing: 4) {
            if let first = pullRequests.first {
                badge(icon: "arrow.triangle.pull", text: pullRequests.count > 1 ? "\(first.label) +\(pullRequests.count - 1)" : first.label,
                      help: first.detail, url: first.url)
            }
            if let first = artifacts.first {
                badge(icon: "sparkles.rectangle.stack", text: artifacts.count > 1 ? "\(artifacts.count)" : nil,
                      help: first.detail, url: first.url)
            }
        }
    }

    private func badge(icon: String, text: String?, help: String, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                if let text { Text(text).font(.system(size: 10, weight: .medium).monospacedDigit()) }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct StatusDot: View {
    let status: LiveSession.Status?
    @State private var pulse = false

    var body: some View {
        ZStack {
            switch status {
            case .busy:
                Circle()
                    .fill(Theme.accent.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1 : 0.45)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
            case .idle:
                Circle().fill(Theme.live).frame(width: 7, height: 7)
            case .waiting:
                Circle().strokeBorder(Theme.attention.opacity(0.45), lineWidth: 1.5).frame(width: 13, height: 13)
                Circle().fill(Theme.attention).frame(width: 7, height: 7)
            case nil:
                EmptyView()
            }
        }
        .frame(width: 14, height: 14)
        .help(status?.label ?? "")
    }
}

extension LiveSession.Status {
    var label: String {
        switch self {
        case .busy: "Working"
        case .idle: "Idle"
        case .waiting: "Needs you"
        }
    }

    var color: Color {
        switch self {
        case .busy: Theme.accent
        case .idle: Theme.live
        case .waiting: Theme.attention
        }
    }
}

// MARK: - Menus

/// Right-click menu for a session.
struct SessionMenu: View {
    @Environment(SessionStore.self) private var store
    let session: Session

    var body: some View {
        let isLive = store.live[session.id] != nil
        Button(isLive ? "Switch to Tab" : "Resume in New Tab") { store.open(session, placement: .tab) }
        Button("Resume in New Window") { store.open(session, placement: .window) }
        Button("Fork Conversation") { store.open(session, fork: true) }
        Divider()
        Button(store.pinned.contains(session.id) ? "Unpin" : "Pin to Top") { store.togglePin(session) }
        Button("Rename…") { Prompts.rename(session, store: store) }
        Button(store.hidden.contains(session.id) ? "Unhide" : "Hide") { store.toggleHidden(session) }
        if !session.links.isEmpty {
            Divider()
            ForEach(session.links) { link in
                Button("Open \(link.detail)") { store.openLink(link) }
            }
        }
        Divider()
        Button("Copy Resume Command") { store.copyCommand(session) }
        Button("Copy Session ID") { store.copy(session.id) }
        Button("Open Folder") { store.revealFolder(session) }.disabled(!session.folderExists)
        Button("Show Transcript in Finder") { store.revealTranscript(session) }
        if isLive {
            Divider()
            Button("Quit Session…") { Prompts.quit([session], store: store) }
        }
    }
}

struct ProjectPicker: View {
    @Binding var selection: String?
    let projects: [(path: String, name: String, count: Int)]

    var body: some View {
        if Snapshot.isActive {
            // Without the Menu around it, the label would take all the width it's offered.
            label.fixedSize()
        } else {
            Menu {
                Button("All Projects") { selection = nil }
                Divider()
                ForEach(projects, id: \.path) { project in
                    Button {
                        selection = project.path
                    } label: {
                        Text("\(project.name)  \(project.count)")
                        if selection == project.path { Image(systemName: "checkmark") }
                    }
                    .help(Fmt.path(project.path))
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter by project")
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: selection == nil ? "folder" : "folder.fill")
                .font(.system(size: 11, weight: .medium))
            if let selection {
                Text((selection as NSString).lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 90)
            }
        }
        .foregroundStyle(selection == nil ? .secondary : Theme.accent)
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(selection == nil ? Color.clear : Theme.accent.opacity(0.12), in: Capsule())
        .contentShape(Capsule())
    }
}

struct SettingsMenu: View {
    @Environment(SessionStore.self) private var store
    @AppStorage(Prefs.placement) private var placement: Terminal.Placement = .tab
    @AppStorage(Prefs.terminal) private var terminal: Terminal.Kind = .iterm
    @AppStorage(Prefs.hotKey) private var hotKey = true
    @AppStorage(Prefs.notifications) private var notifications = true

    var body: some View {
        @Bindable var store = store
        Menu {
            Picker("Group By", selection: $store.grouping) {
                ForEach(Grouping.allCases) { Text($0.title).tag($0) }
            }
            Picker("Terminal", selection: $terminal) {
                ForEach(Terminal.Kind.allCases) { kind in
                    let installed = kind.isInstalled
                    Text(installed ? kind.title : "\(kind.title) (not installed)")
                        .tag(kind)
                        .disabled(!installed && kind != terminal)
                }
            }
            Picker("Open Sessions In", selection: $placement) {
                ForEach(Terminal.Placement.allCases) { Text($0.title).tag($0) }
            }
            Button("Extra claude Flags…") { Prompts.extraFlags() }
            Divider()
            Toggle("Notify When Claude Finishes", isOn: $notifications)
            Toggle("Show Hidden Conversations (\(store.hiddenCount))", isOn: $store.showHidden)
            Toggle("Global Shortcut ⌃⌥R", isOn: $hotKey)
            Toggle("Launch at Login", isOn: launchAtLogin)
            Divider()
            Menu("Quit Idle Sessions") {
                ForEach([(1, "1 day"), (3, "3 days"), (7, "7 days"), (30, "30 days")], id: \.0) { days, label in
                    let idle = store.idleSessions(olderThan: TimeInterval(days) * 86400)
                    Button("Waiting for over \(label) (\(idle.count))") { Prompts.quit(idle, store: store) }
                        .disabled(idle.isEmpty)
                }
            }
            Button("Refresh") { store.refresh() }
            Divider()
            Button("Quit ClaudeResume") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onChange(of: hotKey) { _, enabled in HotKey.shared.setEnabled(enabled) }
        .onChange(of: notifications) { _, enabled in if enabled { Notifier.shared.requestPermission() } }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                if enabled { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            }
        )
    }
}

// MARK: - Pieces

/// All / Running switch; ⇥ toggles it from the keyboard.
struct FilterPills: View {
    @Binding var selection: SessionFilter
    let runningCount: Int
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SessionFilter.allCases) { filter in
                let isOn = selection == filter
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = filter }
                } label: {
                    HStack(spacing: 4) {
                        if filter == .running {
                            Circle().fill(Theme.live).frame(width: 5, height: 5)
                        }
                        Text(filter.title)
                        if filter == .running, runningCount > 0 {
                            Text("\(runningCount)").monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background {
                        if isOn {
                            Capsule().fill(Color.primary.opacity(0.08))
                                .matchedGeometryEffect(id: "pill", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .help("Show all or only running conversations (⇥)")
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

struct EmptyState: View {
    let query: String
    var filter: SessionFilter = .all
    var hasProject = false

    private var emptyTitle: String {
        if filter == .running { return "Nothing running right now" }
        return hasProject ? "No conversations in this project" : "No conversations yet"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "bubble.left.and.text.bubble.right" : "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? emptyTitle : "No matches for “\(query)”")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if query.isEmpty, filter == .all, !hasProject {
                Text("Sessions from ~/.claude/projects show up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

// MARK: - Prompts

/// Small modal dialogs. They keep the panel open while they're up.
enum Prompts {
    @MainActor static func extraFlags() {
        let current = UserDefaults.standard.string(forKey: Prefs.extraFlags) ?? ""
        if let value = text(title: "Extra claude flags",
                            message: "Added to every resume command, for example --model opus or --permission-mode plan.",
                            value: current, placeholder: "--model opus", button: "Save") {
            UserDefaults.standard.set(value.trimmingCharacters(in: .whitespaces), forKey: Prefs.extraFlags)
        }
    }

    @MainActor static func rename(_ session: Session, store: SessionStore) {
        let message = store.live[session.id] == nil
            ? "The new name is saved in the transcript, so claude --resume shows it too."
            : "This session is running. ClaudeResume shows the new name now and saves it to the transcript once the session stops."
        if let value = text(title: "Rename conversation", message: message, value: session.title,
                            placeholder: "Name", button: "Rename") {
            store.rename(session, to: value)
        }
    }

    @MainActor static func quit(_ sessions: [Session], store: SessionStore) {
        guard !sessions.isEmpty else { return }
        let alert = NSAlert()
        if sessions.count == 1 {
            alert.messageText = "Quit “\(sessions[0].title)”?"
        } else {
            alert.messageText = "Quit \(sessions.count) idle sessions?"
        }
        let busy = sessions.filter { store.live[$0.id]?.status == .busy }.count
        var info = "The Claude Code processes stop. The conversations stay saved and you can resume them any time."
        if busy > 0 { info += "\n\nClaude is still working in \(busy == 1 ? "this session" : "\(busy) of them")." }
        if sessions.count > 1 {
            let names = sessions.prefix(8).map { "• \($0.title)" }.joined(separator: "\n")
            info += "\n\n" + names + (sessions.count > 8 ? "\n• and \(sessions.count - 8) more" : "")
        }
        alert.informativeText = info
        alert.alertStyle = busy > 0 ? .critical : .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also close their terminal tabs"
        alert.suppressionButton?.state = .on
        if run(alert) == .alertFirstButtonReturn {
            store.quit(sessions, closeTabs: alert.suppressionButton?.state == .on)
        }
    }

    @MainActor private static func text(title: String, message: String, value: String, placeholder: String,
                                        button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return run(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @MainActor static var isShowing = false

    @MainActor private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        isShowing = true
        defer { isShowing = false }
        let response = alert.runModal()
        NotificationCenter.default.post(name: .promptDidClose, object: nil)
        return response
    }
}

/// Tracks whether the selection last moved by keyboard, so hover doesn't make the list jump.
enum KeyboardState {
    @MainActor static var lastMoveWasKeyboard = false
}

extension Notification.Name {
    static let panelDidOpen = Notification.Name("ClaudeResume.panelDidOpen")
    static let promptDidClose = Notification.Name("ClaudeResume.promptDidClose")
}
