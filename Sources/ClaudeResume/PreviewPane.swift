import SwiftUI

/// The details pane (→): recap, last exchange, links, files changed and cost, without resuming.
struct PreviewPane: View {
    @Environment(SessionStore.self) private var store
    let session: Session
    let live: LiveSession?
    @State private var showAllLinks = false

    var body: some View {
        VStack(spacing: 0) {
            if Snapshot.isActive {
                Color.clear.overlay(alignment: .top) { details }.clipped()
            } else {
                ScrollView { details }.scrollIndicators(.never)
            }
            Divider().opacity(0.5)
            actions
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            stats
            if let recap = session.recap {
                Block(label: "Recap", icon: "text.quote") {
                    Text(recap).textSelection(.enabled)
                }
            }
            if !session.links.isEmpty { links }
            if let prompt = session.lastPrompt, prompt != session.title {
                Block(label: "You", icon: "person") {
                    Text(prompt).lineLimit(5).textSelection(.enabled)
                }
            }
            if let reply = session.lastReply {
                Block(label: "Claude", icon: "sparkle", tint: Theme.accent) {
                    Text(reply).lineLimit(12).textSelection(.enabled)
                }
            }
            if !session.filesChanged.isEmpty { files }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let live {
                HStack(spacing: 6) {
                    StatusDot(status: live.status)
                    Text(!live.statusKnown ? "Running" : live.status == .waiting ? "Needs you · \(live.waitingLabel)" : live.status.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(live.status.color)
                }
            }
            Text(session.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(3)
                .textSelection(.enabled)
            if store.profiles.count > 1 {
                Label(session.profile.label, systemImage: "person.crop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(Fmt.path(session.profile.directory.path))
            }
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.system(size: 10))
                Text(session.projectPath.map(Fmt.path) ?? "Unknown folder")
                    .lineLimit(1)
                    .truncationMode(.head)
                if let branch = session.branch {
                    Text("·").foregroundStyle(.quaternary)
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(branch).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var stats: some View {
        let started = session.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Stat(value: "\(session.promptCount)", label: session.promptCount == 1 ? "prompt" : "prompts")
                Stat(value: Fmt.cost(session) ?? "–", label: "API cost", help: Fmt.costHelp(session))
                Stat(value: Fmt.compact(session.tokens), label: "tokens",
                     help: "\(Fmt.compact(session.outputTokens)) output tokens. The total includes cache reads.")
                Stat(value: Fmt.age(session.lastActivity), label: "last active")
            }
            HStack(spacing: 6) {
                if let started { Text("Started \(started)") }
                if !session.models.isEmpty {
                    Text("·").foregroundStyle(.quaternary)
                    Text(session.models.prefix(2).joined(separator: ", "))
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            if let turn = session.lastTurn, turn.duration != nil || turn.edits > 0 {
                lastTurn(turn)
            }
        }
    }

    /// Flightdeck-style receipt for the running or last turn.
    private func lastTurn(_ turn: TurnSummary) -> some View {
        HStack(spacing: 10) {
            Text(live?.status == .busy ? "THIS TURN" : "LAST TURN")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            if let duration = turn.duration {
                Label(Fmt.precise(duration), systemImage: "clock")
            }
            if turn.edits > 0 {
                Label("\(turn.edits)", systemImage: "pencil").help(turn.edits == 1 ? "1 edit" : "\(turn.edits) edits")
            }
            if turn.errors > 0 {
                Label("\(turn.errors)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(turn.errors == 1 ? "1 tool error" : "\(turn.errors) tool errors")
            }
            if let cost = turn.cost, cost > 0 {
                Text("+≈" + Fmt.usd(cost)).help("Estimated API cost of this turn's main-session requests")
            }
            Spacer(minLength: 0)
        }
        .labelStyle(TurnLabelStyle())
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.top, 4)
    }

    private var links: some View {
        let shown = showAllLinks ? session.links : Array(session.links.prefix(3))
        return VStack(alignment: .leading, spacing: 4) {
            Label("Links · \(session.links.count)", systemImage: "link").labelStyle(BlockLabelStyle())
            ForEach(shown) { link in
                Button { store.openLink(link) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: link.kind == .pullRequest ? "arrow.triangle.pull" : "sparkles.rectangle.stack")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 16)
                        Text(link.detail)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(link.url.absoluteString)
            }
            if session.links.count > shown.count {
                Button("\(session.links.count - shown.count) more") { showAllLinks = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .padding(.leading, 8)
            }
        }
        .onChange(of: session.key) { _, _ in showAllLinks = false }
    }

    private var files: some View {
        let shown = session.filesChanged.prefix(8)
        return VStack(alignment: .leading, spacing: 4) {
            Label("Files changed · \(session.filesChanged.count == 40 ? "40+" : "\(session.filesChanged.count)")",
                  systemImage: "doc.on.doc").labelStyle(BlockLabelStyle())
            ForEach(Array(shown), id: \.self) { path in
                Button { store.revealFile(path) } label: {
                    HStack(spacing: 4) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .foregroundStyle(.primary)
                        Text(relative(path))
                            .foregroundStyle(.tertiary)
                            .truncationMode(.head)
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
            if session.filesChanged.count > shown.count {
                Text("and \(session.filesChanged.count - shown.count) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The file's folder relative to the session's folder.
    private func relative(_ path: String) -> String {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if let cwd = session.cwd, folder.hasPrefix(cwd) {
            let rest = folder.dropFirst(cwd.count).drop { $0 == "/" }
            return rest.isEmpty ? "" : String(rest)
        }
        return Fmt.path(folder)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { store.open(session) } label: {
                let running = live?.hasProcess == true
                Label(running ? "Switch to Tab" : "Resume", systemImage: running ? "arrow.up.forward.app" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            Button { store.open(session, fork: true) } label: {
                Text("Fork")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Resume as a new conversation (⌥↩)")
            Spacer()
            Button { store.togglePin(session) } label: {
                Image(systemName: store.pinned.contains(session.key) ? "pin.slash" : "pin")
            }
            .buttonStyle(IconButtonStyle())
            .help(store.pinned.contains(session.key) ? "Unpin (⌘P)" : "Pin to top (⌘P)")
            Button { Prompts.rename(session, store: store) } label: { Image(systemName: "pencil") }
                .buttonStyle(IconButtonStyle())
                .help("Rename (⌘E)")
            Button { store.revealFolder(session) } label: { Image(systemName: "folder") }
                .buttonStyle(IconButtonStyle())
                .help("Open folder")
                .disabled(!session.folderExists)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

// MARK: - Pieces

private struct Stat: View {
    let value: String
    let label: String
    var help: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .lineLimit(1)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }
}

private struct Block<Content: View>: View {
    let label: String
    let icon: String
    var tint: Color = .secondary
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon)
                .labelStyle(BlockLabelStyle(tint: tint))
            content
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TurnLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title
        }
    }
}

private struct BlockLabelStyle: LabelStyle {
    var tint: Color = .secondary

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 9, weight: .semibold)).foregroundStyle(tint)
            configuration.title
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? .secondary : .quaternary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
