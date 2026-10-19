import AppKit
import Foundation

/// Launch preferences apply to new sessions; existing sessions retain their own terminal.
enum Terminal {
    enum Kind: String, CaseIterable, Identifiable {
        case iterm, ghostty
        var id: String { rawValue }
        var title: String { self == .iterm ? "iTerm2" : "Ghostty" }
        var bundleID: String { self == .iterm ? ITerm.bundleId : Ghostty.bundleId }
        var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    }

    enum Placement: String, CaseIterable, Identifiable {
        case tab, window
        var id: String { rawValue }
        var title: String { self == .tab ? "New tab" : "New window" }
    }

    enum ID: Hashable, Sendable {
        case iterm(tty: String)
        case ghostty(terminalID: String)

        var kind: Kind {
            switch self {
            case .iterm: .iterm
            case .ghostty: .ghostty
            }
        }
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func selected(in defaults: UserDefaults = .standard) -> Kind {
        Kind(rawValue: defaults.string(forKey: Prefs.terminal) ?? "") ?? .iterm
    }

    static func resumeCommand(for session: Session, fork: Bool = false, extraFlags: String = "") -> String {
        ITerm.resumeCommand(for: session, fork: fork, extraFlags: extraFlags)
    }

    /// `claude` for Personal, exactly as before. Other accounts get their own config folder, and
    /// credentials from the shell are dropped so they can't sign in as a different account.
    static func claude(for profile: AgentProfile) -> String {
        guard !profile.isPersonal else { return "claude" }
        return "env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN "
            + "CLAUDE_CONFIG_DIR=\(ITerm.shellQuote(profile.directory.path)) claude"
    }

    /// `codex` with the account's `CODEX_HOME`. `marker` is the `Session.key` ClaudeResume uses to
    /// find the client it launched. As with Claude, `~/.codex` keeps your shell's credentials.
    static func codex(for profile: AgentProfile, marker: String? = nil) -> String {
        // `env` takes its -u options before any assignment.
        var unset: [String] = [], set: [String] = []
        if !profile.usesDefaultFolder {
            unset += ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"]
            set.append("CODEX_HOME=\(ITerm.shellQuote(profile.directory.path))")
        }
        if let marker {
            set.append("\(CodexRuntime.sessionMarker)=\(ITerm.shellQuote(marker))")
        } else {
            unset.append(CodexRuntime.sessionMarker)
        }
        return (["env"] + unset.map { "-u \($0)" } + set + ["codex"]).joined(separator: " ")
    }

    static func loginCommand(for profile: AgentProfile) -> String {
        switch profile.provider {
        case .claude: "\(claude(for: profile)) auth login"
        case .codex: "\(codex(for: profile)) login"
        }
    }

    static func newCommand(for profile: AgentProfile, cwd: String) -> String {
        let agent = profile.provider == .claude ? claude(for: profile) : codex(for: profile)
        return "cd \(ITerm.shellQuote(cwd)) && \(agent)"
    }

    static func run(_ command: String, in kind: Kind, placement: Placement, cwd: String? = nil) throws {
        guard kind.isInstalled else { throw Failure(message: "\(kind.title) isn't installed.") }
        switch kind {
        case .iterm: try ITerm.run(command, placement: placement)
        case .ghostty: try Ghostty.run(command, placement: placement, cwd: cwd)
        }
    }

    /// Never resume a second process into a conversation that is already running.
    static func open(_ command: String, live: LiveSession?, in kind: Kind,
                     placement: Placement, cwd: String? = nil) throws {
        if let live {
            guard let id = id(for: live), try focus(id) else {
                throw Failure(message: "This conversation is already running. Switch to its terminal, or quit it before resuming. Ghostty can focus sessions opened by ClaudeResume.")
            }
            return
        }
        try run(command, in: kind, placement: placement, cwd: cwd)
    }

    static func id(for live: LiveSession) -> ID? {
        let bytes = LiveSessions.processBytes(live.pid) ?? []
        let program = LiveSessions.environmentValue("TERM_PROGRAM", in: bytes)
        let marker = LiveSessions.environmentValue("CLAUDE_RESUME_TERMINAL", in: bytes)
        return id(tty: live.tty, terminalProgram: program,
                  ghosttyID: marker.flatMap { Ghostty.terminalID(for: $0) })
    }

    /// An inherited Ghostty marker must never take precedence over an iTerm2 tty.
    static func id(tty: String?, terminalProgram: String?, ghosttyID: String?) -> ID? {
        if terminalProgram == "ghostty" {
            return ghosttyID.map { .ghostty(terminalID: $0) }
        }
        if let tty { return .iterm(tty: tty) }
        return nil
    }

    static func focus(_ id: ID) throws -> Bool {
        guard isRunning(id.kind) else { return false }
        switch id {
        case .iterm(let tty): return try ITerm.focus(tty: tty)
        case .ghostty(let terminalID): return try Ghostty.focus(terminalID: terminalID)
        }
    }

    @discardableResult
    static func close(_ id: ID) throws -> Bool {
        guard isRunning(id.kind) else { return false }
        switch id {
        case .iterm(let tty): return try ITerm.close(tty: tty)
        case .ghostty(let terminalID): return try Ghostty.close(terminalID: terminalID)
        }
    }

    static func frontmostID() -> ID? {
        switch NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
        case ITerm.bundleId: return ITerm.frontmostTTY().map { .iterm(tty: $0) }
        case Ghostty.bundleId: return Ghostty.frontmostTerminalID().map { .ghostty(terminalID: $0) }
        default: return nil
        }
    }

    private static func isRunning(_ kind: Kind) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: kind.bundleID).isEmpty
    }
}
